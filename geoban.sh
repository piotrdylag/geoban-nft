#!/usr/bin/env bash
# geoban - block whole countries (all traffic or chosen TCP ports) with nftables.
#
# Design: country lists go into nftables interval sets, so the kernel matches a
# packet with a tree lookup. Blocked clients are dropped before Apache/PHP ever
# see the connection. No proxy, no per-request cost, no log files.
#
# Usage: sudo geoban <command>
#
# Commands:
#   apply      download lists, validate, load rules now, save them for boot
#   print      build the ruleset and print it (nothing is changed)
#   status     per-country counters: new connections dropped (or counted)
#   remove     delete the rules and disable the boot/update units (pause;
#              'apply' loads the rules and enables the units again)
#   countries [name]
#              list country codes, or search them: geoban countries korea
#
# Options:
#   -h, --help     show this help
#   --version      show the geoban version
#
# Config:  /etc/geoban/geoban.conf  (shell syntax, owned by root), e.g.
#   COUNTRIES="xx yy zz"      # ISO 3166-1 alpha-2 codes
#   PROTECT="pl"              # codes that must never be blocked (your own country)
#   PORTS="all"               # all = every port/protocol, SSH included; or TCP list "80,443"
#   ALLOW="203.0.113.10 2001:db8::/32"   # never blocked: your IP, monitoring, payment callbacks
#   MODE="drop"               # drop = block now, count = only count matches (dry run)
#   IPV6="no"                 # yes = also block IPv6 ranges
#   URL4='https://www.ipdeny.com/ipblocks/data/countries/%s.zone'
#   URL6='https://www.ipdeny.com/ipv6/ipaddresses/blocks/%s.zone'
#   LOCAL_DIR=""              # offline: read $LOCAL_DIR/v4/<cc>.zone and v6/<cc>.zone
#
# Country data: ipdeny.com (free). Be considerate: refresh weekly, not every minute.
# No warranty. Test from outside your network before relying on it.
# License: MIT

set -euo pipefail
VERSION=0.1.0
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

CONF="${GEOBAN_CONF:-/etc/geoban/geoban.conf}"
STATE_DIR="${GEOBAN_STATE_DIR:-/etc/geoban}"
RULES="$STATE_DIR/geoban.nft"
TABLE="geoban"
LOCK="${GEOBAN_LOCK:-/run/geoban.lock}"
# ISO 3166 code -> country name table shipped with tzdata (on nearly every system)
ISO_TAB="${GEOBAN_ISO_TAB:-/usr/share/zoneinfo/iso3166.tab}"

log()  { printf 'geoban: %s\n' "$*"; }
die()  { printf 'geoban: ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run as root (use sudo)"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

usage() {
  sed -n '2,/^# License/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
}

# ------------------------------------------------------------- countries ----
iso_name() { # $1 = code -> prints the country name; 1 = unknown, 2 = no table
  [[ -r $ISO_TAB ]] || return 2
  awk -F'\t' -v c="${1^^}" '$1 == c { print $2; found = 1; exit } END { exit !found }' "$ISO_TAB"
}

check_code() { # $1 = lowercase code, $2 = setting name (for the message)
  local cc=$1 rc=0 hint=""
  [[ $cc =~ ^[a-z]{2}$ ]] || die "bad country code in $2: '$cc' (two letters, e.g. cn; search: geoban countries <name>)"
  iso_name "$cc" >/dev/null || rc=$?
  (( rc == 0 || rc == 2 )) && return 0          # rc 2: no table here, skip the name check
  case $cc in
    uk) hint=" (did you mean gb?)" ;;             # common mistakes: UK and Greece (EU uses EL)
    el) hint=" (did you mean gr?)" ;;
  esac
  die "unknown country code in $2: '$cc'$hint; search: geoban countries <name>"
}

cmd_countries() { # $1 = optional search text (part of the name, or a code)
  [[ -r $ISO_TAB ]] || die "$ISO_TAB not found (install tzdata); list: https://www.ipdeny.com/ipblocks/"
  local out
  out=$(awk -F'\t' -v q="${1:-}" '
    BEGIN { q = tolower(q) }
    /^#/ || NF < 2 { next }
    { c = tolower($1); if (q == "" || c == q || index(tolower($2), q)) printf "%s  %s\n", c, $2 }
  ' "$ISO_TAB" | sort)
  [[ -n $out ]] || die "no country matches '$1' (names are short, e.g. 'Britain (UK)', 'Korea (South)')"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------- config ----
load_config() {
  COUNTRIES=""; PROTECT=""; PORTS="all"; ALLOW=""; MODE="drop"; IPV6="no"
  URL4='https://www.ipdeny.com/ipblocks/data/countries/%s.zone'
  URL6='https://www.ipdeny.com/ipv6/ipaddresses/blocks/%s.zone'
  LOCAL_DIR=""

  [[ -r $CONF ]] || die "config not found or unreadable: $CONF"
  # the config is sourced as shell code, so it must not be writable by others
  if [[ -n $(find "$CONF" -maxdepth 0 \( \( ! -user root -a ! -user "$(id -un)" \) -o -perm /022 \) 2>/dev/null) ]]; then
    die "$CONF must be owned by root and not writable by group/others"
  fi
  # shellcheck disable=SC1090
  source "$CONF"

  COUNTRIES=${COUNTRIES,,}; COUNTRIES=${COUNTRIES//,/ }
  PROTECT=${PROTECT,,};     PROTECT=${PROTECT//,/ }
  [[ -n ${COUNTRIES// /} ]] || die "COUNTRIES is empty in $CONF"
  local cc p
  for p in $PROTECT; do check_code "$p" PROTECT; done
  for cc in $COUNTRIES; do
    check_code "$cc" COUNTRIES
    for p in $PROTECT; do
      [[ $cc == "$p" ]] && die "refusing to block protected country: $cc"
    done
  done

  PORTS=${PORTS// /}; PORTS=${PORTS,,}
  if [[ $PORTS == all ]]; then
    # whole-host block: SSH from blocked countries is dropped too, so keep your
    # admin IP in ALLOW. Already-open sessions survive (ct state rule).
    MATCH=""
  else
    [[ $PORTS =~ ^[0-9]+(,[0-9]+)*$ ]] || die "bad PORTS: '$PORTS' (use 'all' or a list like 80,443)"
    IFS=, read -ra PORT_ARR <<<"$PORTS"
    for p in "${PORT_ARR[@]}"; do
      (( p >= 1 && p <= 65535 )) || die "port out of range: $p"
    done
    # port mode: never lock yourself out of SSH by mistake
    if command -v ss >/dev/null 2>&1; then
      local sp
      for sp in $(ss -H -tlnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -u); do
        for p in "${PORT_ARR[@]}"; do
          [[ $p == "$sp" ]] && die "PORTS includes the sshd port ($sp); refusing (set PORTS=\"all\" to block everything on purpose)"
        done
      done
    fi
    MATCH="tcp dport { ${PORTS//,/, } } "
  fi

  case $MODE in
    drop)  ACTION=" drop" ;;
    count) ACTION="" ;;
    *) die "MODE must be 'drop' or 'count'" ;;
  esac
  case $IPV6 in yes|no) ;; *) die "IPV6 must be 'yes' or 'no'" ;; esac

  A4=(); A6=()
  local a
  for a in ${ALLOW//,/ }; do
    if [[ $a =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
      A4+=("$a")
    elif [[ $a == *:* && $a =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]; then
      A6+=("$a")
    else
      die "bad ALLOW entry: '$a'"
    fi
  done
}

# ----------------------------------------------------------------- lists ----
fetch_zone() { # $1 = country code, $2 = 4|6
  local cc=$1 fam=$2 url
  if [[ -n $LOCAL_DIR ]]; then
    cat "$LOCAL_DIR/v$fam/$cc.zone"
    return
  fi
  if [[ $fam == 4 ]]; then
    # shellcheck disable=SC2059
    url=$(printf "$URL4" "$cc")
  else
    # shellcheck disable=SC2059
    url=$(printf "$URL6" "$cc")
  fi
  curl -fsS --retry 3 --connect-timeout 10 --max-time 120 "$url"
}

zone_list() { # $1 = country code, $2 = 4|6 ; prints its sorted unique CIDRs
  local cc=$1 fam=$2 re out
  if [[ $fam == 4 ]]; then
    re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
  else
    re='^[0-9a-fA-F:]+/[0-9]{1,3}$'
  fi
  out=$(fetch_zone "$cc" "$fam" 2>/dev/null | tr -d '\r' | grep -E "$re" | sort -u || true)
  [[ -n $out ]] || die "no IPv$fam ranges for '$cc' (wrong code or download problem); nothing was changed"
  printf '%s\n' "$out"
}

# --------------------------------------------------------------- ruleset ----
# One set pair and one rule per country (block4_cn, block6_cn, ...), so every
# country has its own counter. A few set lookups per NEW connection cost nothing
# measurable; established traffic is accepted before any of them.
emit_set() { # $1 name, $2 type, $3 elements (may contain newlines, may be empty)
  printf '  set %s {\n    type %s\n    flags interval\n    auto-merge\n' "$1" "$2"
  if [[ -n $3 ]]; then
    printf '    elements = {\n%s\n    }\n' "$3"
  fi
  printf '  }\n'
}

commas() { sed '$!s/$/,/'; } # comma after every line except the last

declare -A V4=() V6=() PREV=()

read_counters() { # PREV["4 cn"]="packets bytes" from the live ruleset, if any
  local fam cc pk by
  while read -r fam cc pk by; do
    PREV["$fam $cc"]="$pk $by"
  done < <(nft list chain inet "$TABLE" input 2>/dev/null | parse_counters)
}

parse_counters() { # rule lines on stdin -> "fam cc packets bytes"
  sed -nE 's/.*@block([46])_([a-z]{2}) counter packets ([0-9]+) bytes ([0-9]+).*/\1 \2 \3 \4/p'
}

counter_for() { # $1 = "4 cn" -> nft counter statement, carrying over old values
  local v=${PREV[$1]:-}
  if [[ -n $v ]]; then printf 'counter packets %s bytes %s' "${v% *}" "${v#* }"; else printf 'counter'; fi
}

build() { # uses V4/V6 (per country) and PREV (old counter values, may be empty)
  local cc fam
  printf 'table inet %s\n' "$TABLE"
  printf 'delete table inet %s\n' "$TABLE"
  printf 'table inet %s {\n' "$TABLE"
  local e4="" e6=""
  if (( ${#A4[@]} )); then e4=$(printf '%s\n' "${A4[@]}" | commas); fi
  if (( ${#A6[@]} )); then e6=$(printf '%s\n' "${A6[@]}" | commas); fi
  emit_set allow4 ipv4_addr "$e4"
  emit_set allow6 ipv6_addr "$e6"
  for cc in $COUNTRIES; do
    emit_set "block4_$cc" ipv4_addr "$(printf '%s\n' "${V4[$cc]}" | commas)"
    if [[ $IPV6 == yes ]]; then
      emit_set "block6_$cc" ipv6_addr "$(printf '%s\n' "${V6[$cc]}" | commas)"
    fi
  done
  printf '  chain input {\n'
  printf '    type filter hook input priority -150; policy accept;\n'
  # replies to connections this host opened (APIs, mirrors, DNS) must pass,
  # and already-open sessions are not cut. Only new traffic is checked below.
  printf '    ct state established,related accept\n'
  printf '    %sip saddr @allow4 accept\n' "$MATCH"
  printf '    %sip6 saddr @allow6 accept\n' "$MATCH"
  for cc in $COUNTRIES; do
    printf '    %sip saddr @block4_%s %s%s\n' "$MATCH" "$cc" "$(counter_for "4 $cc")" "$ACTION"
    if [[ $IPV6 == yes ]]; then
      printf '    %sip6 saddr @block6_%s %s%s\n' "$MATCH" "$cc" "$(counter_for "6 $cc")" "$ACTION"
    fi
  done
  printf '  }\n}\n'
}

prepare() { # fills V4[cc], V6[cc]
  local cc
  for cc in $COUNTRIES; do
    V4[$cc]=$(zone_list "$cc" 4)
    [[ $IPV6 == yes ]] && V6[$cc]=$(zone_list "$cc" 6)
  done
  return 0
}

# -------------------------------------------------------------- commands ----
cmd_print() {
  load_config
  prepare
  build
}

cmd_apply() {
  need_root; need nft; need flock
  exec 9>"$LOCK"
  flock -n 9 || die "another geoban run is in progress"
  load_config
  [[ -n $LOCAL_DIR ]] || need curl
  prepare

  # globals, not locals: the EXIT trap runs after this function has returned
  TMP_LIVE=$(mktemp); TMP_BOOT=$(mktemp)
  trap 'rm -f -- "${TMP_LIVE:-}" "${TMP_BOOT:-}"' EXIT
  build > "$TMP_BOOT"              # boot copy: counters start at zero after a reboot
  read_counters
  build > "$TMP_LIVE"              # live copy: keeps the per-country counts across refreshes

  nft -c -f "$TMP_LIVE" || die "generated ruleset failed validation; nothing was changed"
  nft -f "$TMP_LIVE"    || die "loading the ruleset failed"     # atomic: all or nothing
  mkdir -p "$STATE_DIR"
  install -m 600 "$TMP_BOOT" "$RULES"                           # reloaded at boot by geoban.service

  # after 'geoban remove' the units are disabled; apply turns them back on
  # (only when the installer created them, so test runs never touch systemd)
  if [[ -e /etc/systemd/system/geoban.service ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled -q geoban.service 2>/dev/null || systemctl enable -q geoban.service \
      || log "warning: could not enable geoban.service (rules will not survive a reboot)"
    systemctl is-enabled -q geoban-update.timer 2>/dev/null || systemctl enable -q --now geoban-update.timer \
      || log "warning: could not enable geoban-update.timer (no weekly refresh)"
  fi

  local cc n4=0 n6=0
  for cc in $COUNTRIES; do
    n4=$(( n4 + $(printf '%s\n' "${V4[$cc]}" | wc -l) ))
    [[ $IPV6 == yes ]] && n6=$(( n6 + $(printf '%s\n' "${V6[$cc]}" | wc -l) ))
  done
  log "active. countries: $COUNTRIES | IPv4 ranges: $n4 | IPv6 ranges: $n6 | ports: $PORTS | mode: $MODE"
  [[ $MODE == count ]] && log "count mode: nothing is blocked yet. Set MODE=\"drop\" and run apply again."
  return 0
}

human() { # bytes -> 1.2 MB
  awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1000 && i < 5) { b /= 1000; i++ }
                         printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

cmd_status() {
  need_root; need nft
  local rules mode="drop" what="dropped" cc pk by name tp=0 tb=0
  if ! rules=$(nft list chain inet "$TABLE" input 2>/dev/null); then
    echo "geoban is not active (start: sudo geoban apply)"
    return 1
  fi
  grep -Eq '@block[46]_[a-z]{2} counter.* drop' <<<"$rules" || { mode="count"; what="would be dropped"; }
  printf 'geoban is active, mode: %s. New connections %s since boot:\n\n' "$mode" "$what"
  printf '  %-28s %12s %10s\n' "COUNTRY" "PACKETS" "BYTES"
  while read -r pk by cc; do
    name=$(iso_name "$cc" 2>/dev/null) || name=""
    printf '  %-28s %12s %10s\n' "$cc  ${name:0:24}" "$pk" "$(human "$by")"
    tp=$(( tp + pk )); tb=$(( tb + by ))
  done < <(parse_counters <<<"$rules" |
           awk '{ p[$2] += $3; b[$2] += $4 } END { for (c in p) print p[c], b[c], c }' | sort -k1,1nr -k3)
  printf '  %-28s %12s %10s\n\n' "total" "$tp" "$(human "$tb")"
  echo "IPv4 + IPv6 combined. Counters reset at reboot or 'geoban remove', not at apply."
  echo "Raw rules: sudo nft list chain inet $TABLE input"
}

cmd_remove() {
  need_root
  if nft list table inet "$TABLE" >/dev/null 2>&1; then
    nft delete table inet "$TABLE"
    log "live rules removed"
  fi
  rm -f "$RULES"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now geoban.service geoban-update.timer >/dev/null 2>&1 || true
  fi
  log "boot and update units disabled. Config kept at $CONF"
}

if [[ ${1:-} == countries ]]; then
  [[ $# -le 2 ]] || die "usage: geoban countries [name]  (quote names with spaces)"
  cmd_countries "${2:-}"; exit
fi
[[ $# -le 1 ]] || die "too many arguments (see geoban --help)"
case "${1:-}" in
  apply)         cmd_apply ;;
  print)         cmd_print ;;
  status)        cmd_status ;;
  remove)        cmd_remove ;;
  -h|--help)     usage ;;
  --version)     echo "geoban $VERSION" ;;
  "")            usage; exit 2 ;;
  *)             die "unknown command: $1 (see geoban --help)" ;;
esac

#!/usr/bin/env bash
#
# geoban-setup.sh - install, update or remove the geoban command.
#
# Usage: sudo bash geoban-setup.sh [options]
#
# First run: asks which countries to block, what to block (all traffic or TCP
# ports) and which IPs must never be blocked, writes /etc/geoban/geoban.conf
# from the commented template geoban.conf.example,
# installs the 'geoban' command plus two systemd units (reload at boot, weekly
# list refresh) and applies the rules.
# Later runs: offers to keep the existing config and only reinstall the command
# and units, so this is also how you update geoban (git pull, then re-run).
#
# Options:
#   --uninstall   remove the rules, command, units and completion (config kept)
#   -h, --help    show this help
#
# Needs: root, nftables, curl, systemd. Run it from the repository directory.
# Works on Debian/Ubuntu-style systems that use nftables (Ubuntu 22.04+, Debian 11+).
# License: MIT

set -euo pipefail

CONF_DIR=/etc/geoban
CONF=$CONF_DIR/geoban.conf
# /usr/sbin is in sudo's secure_path on Debian/Ubuntu and EL alike; /usr/local/sbin
# is not on EL ("sudo: geoban: command not found").
BIN=/usr/sbin/geoban
COMPLETION=/usr/share/bash-completion/completions/geoban
UNIT_DIR=/etc/systemd/system
here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# true if $1 is a copy of our geoban.sh (identified by its header line)
is_ours() { grep -qs '^# geoban - block whole countries' "$1"; }

UNINSTALL=0
while (( $# )); do
  case $1 in
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"

if (( UNINSTALL )); then
  if command -v nft >/dev/null 2>&1 && nft list table inet geoban >/dev/null 2>&1; then
    nft delete table inet geoban
    echo "Removed the live rules (table inet geoban)."
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now geoban.service geoban-update.timer >/dev/null 2>&1 || true
  fi
  if [[ -e $BIN ]] && ! is_ours "$BIN"; then
    echo "Left $BIN alone: it is not geoban from this project."
  else
    rm -f -- "$BIN"
  fi
  rm -f -- "$COMPLETION" "$CONF_DIR/geoban.nft" \
    "$UNIT_DIR/geoban.service" "$UNIT_DIR/geoban-update.service" "$UNIT_DIR/geoban-update.timer"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
  echo "Removed $BIN, its completion and the systemd units."
  echo "Kept $CONF - delete $CONF_DIR manually if you don't need it."
  exit 0
fi

[[ -r $here/geoban.sh ]] || die "geoban.sh must be in the same directory as this script"
[[ -r $here/geoban.conf.example ]] || die "geoban.conf.example must be in the same directory as this script"
for c in nft curl systemctl flock; do
  command -v "$c" >/dev/null 2>&1 || die "missing '$c' (Debian/Ubuntu: apt install nftables curl util-linux)"
done

# --- name clash check (before any questions) ---------------------------------
if [[ -e $BIN ]] && ! is_ours "$BIN"; then
  die "$BIN already exists and is not geoban from this project; refusing to overwrite it (check: ls -l $BIN; head $BIN)"
fi
for d in /usr/local/sbin /usr/local/bin /usr/bin /sbin /bin; do
  f=$d/geoban
  [[ -e $f ]] || continue
  [[ $f -ef $BIN ]] && continue   # same file (merged /usr: /sbin -> /usr/sbin)
  if is_ours "$f"; then
    echo "WARNING: an old copy of geoban is at $f; remove it: sudo rm $f" >&2
  else
    echo "WARNING: another 'geoban' command exists at $f and may be run instead of $BIN" >&2
  fi
done

ask() { # $1 prompt, $2 default -> REPLY
  read -r -p "$1${2:+ [$2]}: " REPLY </dev/tty || die "no input"
  REPLY=${REPLY:-${2:-}}
}
yesno() { # $1 prompt, $2 default y|n -> returns 0 for yes
  local d=$2
  while true; do
    ask "$1 (y/n)" "$d"
    case ${REPLY,,} in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

ISO_TAB=/usr/share/zoneinfo/iso3166.tab
iso_name() { # $1 = code -> country name (fails if unknown or no table)
  [[ -r $ISO_TAB ]] || return 1
  awk -F'\t' -v c="${1^^}" '$1 == c { print $2; found = 1; exit } END { exit !found }' "$ISO_TAB"
}
code_ok() { # $1 = lowercase code; prints why it is wrong, returns 1 if so
  [[ $1 =~ ^[a-z]{2}$ ]] || { echo "  '$1' is not a two-letter code"; return 1; }
  [[ -r $ISO_TAB ]] || return 0                 # no table on this system: trust it
  iso_name "$1" >/dev/null && return 0
  case $1 in
    uk) echo "  'uk' is not a country code; the United Kingdom is 'gb'" ;;
    el) echo "  'el' is not a country code; Greece is 'gr'" ;;
    *)  echo "  '$1' is not a known country code (search: ? name)" ;;
  esac
  return 1
}

KEEP_CONF=0
if [[ -e $CONF ]]; then
  [[ -r /dev/tty ]] || die "no terminal available for questions"
  echo "Existing config found: $CONF"
  if yesno "Keep it and only (re)install the command and units?" y; then KEEP_CONF=1; fi
fi

run_wizard() {
[[ -r /dev/tty ]] || die "no terminal available for questions"
cat <<'EOF'

geoban setup
------------
Blocks whole countries using the kernel firewall (nftables): all traffic by
default, or only chosen TCP ports. Blocked clients are dropped before your
services see them, so there is no extra CPU or latency for everyone else.

EOF

# --- countries ---------------------------------------------------------------
echo "Country codes are ISO 3166-1 alpha-2 (United Kingdom = gb, not uk)."
echo "Type '?' and a name to search, e.g. '? korea'."
while true; do
  ask "Countries to BLOCK (two-letter ISO codes, space or comma separated, e.g. cn ru)"
  if [[ $REPLY == \?* ]]; then
    q=$(printf '%s' "${REPLY#\?}" | xargs)
    bash "$here/geoban.sh" countries "$q" | sed 's/^/  /' || true
    continue
  fi
  COUNTRIES=${REPLY,,}; COUNTRIES=$(printf '%s' "${COUNTRIES//,/ }" | xargs)
  [[ -n $COUNTRIES ]] || { echo "  enter at least one code"; continue; }
  ok=1
  for cc in $COUNTRIES; do code_ok "$cc" || ok=0; done
  (( ok )) || continue
  for cc in $COUNTRIES; do printf '  %s  %s\n' "$cc" "$(iso_name "$cc" || echo '?')"; done
  yesno "Block these?" y && break
done

# --- protected country -------------------------------------------------------
while true; do
  ask "YOUR OWN country code (will be refused as a block target, empty to skip)"
  PROTECT=$(printf '%s' "${REPLY,,}" | xargs)
  [[ -z $PROTECT ]] || code_ok "$PROTECT" || continue
  [[ -z $PROTECT ]] || echo "  $PROTECT = $(iso_name "$PROTECT" || echo '?')"
  hit=0
  for cc in $COUNTRIES; do [[ -n $PROTECT && $cc == "$PROTECT" ]] && hit=1; done
  if (( hit )); then echo "  '$PROTECT' is in your block list; remove it from one of them"; continue; fi
  break
done

# --- ports -------------------------------------------------------------------
echo
echo "What to block from those countries: 'all' = every port and protocol, SSH"
echo "included; or a TCP port list such as 80,443 (the SSH port is then refused)."
while true; do
  ask "Ports to block" "all"
  PORTS=${REPLY// /}; PORTS=${PORTS,,}
  [[ $PORTS == all || $PORTS =~ ^[0-9]+(,[0-9]+)*$ ]] && break
  echo "  use 'all' or a list like 80,443"
done

# --- allowlist ---------------------------------------------------------------
ALLOW=""
detected=${SSH_CLIENT:-}
detected=${detected%% *}
[[ -n $detected ]] || detected=$(who am i 2>/dev/null | sed -n 's/.*(\(.*\))$/\1/p' | head -1 || true)
if [[ $detected =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || $detected == *:* ]]; then
  if yesno "Never block your current address $detected?" y; then ALLOW=$detected; fi
fi
if [[ $PORTS == all ]]; then
  echo "NOTE: 'all' also blocks SSH from those countries. If you might log in from"
  echo "one of them (travel, VPN exit), add that admin IP below or keep console access."
fi
echo "Other addresses that must never be blocked: monitoring servers, payment or"
echo "shipping callback IPs, partners. IPv4/IPv6 addresses or CIDR, space separated."
while true; do
  ask "Extra allowed addresses (empty for none)"
  extra=$(printf '%s' "$REPLY" | tr ',' ' ' | xargs || true)
  ok=1
  for a in $extra; do
    if [[ $a =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || [[ $a == *:* && $a =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]; then :; else echo "  '$a' is not a valid address"; ok=0; fi
  done
  (( ok )) && break
done
ALLOW=$(printf '%s %s' "$ALLOW" "$extra" | xargs || true)

# --- ipv6 / mode -------------------------------------------------------------
echo
echo "IPv6: only needed if your site has an AAAA record (check: dig AAAA yourdomain)."
if yesno "Also block IPv6 ranges?" n; then IPV6=yes; else IPV6=no; fi

echo
echo "Mode: 'drop' blocks immediately. 'count' only counts what WOULD be blocked,"
echo "so you can check the numbers first (sudo geoban status) and switch later."
while true; do
  ask "Mode (drop/count)" "count"
  MODE=${REPLY,,}
  [[ $MODE == drop || $MODE == count ]] && break
done

# --- confirm -----------------------------------------------------------------
cat <<EOF

Summary
  block countries : $COUNTRIES
  protected       : ${PROTECT:-none}
  ports           : $PORTS
  never blocked   : ${ALLOW:-none}
  IPv6            : $IPV6
  mode            : $MODE

EOF
yesno "Install and apply now?" y || die "cancelled, nothing was changed"

# --- install -----------------------------------------------------------------
# Fill the answers into the commented template, so the config explains itself.
# All values were validated above and contain no quotes or backslashes.
umask 077
mkdir -p "$CONF_DIR"
local new; new=$(mktemp)
{
  echo "# generated by geoban-setup.sh on $(date +%F)"
  sed 's/\r$//' "$here/geoban.conf.example" | awk \
    -v COUNTRIES="$COUNTRIES" -v PROTECT="$PROTECT" -v PORTS="$PORTS" \
    -v ALLOW="$ALLOW" -v MODE="$MODE" -v IPV6="$IPV6" '
    /^(COUNTRIES|PROTECT|PORTS|ALLOW|MODE|IPV6)=/ {
      k = substr($0, 1, index($0, "=") - 1)
      v = (k == "COUNTRIES") ? COUNTRIES : (k == "PROTECT") ? PROTECT : (k == "PORTS") ? PORTS : \
          (k == "ALLOW") ? ALLOW : (k == "MODE") ? MODE : IPV6
      print k "=\"" v "\""; if (!(k in seen)) { seen[k] = 1; n++ }; next
    }
    { print }
    END { if (n != 6) exit 1 }'
} >"$new" || { rm -f "$new"; die "geoban.conf.example is missing a setting; nothing was changed"; }
install -o root -g root -m 0600 "$new" "$CONF"
rm -f "$new"
echo "Wrote $CONF (comments explain every setting)"
}

(( KEEP_CONF )) || run_wizard

# --- command + completion ----------------------------------------------------
# Strip Windows line endings while copying, in case the repo was checked out on
# Windows. Root-owned and not writable by others: it runs as root.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed 's/\r$//' "$here/geoban.sh" >"$tmp"
bash -n "$tmp" || die "geoban.sh has syntax errors; nothing was installed"
install -o root -g root -m 0755 "$tmp" "$BIN"
echo "Installed $BIN ($("$BIN" --version))"
if [[ -r $here/completions/geoban.bash ]]; then
  sed 's/\r$//' "$here/completions/geoban.bash" >"$tmp"
  install -D -o root -g root -m 0644 "$tmp" "$COMPLETION"
  echo "Installed $COMPLETION"
fi

# --- systemd units -----------------------------------------------------------
umask 022                          # unit files are world-readable, like every other unit
NFT=$(command -v nft)
cat > $UNIT_DIR/geoban.service <<EOF
[Unit]
Description=GeoIP country blocklist (nftables)
# load before any interface comes up (same ordering as the stock nftables.service)
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target
ConditionPathExists=$CONF_DIR/geoban.nft

[Service]
Type=oneshot
ExecStart=$NFT -f $CONF_DIR/geoban.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > $UNIT_DIR/geoban-update.service <<EOF
[Unit]
Description=Refresh GeoIP country lists

[Service]
Type=oneshot
ExecStart=$BIN apply
EOF

cat > $UNIT_DIR/geoban-update.timer <<'EOF'
[Unit]
Description=Weekly refresh of GeoIP country lists

[Timer]
OnCalendar=weekly
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF

"$BIN" apply
systemctl daemon-reload
systemctl enable --now geoban.service geoban-update.timer >/dev/null

cat <<EOF

Done.
  see counters   : sudo geoban status
  change settings: sudo vim $CONF && sudo geoban apply
  pause blocking : sudo geoban remove      (re-enable: sudo geoban apply)
  uninstall      : sudo bash geoban-setup.sh --uninstall
  help           : geoban --help

Now test from OUTSIDE your network (for example a phone on mobile data) and check
that your payment, shipping and monitoring callbacks still work.
Failed list downloads never change the active rules, so weekly refreshes are safe.
EOF

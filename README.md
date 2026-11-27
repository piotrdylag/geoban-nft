# geoban-nft

Block whole countries with **nftables**: all traffic, or only chosen TCP ports. Country lists go into
kernel interval sets, so blocked clients are dropped before Apache, nginx, PHP
or sshd ever see them: no proxy, no per-request CPU cost, no log files.

Built for bot floods that arrive as thousands of IPs sending one request each,
which per-IP tools such as fail2ban or CrowdSec scenarios never catch.

## Quick start

```bash
git clone https://github.com/piotrdylag/geoban-nft.git
cd geoban-nft
sudo bash geoban-setup.sh
```

The wizard asks for the countries to block, your own country, the ports, IPs that
must never be blocked, IPv6 and the mode. Ports default to `all` (every port and
protocol, SSH included). It then writes `/etc/geoban/geoban.conf` (from the
commented template `geoban.conf.example`), installs the
`geoban` command (`/usr/sbin/geoban`, with bash completion) and systemd units
(reload at boot, weekly list refresh) and applies the rules.

Default mode is `count` (dry run: counts what would be blocked). Choose `drop` to block.

## Choosing countries

Codes are ISO 3166-1 alpha-2, e.g. `cn`, `ru`, `br`. The United Kingdom is `gb`, not `uk`.

```bash
geoban countries            # all codes with names
geoban countries korea      # kp  Korea (North) / kr  Korea (South)
```

The list comes from tzdata (`/usr/share/zoneinfo/iso3166.tab`), so it works offline.
The wizard and `apply` reject unknown codes before anything is downloaded.
Not sure which countries to block? Run in `count` mode for a few days and check
`sudo geoban status`, or map the client IPs in your web server log to countries
with a free GeoIP database such as [DB-IP Lite](https://db-ip.com/db/download/ip-to-country-lite).

## Without the wizard

Start from the commented template, which explains every setting:

```bash
sudo install -D -o root -g root -m 600 geoban.conf.example /etc/geoban/geoban.conf
sudo vim /etc/geoban/geoban.conf        # set COUNTRIES, PROTECT, ALLOW, MODE...
```

The main settings:

```bash
COUNTRIES="xx yy zz"     # ISO 3166-1 alpha-2 codes
PROTECT="pl"             # never blockable: your own country
PORTS="all"              # all = every port/protocol (SSH too), or TCP list "80,443"
ALLOW="203.0.113.10"     # never blocked: your IP, monitoring, payment callbacks
MODE="count"             # count = dry run, drop = block
IPV6="no"                # yes = also block IPv6 ranges
```

Then run `sudo bash geoban-setup.sh` and answer "keep it" when it finds the config:
it installs the command and units without asking the questions again.

## Commands

| Command | What it does |
|---|---|
| `sudo geoban apply` | download lists, validate, load rules, save for boot |
| `sudo geoban print` | build and print the ruleset, change nothing |
| `sudo geoban status` | per-country table of blocked (or counted) connections |
| `sudo geoban remove` | delete rules, disable boot and update units (pause) |
| `geoban countries [name]` | list or search country codes, e.g. `geoban countries korea` |
| `geoban --help` / `--version` | help, installed version |

Change settings: `sudo vim /etc/geoban/geoban.conf && sudo geoban apply`.

## Statistics

Every country has its own counter, so you can see which blocks are worth keeping:

```
$ sudo geoban status
geoban is active, mode: drop. New connections dropped since boot:

  COUNTRY                           PACKETS      BYTES
  cn  China                           18342     1.1 MB
  ru  Russia                           4211   252.7 KB
  total                               22553     1.4 MB
```

Only new connections are counted (established traffic is accepted first). The
numbers survive `apply` and the weekly refresh; they reset at reboot or `remove`.
In `count` mode the same table shows what *would* be dropped.

## Update and uninstall

```bash
cd geoban-nft && git pull
sudo bash geoban-setup.sh               # keep the config -> reinstalls command and units
sudo bash geoban-setup.sh --uninstall   # removes rules, command, units; keeps the config
```

Manual rollback: `sudo nft delete table inet geoban`.

## Safety

- Refuses to block a country listed in `PROTECT`.
- With a port list, refuses `PORTS` that include the sshd port.
- With `PORTS="all"` SSH is blocked too: put your admin IP in `ALLOW`.
- `ct state established,related` is accepted first, so replies to connections
  the server opens itself (APIs, mirrors, DNS) and already-open sessions survive.
- `ALLOW` addresses are accepted before any block rule.
- The ruleset is validated with `nft -c` and loaded atomically; a failed or empty
  download changes nothing.
- Uses its own table (`inet geoban`), so it does not touch UFW, CrowdSec or Docker rules.
- Config must be root-owned and not group/other writable (it is sourced as shell).

**Before using `drop`:** allow-list your own IP, monitoring, and payment or
shipping callback IPs. Test from outside your network (e.g. phone on mobile data).

## Limits

- Country data is only as accurate as the source; some IPs are misattributed.
- Residential proxy networks use real ISP addresses and can come from any country.
- `IPV6="no"` (default) leaves IPv6 open. If the server has a public IPv6 address,
  set `IPV6="yes"`, otherwise blocked countries can still connect over IPv6.
- Only the host's own traffic (nftables `input` hook) is filtered. Ports published
  by Docker containers go through `forward` and are **not** blocked.

## Tested

- Ubuntu 26.04 (WSL, nftables 1.1.6), in isolated network namespaces: `apply`,
  `count` and `drop` modes, IPv4 + IPv6 blocking, `ALLOW`, port mode, per-country
  counters, boot file reload, `remove`, real ipdeny downloads (cn + ru, ~24,500 ranges,
  loads in ~0.1 s).
- Not yet tested: `geoban-setup.sh` end to end and the systemd units on a real server.
  Reports from Ubuntu 24.04 / Debian 12 / EL are welcome.

## Data

Lists come from [ipdeny.com](https://www.ipdeny.com/) and are downloaded at run
time, not bundled. Refresh weekly, not constantly, and check their terms of use.

## License

MIT

# geoblock-nft
 
Block whole countries on your web ports with **nftables**. Country lists go into
kernel interval sets, so blocked clients are dropped before Apache, nginx or PHP
ever see them: no proxy, no per-request CPU cost, no log files.
 
Built for bot floods that arrive as thousands of IPs sending one request each,
which per-IP tools such as fail2ban or CrowdSec scenarios never catch.
 
## Quick start
 
```bash
git clone https://github.com/<you>/geoblock-nft.git
cd geoblock-nft
sudo bash geoblock-setup.sh
```
 
The wizard asks for the countries to block, your own country, the ports, IPs that
must never be blocked, IPv6 and the mode. It then writes `/etc/geoblock/geoblock.conf`,
installs `/usr/local/sbin/geoblock.sh` and systemd units (reload at boot, weekly
list refresh) and applies the rules.
 
Default mode is `count` (dry run: counts what would be blocked). Choose `drop` to block.
 
## Without the wizard
 
Create `/etc/geoblock/geoblock.conf` (owned by root, not writable by others):
 
```bash
COUNTRIES="xx yy zz"     # ISO 3166-1 alpha-2 codes
PROTECT="pl"             # never blockable: your own country
PORTS="80,443"           # TCP ports to protect
ALLOW="203.0.113.10"     # never blocked: your IP, monitoring, payment callbacks
MODE="drop"              # drop | count
IPV6="no"                # yes = also block IPv6 ranges
```
 
Then run `sudo bash geoblock.sh apply`.
`apply` only loads the rules now; use the wizard for boot persistence and weekly refresh.
 
## Commands
 
| Command | What it does |
|---|---|
| `geoblock.sh apply` | download lists, validate, load rules, save for boot |
| `geoblock.sh print` | build and print the ruleset, change nothing |
| `geoblock.sh status` | show rules with packet/byte counters |
| `geoblock.sh remove` | delete rules, disable boot and update units |
 
Manual rollback: `sudo nft delete table inet geoblock`.
 
## Safety
 
- Refuses to block a country listed in `PROTECT`.
- Refuses `PORTS` that include the sshd port.
- `ALLOW` addresses are accepted before any block rule.
- The ruleset is validated with `nft -c` and loaded atomically; a failed or empty
  download changes nothing.
- Uses its own table (`inet geoblock`), so it does not touch UFW, CrowdSec or Docker rules.
- Config must be root-owned and not group/other writable (it is sourced as shell).
**Before using `drop`:** allow-list your own IP, monitoring, and payment or
shipping callback IPs. Test from outside your network (e.g. phone on mobile data).
 
## Limits
 
- Country data is only as accurate as the source; some IPs are misattributed.
- Residential proxy networks use real ISP addresses and can come from any country.
- The IPv6 list URL is unverified; keep `IPV6="no"` unless your site has an AAAA record.
- Tested on: Ubuntu 24.04 (update this list with what you actually tested).
## Data
 
Lists come from [ipdeny.com](https://www.ipdeny.com/) and are downloaded at run
time, not bundled. Refresh weekly, not constantly, and check their terms of use.
 
## License
 
MIT
 
# Runbook — persisting OMR router settings as code

Once you've spent hours getting the Beryl AX dialed in (bridge configured, country code set, 3 WANs bonded with the right MPTCP roles, S25 hotspot wired in as Wi-Fi-as-WAN, travelmate priorities set), the *next* concern is: how do you not have to redo all of this on a rebuild?

OMR ships with a Save Config / Load Config button in the LuCI Settings page — that's a fine first line of defense but is opaque (a binary blob you can't diff or share). For real persistence with version history, the answer is treating `/etc/config/*` on the router as code.

This runbook walks through both patterns.

---

## What's actually persistent — the file layout

Every meaningful OMR/OpenWrt setting is a plain-text UCI file under `/etc/config/`. Diffable, version-controllable, scriptable.

| File | What it controls |
|---|---|
| `network` | Interfaces, bridges (`br-lan`), devices, zones, routing tables |
| `wireless` | Radios, SSIDs (both AP and Client mode), encryption, country code |
| `firewall` | Zones, NAT, port forwards, ByPass rules |
| `dhcp` | dnsmasq config, DHCP server settings, static leases |
| `system` | Hostname, timezone, root password hash, log level |
| `openmptcprouter` | OMR-specific: VPS endpoint, per-WAN slots, MPTCP roles, Force TTL |
| `glorytun-tcp`, `glorytun-udp` | Per-tunnel keys, host, port |
| `shadowsocks-rust` | SS server, key, encryption |
| `dsvpn`, `mlvpn` | Other tunnel options |
| `travelmate` | Multi-upstream Wi-Fi list with priorities |
| `dropbear` | SSH host keys (don't replicate these — generate fresh per device) |

UCI format is simple line-based config; cat any of them to see. They contain secrets — passwords, VPS keys, root password hash — so handle accordingly.

---

## Pattern A — snapshot-based

Treat the router like a VM. Periodically pull `/etc/config/*` off the router into the repo. On rebuild, push it back. Fast, low cognitive overhead, but secrets sit on your laptop in plaintext.

### Backup

```bash
# scripts/router-backup.sh
#!/usr/bin/env bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.100.1}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT_DIR="$REPO_DIR/router-config/snapshots/$(date -u +%Y-%m-%dT%H-%M-%SZ)"

mkdir -p "$SNAPSHOT_DIR"
scp -r "root@$ROUTER:/etc/config" "$SNAPSHOT_DIR/"
ssh "root@$ROUTER" 'uci show' > "$SNAPSHOT_DIR/uci-show-all.txt"
ssh "root@$ROUTER" 'sysupgrade -b -' > "$SNAPSHOT_DIR/sysupgrade-backup.tar.gz"

# Maintain a "latest" symlink for the restore script
ln -sfn "$SNAPSHOT_DIR" "$REPO_DIR/router-config/latest"

echo "Snapshot written to $SNAPSHOT_DIR"
```

### Restore

```bash
# scripts/router-restore.sh
#!/usr/bin/env bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.100.1}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$REPO_DIR/router-config/latest}"

if [[ ! -d "$SOURCE/config" ]]; then
  echo "No snapshot at $SOURCE/config — run router-backup.sh first or pass a path"
  exit 1
fi

scp -r "$SOURCE/config/." "root@$ROUTER:/etc/config/"
ssh "root@$ROUTER" 'wifi reload; /etc/init.d/network restart; /etc/init.d/dnsmasq restart; /etc/init.d/firewall restart'
echo "Restored from $SOURCE. SSH may drop briefly during network restart."
```

### .gitignore

```
router-config/
```

(or, if using git-crypt, encrypt the dir instead of ignoring it.)

### When this pattern is right

- You're the sole user of the build
- You want quick rebuild capability without designing a config schema
- You're OK with secrets on your laptop (encrypted disk, no shared work machine)

### When this pattern breaks down

- Sharing the build pattern with others (your config is yours, not portable)
- Hardware migration (new Beryl has different MAC/keys; some snapshots paste poorly)
- Drift detection (no easy diff between "what I intend" and "what is")

---

## Pattern B — declarative `uci set` script

Write a `bootstrap.sh`-style script of `uci` commands that builds the desired config from a known starting point. The script is the source of truth. Secrets come from env vars or a separate gitignored file.

### Skeleton

```bash
# scripts/router-setup.sh
#!/usr/bin/env bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.100.1}"

# Read secrets — never commit this file
source "$(dirname "$0")/router-secrets.env"

ssh "root@$ROUTER" bash -s <<EOF
set -e

# --- LAN bridge ---
uci set network.lan_dev=device
uci set network.lan_dev.name='br-lan'
uci set network.lan_dev.type='bridge'
uci add_list network.lan_dev.ports='eth1'
uci set network.lan.device='br-lan'
uci delete network.lan.ifname 2>/dev/null || true

# --- System ---
uci set system.@system[0].hostname='OpenMPTCProuter'
uci set system.@system[0].timezone='America/New_York'

# --- Wireless ---
uci set wireless.radio0.country='US'
uci set wireless.radio0.disabled='0'
uci set wireless.radio1.country='US'
uci set wireless.radio1.disabled='0'

# AP on radio1 (5GHz)
# (assuming wifi-iface section index 1 = your 5GHz AP — adjust to match wifi config)
uci set wireless.@wifi-iface[1].mode='ap'
uci set wireless.@wifi-iface[1].ssid='BrownVortex'
uci set wireless.@wifi-iface[1].encryption='psk2'
uci set wireless.@wifi-iface[1].key="\${WIFI_AP_PASSWORD}"
uci set wireless.@wifi-iface[1].network='lan'
uci set wireless.@wifi-iface[1].country='US'

# Client on radio0 (2.4GHz) — joins S25 hotspot for Wi-Fi-as-WAN
uci set wireless.@wifi-iface[2].mode='sta'
uci set wireless.@wifi-iface[2].ssid="\${S25_SSID}"
uci set wireless.@wifi-iface[2].encryption='psk2'
uci set wireless.@wifi-iface[2].key="\${S25_PASSWORD}"
uci set wireless.@wifi-iface[2].network='wwan_s25'
uci set wireless.@wifi-iface[2].country='US'

# --- WAN networks ---
uci set network.wwan_s25=interface
uci set network.wwan_s25.proto='dhcp'

# --- OMR WAN slots ---
uci set openmptcprouter.wan1.iface='eth0'
uci set openmptcprouter.wan1.label='Home eth'
uci set openmptcprouter.wan1.multipath='master'

uci set openmptcprouter.wan2.iface='usb0'
uci set openmptcprouter.wan2.label='OnePlus USB'
uci set openmptcprouter.wan2.multipath='on'
uci set openmptcprouter.wan2.ttl='65'

uci set openmptcprouter.wan3=interface
uci set openmptcprouter.wan3.iface='phy0-sta0'
uci set openmptcprouter.wan3.label='S25 Wi-Fi'
uci set openmptcprouter.wan3.multipath='on'
uci set openmptcprouter.wan3.ttl='65'

# --- MPTCP scheduler ---
uci set network.globals.mptcp_scheduler='default'

# --- Commit and reload ---
uci commit
/etc/init.d/network restart
sleep 3
wifi reload
EOF

echo "router-setup applied. SSH may have dropped during network restart."
```

### Secrets file (gitignored)

```bash
# scripts/router-secrets.env (NOT in git)
export WIFI_AP_PASSWORD='your-ap-wpa2-password'
export S25_SSID="KENNETH's S25"
export S25_PASSWORD='your-s25-hotspot-password'
export ONEPLUS_SSID="OnePlus Hotspot"
export ONEPLUS_PASSWORD='your-oneplus-hotspot-password'
export OMR_SERVER_KEY='hex-from-vps-credentials.txt'
```

### .gitignore

```
scripts/router-secrets.env
router-config/snapshots/
```

### When this pattern is right

- You rebuild more than once (fresh OMR install, hardware swap, sharing the build)
- You want the config to be reviewable in PRs / commits
- You like declarative infrastructure-as-code style
- You want secrets cleanly separated from logic

### When this pattern breaks down

- Initial schema design takes hours
- UCI section indices (`@wifi-iface[N]`) drift if you manually add/remove sections via LuCI — script can target the wrong section
- Some OMR settings are computed at runtime (auto-fetched VPN keys); the script can't trivially seed them

---

## Recommended hybrid path

For the openmptcsetup repo, the realistic adoption sequence:

**Phase 1 — immediate value (5 minutes).** Drop in `scripts/router-backup.sh`. Run it after every meaningful config change. You now have a recovery point. Adds `router-config/snapshots/<timestamp>/` to git-ignored storage.

**Phase 2 — when you've done 2-3 rebuilds.** Write `scripts/router-restore.sh` to push a snapshot back. Test on a fresh OMR install to confirm it actually rebuilds correctly.

**Phase 3 — when the config feels stable.** Start extracting the repeatable parts into `scripts/router-setup.sh` declaratively. Each section gets `uci set` lines + a comment explaining why. Secrets move to `router-secrets.env`.

**Phase 4 — full declarative.** `router-setup.sh` builds the entire desired config from scratch. `router-backup.sh` becomes a sanity check ("did the live state drift from what setup.sh would produce?"). The two scripts validate each other.

You don't need to jump straight to Phase 4. Each phase delivers value standalone.

---

## What NOT to put under version control

- **`/etc/dropbear/*`** — SSH host keys. Different per device, regenerating is fine on rebuild.
- **`/etc/config/dhcp` lease files** — actually mostly fine to skip; leases regenerate
- **`/etc/openvpn/`, `/etc/wireguard/`** — private keys here. Encrypt with sops/git-crypt or keep out of VC entirely.
- **System log files, runtime state** — `/var/log/*`, `/tmp/*`. Ephemeral, not config.

The `/etc/config/` files are the canonical persistence target. Everything else is either ephemeral or per-device.

---

## Verifying your persistence pipeline works

1. Build the router fully via LuCI (or recover an existing one)
2. Run `scripts/router-backup.sh` — verify snapshot exists
3. Factory-reset the Beryl (System → Backup / Flash Firmware → Perform reset)
4. Re-do the basics (set root password, get LAN IP back to 192.168.100.1)
5. Run `scripts/router-restore.sh` or `scripts/router-setup.sh` against the freshly-reset device
6. Confirm: 3 WANs green, Wi-Fi AP up, dashboard shows VPS IP

If step 6 works without any manual fix-up, your persistence pipeline is complete. If you have to manually fix anything, that's a hole in the script — patch it and re-test.

This loop — *break it intentionally to verify the rebuild works* — is the only way to find out if your config-as-code is actually reproducible before you need it to be at 3am on a cruise ship.

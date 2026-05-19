# OMR Build Runbook — Beryl AX (GL-MT3000) + Vultr LAX

**This is the recommended setup.** Simpler than the R6S path because the Beryl AX is officially supported by OpenMPTCProuter — no vanilla-OpenWrt + opkg-feeds hackery.

Companion to `~/.claude/plans/what-would-be-the-golden-pearl.md`. Terse, command-by-command. Each phase ends with a **CHECKPOINT** — do not proceed past a failing checkpoint.

Hardware:
- GL.iNet GL-MT3000 (Beryl AX) — runs OMR directly, broadcasts Wi-Fi to clients
- Samsung Galaxy S25 — USB tether for T-Mobile 5G
- Starlink Mini — primary WAN via ethernet
- Vultr LAX VPS — bonding endpoint

R6S goes back in the box for now. You can swap to the R6S runbook (`RUNBOOK-R6S.md`) if you ever outgrow 2 WANs or need 1 Gbps+ encrypted bonded throughput.

---

## Pre-flight (do once, on your CachyOS box)

```bash
cd ~/dev/openmptcsetup
mkdir -p firmware

# Tools you'll need (probably already have these)
which curl wget sha256sum 2>/dev/null

# SSH keypair for the VPS (skip if reusing one)
ssh-keygen -t ed25519 -f ~/.ssh/omr_vps -C "omr-vps"
```

---

## Phase 1 — Vultr LAX VPS (~10 min)

Identical to the R6S runbook. If you've already done this, skip to Phase 2.

### 1.1 Provision

1. https://my.vultr.com → Deploy New Server
2. **Cloud Compute - Shared CPU** (cheapest tier)
3. **Location**: Los Angeles
4. **OS**: Debian 12 x64
5. **Plan**: $6/mo (1 vCPU, 1 GB RAM, 25 GB SSD, 1 TB bandwidth)
6. **Additional features**: enable IPv6, disable auto-backups
7. **SSH Keys**: upload `~/.ssh/omr_vps.pub`
8. **Hostname**: `omr-lax`
9. Deploy. Wait ~60s. Note the public IPv4.

```bash
echo "VPS_IP=<paste-here>" > ~/dev/openmptcsetup/.env
```

### 1.2 Install OMR server

```bash
ssh -i ~/.ssh/omr_vps root@<VPS_IP>

# Inside the VPS:
apt update && apt -y upgrade
reboot
```

Wait 30s, SSH back in:

```bash
ssh -i ~/.ssh/omr_vps root@<VPS_IP>

# Install OMR server (with the Debian 12 install-bug workaround)
wget -O - https://www.openmptcprouter.com/server/debian-x86_64.sh | \
  IPERF="no" OPENVPN="no" KERNEL="6.12" sh
```

The script will install MPTCP kernel 6.12 + Glorytun + Shadowsocks-libev + MLVPN + DSVPN, generate keys at `/root/openmptcprouter_config.txt`, move SSH to port **65222**, then reboot. You'll get kicked out — normal.

Wait ~90s, SSH back in on the new port:

```bash
ssh -i ~/.ssh/omr_vps -p 65222 root@<VPS_IP>

cat /root/openmptcprouter_config.txt
# Copy "Server IP" and "User key" — paste into the Beryl AX wizard later
```

### 1.3 Open firewall

```bash
ufw allow 65222/tcp comment 'SSH'
ufw allow 65001/tcp comment 'Glorytun TCP'
ufw allow 65001/udp comment 'Glorytun UDP'
ufw allow 65101/tcp comment 'Shadowsocks'
ufw allow 65500/tcp comment 'OMR admin'
ufw allow 65400/tcp comment 'iperf3'
ufw --force enable
ufw status numbered
```

**CHECKPOINT 1**: from your laptop —
```bash
nc -zv <VPS_IP> 65222
nc -zv <VPS_IP> 65500
nc -uzv <VPS_IP> 65001
```
All three must respond.

---

## Phase 2 — Download the official OMR Beryl AX image (~5 min)

```bash
cd ~/dev/openmptcsetup/firmware

# Browse the latest OMR release directory
# The target name is "mediatek-filogic" — the file we want has "glinet_gl-mt3000" or "mt3000" in the name.
curl -s https://releases.openmptcprouter.com/v0.63-6.12/ | grep -i 'mt3000\|gl-mt3000'

# Download the SYSUPGRADE image (NOT factory — we're flashing over GL.iNet's stock firmware via its built-in upgrade UI)
# Filename pattern (replace <patch> with the actual version shown):
wget https://releases.openmptcprouter.com/v0.63-6.12/openmptcprouter-v0.63-<patch>-mediatek-filogic-glinet_gl-mt3000-squashfs-sysupgrade.bin
wget https://releases.openmptcprouter.com/v0.63-6.12/sha256sums

# Verify
grep gl-mt3000 sha256sums | sha256sum -c -
# Should print: ...sysupgrade.bin: OK
```

⚠️ Two image types exist on the OMR releases page:
- `*-sysupgrade.bin` ← use this if you're flashing over GL.iNet's stock UI (recommended)
- `*-factory.bin` ← use this if recovering via U-Boot (uboot.gl-inet.com) or if sysupgrade fails

---

## Phase 3 — Flash OMR to the Beryl AX (~10 min)

### 3.1 Initial GL.iNet setup
1. Power up the Beryl AX (USB-C PD)
2. Connect laptop to its default SSID (printed on the bottom) or via ethernet to the LAN port
3. Browse to `http://192.168.8.1`
4. Complete the GL.iNet first-run wizard (set admin password — you'll throw this away in 5 min, but it's required to access the upgrade screen)

### 3.2 Flash via GL.iNet UI
1. **System → Upgrade** (or **Firmware Upgrade** depending on GL UI version)
2. Click **Local Upgrade** / **Upload Firmware**
3. Select the OMR `*-sysupgrade.bin` file
4. ⚠️ **Uncheck "Keep settings"** — OMR has a completely different config layout than GL.iNet's stock, keeping settings will brick the boot
5. Click **Install**
6. Wait 3-5 minutes. The router will reboot. Wi-Fi will disappear (OMR doesn't enable Wi-Fi by default).

### 3.3 First boot after OMR
1. Cable your laptop directly into the Beryl AX's **LAN port** (the 1 GbE port, not the 2.5 GbE WAN port)
2. Wait ~30s for OMR to come up
3. Your laptop should get a DHCP lease in `192.168.100.0/24`
4. Browser → `http://192.168.100.1` → log in as `root` with empty password
5. **Immediately** set a root password at System → Administration → Router Password

### 3.4 Recovery option (if you bricked it)
If the Beryl AX doesn't come back after flashing:
1. Power off, hold the reset button while powering on
2. Keep holding for 8 seconds until LED flashes rapidly
3. Browse to `http://192.168.1.1` — GL.iNet's U-Boot recovery web UI
4. Re-upload either the OMR `*-factory.bin` or GL.iNet's stock firmware to recover

**CHECKPOINT 2**: `http://192.168.100.1` loads showing "OpenMPTCProuter v0.63" in the system info. Status → Overview shows uptime ticking.

---

## Phase 4 — Hardware smoke test (~3 min)

```bash
ssh root@192.168.100.1

# WAN port (2.5GbE) is eth1, LAN port (1GbE) is eth0
ip link
# Expect: eth0 (LAN), eth1 (WAN), wlan0, wlan1 (the two Wi-Fi radios)

# Plug your S25 into the Beryl AX's USB 3.0 port (the rectangular USB-A on the back, NOT the USB-C power input)
dmesg | tail -20
lsusb
# Expect: Samsung device entry

# Enable USB tethering on the S25
# Settings → Connections → Mobile Hotspot and Tethering → USB tethering ON
dmesg | tail -10
ip link show usb0
# Expect: usb0 interface up with IP in 192.168.42.x

# If usb0 doesn't appear:
opkg update
opkg install kmod-usb-net-rndis usbutils
# Unplug/replug S25
```

**CHECKPOINT 3**: `usb0` exists with a DHCP-assigned IP. If not, don't proceed.

---

## Phase 5 — Wire WANs + run OMR wizard (~10 min)

### 5.1 Physical
- Starlink Mini → Beryl AX **WAN port** (2.5GbE)
- S25 (USB tethering ON) → Beryl AX **USB 3.0 port**
- Laptop → Beryl AX **LAN port**

### 5.2 OMR wizard

LuCI → **System → OpenMPTCProuter → Wizard**:

| Field | Value |
|---|---|
| Server IP | `<VPS_IP>` from Phase 1.2 |
| Server Key | paste from `openmptcprouter_config.txt` |
| Default VPN | `Glorytun TCP` |
| Also enable | Shadowsocks (checkbox) |
| wan1 interface | `eth1` (Starlink), Master, DHCP, enable SQM, enable MPTCP |
| wan2 interface | `usb0` (S25), DHCP, enable MPTCP |

Save & Apply. Wait ~30s for reload.

### 5.3 Scheduler tweak for VDI

```bash
ssh root@192.168.100.1

uci set network.globals.mptcp_scheduler='redundant'
uci commit network
/etc/init.d/network restart
/etc/init.d/glorytun restart
```

**CHECKPOINT 4**: LuCI → **OpenMPTCProuter → Status**:
- VPS: green / reachable
- wan1 (Starlink): green / connected
- wan2 (usb0): green / connected
- Glorytun tunnel: UP
- Shadowsocks: running

SSH check:
```bash
ip -s link show gt-tun0     # bytes incrementing
ping -c 4 8.8.8.8
curl -s ifconfig.me         # should return Vultr LAX IP
```

---

## Phase 6 — Configure Wi-Fi (~5 min)

The Beryl AX has two radios:
- **wlan0** = 5GHz (Wi-Fi 6, ~1200 Mbps, shorter range) — use as your **client-facing AP**
- **wlan1** = 2.4GHz (Wi-Fi 6, ~600 Mbps, longer range) — reserve for **Wi-Fi-as-WAN** later (cruise wifi, hotel wifi, etc.)

LuCI → **Network → Wireless**:

### 6.1 Enable the 5GHz AP for OnePlus
1. Find the `radio0` (5GHz) section
2. Click **Edit** on the existing default network
3. **General Setup**: Mode = Access Point, SSID = `<your-ssid>`, Network = `lan`
4. **Wireless Security**: Encryption = WPA2-PSK/WPA3-PSK (or just WPA3-PSK if your OnePlus supports it), enter a strong password
5. Save & Apply
6. Toggle the radio ON (the **Enable** button on the radio0 row)

### 6.2 Leave the 2.4GHz radio off for now
- We'll turn it on later when you need to capture cruise/hotel wifi (Phase 9, optional)

**CHECKPOINT 5**:
- Connect OnePlus to the new 5GHz SSID
- `ifconfig.me` on OnePlus returns the Vultr LAX IP (= proof the bonded tunnel is the egress)
- Speed test on OnePlus shows combined throughput approaching Starlink + cellular

---

## Phase 7 — OMR-ByPass for Tailscale (~3 min)

LuCI → **OpenMPTCProuter → ByPass**:

Add bypass rules so Tailscale skips Glorytun and rides Starlink direct:

| Source | Destination | Protocol | Port |
|---|---|---|---|
| LAN | any | UDP | 41641 (Tailscale direct) |
| LAN | any | TCP | 443 (Tailscale DERP fallback) |
| LAN | any | UDP | 3478 (STUN for NAT traversal) |

Save & Apply.

Install Tailscale on OnePlus + Mac Studio if not already done. From OnePlus:

```
tailscale status   # via the app — should show Mac Studio as "active, direct"
```

**CHECKPOINT 6**: `tailscale ping <mac-studio-name>` from OnePlus reports **direct** connection (not DERP relay).

---

## Phase 8 — End-to-end test

1. **VDI test**: launch VDI client on OnePlus, log into corp gateway. Eyeball keystroke latency, cursor jitter, video.
2. **Failover test**: SSH to Beryl, `ifdown wan1` (kills Starlink). VDI session should hiccup 2-5s then keep going on cellular only. `ifup wan1` to restore.
3. **Throughput**: on Mac Studio over Tailscale, `iperf3 -s`. On OnePlus or a laptop on the Beryl: `iperf3 -c <mac-tailscale-ip> -t 30`. Compare to either WAN alone.
4. **Moonlight** (secondary): launch Moonlight on OnePlus → Mac Studio. Works over Glorytun TCP. If laggy, add Glorytun UDP as a secondary tunnel.

---

## Phase 9 — Cruise mode: add Wi-Fi as WAN for ship/hotel wifi (~10 min)

Only enable this when you're somewhere with a Wi-Fi-only internet source (cruise wifi, hotel wifi, coffee shop, etc.).

### 9.1 Enable 2.4GHz radio as a client
LuCI → **Network → Wireless**:
1. Find `radio1` (2.4GHz) section → click **Scan**
2. Select the cruise/hotel SSID → click **Join Network**
3. Enter password (or leave blank for open wifi)
4. **Name of the new network**: `wwan` (this becomes a new interface)
5. **Firewall zone**: `wan`
6. Save & Apply

### 9.2 Handle the captive portal
Most cruise/hotel wifi requires browser-based login before they let traffic through. From your laptop on the LAN:
1. Open a browser, try to visit `http://example.com` (HTTP, not HTTPS — HTTPS won't redirect)
2. The captive portal page should appear
3. Log in / accept terms

Some captive portals are MAC-locked to the Beryl AX. If you re-power the router, you may need to log in again.

### 9.3 Add the new WAN to OMR
LuCI → **System → OpenMPTCProuter → Wizard**:
1. Add `wwan` as wan3
2. **For cruise wifi specifically**: enable MPTCP, but set its weight/priority LOWER than Starlink (cruise wifi is slow and high-latency — you want it as redundancy, not a primary throughput contributor)
3. Save & Apply

### 9.4 Cruise-specific tunnel adjustments
Cruise wifi often blocks UDP VPN traffic via DPI. To minimize tunnel failures:
1. LuCI → **OpenMPTCProuter → Settings**
2. **Primary tunnel**: Shadowsocks (looks like HTTPS, very rarely blocked)
3. **Disable** Glorytun UDP if it keeps failing — keep only Shadowsocks + Glorytun TCP

**CHECKPOINT 7**: SSH to Beryl, `ping -I wwan 8.8.8.8` works. OMR Status shows three green WANs. Throughput test shows combined throughput (cruise wifi contribution will be tiny but non-zero).

When you leave the cruise, just disable the 2.4GHz radio in LuCI to drop wan3.

---

## Troubleshooting quick-refs

| Symptom | Likely cause | Fix |
|---|---|---|
| Stuck on GL.iNet after flash | Forgot to uncheck "Keep settings" | Reflash via U-Boot recovery (Phase 3.4) |
| `usb0` doesn't appear after S25 tether | RNDIS driver missing | `opkg install kmod-usb-net-rndis` |
| Glorytun tunnel won't establish | VPS firewall blocking 65001 | Check `ufw status` on VPS |
| Cruise wifi blocks tunnel | DPI blocking UDP VPNs | Switch to Shadowsocks-only |
| OnePlus on Beryl Wi-Fi can't reach internet | Wi-Fi network attached to wrong firewall zone | Wireless → edit SSID → Network = `lan` |
| Speed < 50% of single WAN | SQM wrong values | LuCI → Network → SQM, run wizard speedtest |
| Tailscale stuck on DERP relay | Bypass UDP 41641 not active | Recheck ByPass rules, restart Tailscale |
| VDI disconnects after a few min | Glorytun TCP + CGNAT NAT expiry (#2418) | Set keepalive in `/etc/config/glorytun` to 15s |

---

## Files generated

- `/root/openmptcprouter_config.txt` (VPS) — Server IP, User Key, all VPN keys
- `/etc/config/network` (Beryl AX) — interface definitions
- `/etc/config/wireless` (Beryl AX) — Wi-Fi config
- `/etc/config/glorytun` (Beryl AX) — Glorytun TCP/UDP configs
- `/etc/config/shadowsocks-libev` (Beryl AX) — SS-MPTCP config
- `/etc/config/omr-bypass` (Beryl AX) — bypass rules

Back these up after a successful build:
```bash
ssh root@192.168.100.1 'tar czf - /etc/config' > ~/dev/openmptcsetup/beryl-config-backup-$(date +%F).tar.gz
```

---

## Why this is the recommended path over the R6S

- **Official OMR image** — no vanilla-OpenWrt + opkg-feeds overlay required
- **Built-in Wi-Fi AP** — one device does everything
- **Built-in Wi-Fi client** — Wi-Fi-as-WAN for cruise/hotel comes for free
- **Less power draw** (~5W vs ~10W), smaller, runs cooler
- **Community-validated** — bugs hit OMR's main forum, fixes ship in mainline

The R6S still wins if you need:
- 3+ wired WANs simultaneously (e.g. Starlink + ethernet WAN bridge + a second cellular modem all wired in)
- 1 Gbps+ encrypted bonded throughput
- A dedicated headless router with no Wi-Fi (e.g. driving an external high-power AP)

For most use cases (home + travel + cruise): Beryl AX is genuinely the better choice.

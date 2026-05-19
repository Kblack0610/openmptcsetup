# OMR Build Runbook — R6S + Vultr LAX

Companion to `~/.claude/plans/what-would-be-the-golden-pearl.md`. Terse, command-by-command. Each phase ends with a **CHECKPOINT** — do not proceed past a failing checkpoint.

---

## Pre-flight (do once, on your CachyOS box)

```bash
# Working dir
cd ~/dev/openmptcsetup

# Tools you'll need
which curl wget dd sha256sum balena-etcher 2>/dev/null
# If balenaEtcher isn't installed: yay -S balena-etcher  (or use dd)

# SSH keypair for the VPS (skip if you already have one you'll use)
ssh-keygen -t ed25519 -f ~/.ssh/omr_vps -C "omr-vps"
```

---

## Phase 1 — Vultr LAX VPS (~10 min)

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
# Save the IP locally so the wizard step is easy
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

The script will:
- Add the OMR Debian repo
- Install MPTCP kernel 6.12
- Install Glorytun, Shadowsocks-libev, MLVPN, DSVPN
- Generate keys at `/root/openmptcprouter_config.txt`
- Move SSH to port **65222**
- Reboot at the end (you'll get kicked out — this is normal)

Wait ~90s for reboot. SSH back in on the NEW port:

```bash
ssh -i ~/.ssh/omr_vps -p 65222 root@<VPS_IP>

# Grab the credentials
cat /root/openmptcprouter_config.txt
# Copy "Server IP" and "User key" — you'll paste them into the R6S wizard
```

### 1.3 Open firewall

```bash
# Inside VPS — minimal port set for our config
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
nc -zv <VPS_IP> 65222  # SSH
nc -zv <VPS_IP> 65500  # OMR admin
nc -uzv <VPS_IP> 65001 # Glorytun UDP (returns "open" or "succeeded")
```
All three must respond. If any fail, check Vultr's firewall console (separate from ufw).

---

## Phase 2 — Flash R6S with OpenWrt 24.10 (~10 min)

### 2.1 Download

```bash
cd ~/dev/openmptcsetup
mkdir -p firmware && cd firmware

# Get the current 24.10.x patch version
curl -s https://downloads.openwrt.org/releases/ | grep -oE '24\.10\.[0-9]+' | sort -u | tail -1
# Use that version below — example assumes 24.10.0
OWRT_VER=24.10.0  # update to whatever the above command printed

wget "https://downloads.openwrt.org/releases/${OWRT_VER}/targets/rockchip/armv8/openwrt-${OWRT_VER}-rockchip-armv8-friendlyarm_nanopi-r6s-squashfs-sysupgrade.img.gz"
wget "https://downloads.openwrt.org/releases/${OWRT_VER}/targets/rockchip/armv8/sha256sums"

# Verify
grep nanopi-r6s sha256sums | sha256sum -c -
# Should print: ...img.gz: OK
```

### 2.2 Flash SD card

⚠️ Identify your SD card BEFORE running dd. `lsblk` is your friend.

```bash
# Plug SD card in, find its device
lsblk
# Look for the SD card by size (probably /dev/sdb or /dev/mmcblk0). DO NOT pick /dev/sda or /dev/nvme0n1.

# Decompress + write (replace /dev/sdX)
gunzip -c openwrt-${OWRT_VER}-rockchip-armv8-friendlyarm_nanopi-r6s-squashfs-sysupgrade.img.gz | \
  sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sudo sync
```

(Alternative: use `balena-etcher` with the GUI if you prefer.)

### 2.3 First boot

1. Eject SD, insert into R6S
2. Plug laptop ethernet into the R6S **LAN port** (the 1 GbE one, *not* one of the 2.5 GbE WAN ports)
3. Power on R6S via USB-C PD
4. Wait ~60s for first boot (LED activity should settle)

```bash
# From laptop, set NetworkManager to DHCP on the wired interface
# Verify you got an IP in 192.168.1.0/24:
ip a show <your-ethernet-interface>

# SSH in (no password yet)
ssh root@192.168.1.1
```

**Set a root password immediately:**
```bash
passwd
# Then exit and re-test via LuCI
```

Browser → `http://192.168.1.1` → log in as root.

**CHECKPOINT 2**: LuCI loads, you see "OpenWrt 24.10.x" in the bottom-right. Goto **Status → Overview** and confirm uptime is ticking.

---

## Phase 3 — Smoke-test R6S hardware (CRITICAL, ~5 min)

This is where you find out if your R6S has the USB 3.0 issue *before* you've built a full stack on top of it.

```bash
ssh root@192.168.1.1

# All three Ethernet interfaces present?
ip link
# Expect: eth0, eth1, eth2 (plus lo and br-lan). If only eth0 + eth1, that's still OK for 2 WANs.

# MAC unique (not all zeros)?
cat /sys/class/net/eth0/address
cat /sys/class/net/eth1/address
# If both read 00:00:00:00:00:00 or identical, set manually via uci before continuing.

# USB 3.0 smoke test — THE BIG ONE
# Plug your S25 into the USB-C port on the R6S (don't enable tethering yet — just plug it in)
dmesg | tail -30
lsusb
# Expect: a Samsung device line in lsusb output, dmesg shows "new SuperSpeed USB device"
```

Now enable USB tethering on the S25 (Settings → Connections → Mobile Hotspot and Tethering → USB tethering):

```bash
# Back on R6S
dmesg | tail -20
# Expect: "rndis_host: Samsung [...] USB Mobile Broadband" or similar
# Expect: usb0 interface appears

ip link show usb0
ip a show usb0
# Expect: usb0 has an IP in 192.168.42.x
```

**CHECKPOINT 3** — three outcomes:

- **All three pass** → proceed to Phase 4.
- **USB enumerates but `usb0` doesn't appear** → install RNDIS driver before proceeding:
  ```bash
  opkg update
  opkg install kmod-usb-net-rndis usbutils
  # Unplug/replug S25, retest
  ```
- **USB 3.0 doesn't enumerate at all (no `dmesg` output, no `lsusb` entry)** → you've hit the RK3588 USB 3.0 bug. **STOP HERE.** You need to either:
  - Wait for OpenWrt to pick up the kernel patch (https://patchwork.kernel.org/project/linux-arm-kernel/patch/20240612205056.397204-5-seb-dev@mail.de/) — possibly already in 24.10.1+
  - Try OpenWrt SNAPSHOT (newer kernel) instead of 24.10
  - Or use the second 2.5GbE port + a separate GL.iNet mini-router doing RNDIS-to-Ethernet bridge as a workaround

Don't proceed to Phase 4 until USB tethering works. Everything downstream depends on `usb0`.

---

## Phase 4 — Layer OMR userspace on top (~5 min)

```bash
ssh root@192.168.1.1

# Add the OMR feed
cat >> /etc/opkg/customfeeds.conf <<'EOF'
src/gz openmptcprouter_feeds https://github.com/Ysurac/openmptcprouter-feeds/raw/v0.63/
EOF

opkg update

# Install core OMR userspace
opkg install \
  luci-app-openmptcprouter \
  shadowsocks-libev-mptcp \
  glorytun \
  mptcp-tools \
  omr-tracker \
  omr-bypass \
  luci-app-omr-bypass \
  luci-app-mptcp

# Reboot to pick up everything
reboot
```

Wait 60s, SSH back in.

**CHECKPOINT 4**: in LuCI you now see a **System → OpenMPTCProuter** menu. Click into it — the Wizard page should render without errors.

---

## Phase 5 — Wire WANs + run OMR wizard (~10 min)

### 5.1 Physical

- Starlink Mini → R6S **eth1** (one of the 2.5 GbE ports)
- S25 (USB tether ON) → R6S USB-C
- Laptop → R6S **eth0/LAN** (don't unplug yet)

### 5.2 Wizard

LuCI → **System → OpenMPTCProuter → Wizard**:

| Field | Value |
|---|---|
| Server IP | `<VPS_IP>` from Phase 1.2 |
| Server Key | paste from `openmptcprouter_config.txt` |
| Default VPN | `Glorytun TCP` |
| Also enable | Shadowsocks (checkbox) |
| wan1 interface | `eth1` (Starlink), Master, DHCP, enable SQM, enable MPTCP |
| wan2 interface | `usb0` (S25), DHCP, enable MPTCP |

Save & Apply. Wait ~30s for the page to reload.

### 5.3 Scheduler tweak for VDI

LuCI → **OpenMPTCProuter → Settings → Multipath TCP** (or via SSH):

```bash
uci set network.globals.mptcp_scheduler='redundant'
uci commit network
/etc/init.d/network restart
/etc/init.d/glorytun restart
```

**CHECKPOINT 5**: LuCI → **OpenMPTCProuter → Status**:
- VPS: green / reachable
- wan1 (Starlink): green / connected
- wan2 (usb0): green / connected
- Glorytun tunnel: UP
- Shadowsocks: running

SSH to R6S:
```bash
ip -s link show gt-tun0     # Glorytun TCP — bytes incrementing under load
ping -c 4 8.8.8.8           # internet works
curl -s ifconfig.me         # should return your VPS's public IP (proof the tunnel is the egress)
```

---

## Phase 6 — Beryl AX as dumb AP (~5 min)

1. Power Beryl AX, connect a separate device to its default SSID
2. http://192.168.8.1 → set admin password
3. **System → Network Mode → Access Point** → Apply
4. Cable from R6S **eth2 (LAN)** → Beryl WAN-or-LAN port
5. Beryl's IP changes — find it via LuCI on R6S: **Network → DHCP and DNS → Active DHCP Leases**
6. Reconnect to the new Beryl IP, configure 5GHz SSID + WPA3 password

**CHECKPOINT 6**: connect OnePlus to Beryl Wi-Fi → `ifconfig.me` on OnePlus returns the Vultr LAX IP.

---

## Phase 7 — OMR-ByPass for Tailscale (~3 min)

LuCI → **OpenMPTCProuter → ByPass**:

Add bypass rules so Tailscale skips Glorytun:

| Source | Destination | Protocol | Port |
|---|---|---|---|
| LAN | any | UDP | 41641 (Tailscale direct) |
| LAN | any | TCP | 443 (Tailscale DERP fallback) |
| LAN | any | UDP | 3478 (STUN for NAT traversal) |

Save & Apply.

Install Tailscale on OnePlus + Mac Studio if not already. From OnePlus:

```
tailscale status   # via the app — confirm Mac Studio is "active, direct"
```

**CHECKPOINT 7**: `tailscale ping <mac-studio-name>` from OnePlus reports **direct** connection (not via DERP). If it shows DERP relay, the bypass rule for UDP 41641 isn't working — recheck.

---

## Phase 8 — End-to-end test

1. **VDI test**: launch your VDI client on the OnePlus, log into the corp gateway. Eyeball: keystroke latency, mouse cursor jitter, video playback if any.
2. **Failover test**: SSH to R6S, `ifdown wan1` (kills Starlink). VDI session should hiccup ~2-5s then keep going on cellular only. `ifup wan1` to restore.
3. **Throughput test** (optional): on Mac Studio over Tailscale, `iperf3 -s`. On OnePlus or a laptop on the Beryl: `iperf3 -c <mac-tailscale-ip> -t 30`. Compare to either WAN alone.
4. **Moonlight test** (optional, secondary): launch Moonlight on OnePlus → connect to Mac Studio. Stream should work over Glorytun TCP. If laggy, add Glorytun UDP as a secondary tunnel (see plan file Phase 6).

---

## Troubleshooting quick-refs

| Symptom | Likely cause | Fix |
|---|---|---|
| `usb0` doesn't appear after S25 tether | RNDIS driver missing | `opkg install kmod-usb-net-rndis` |
| Glorytun tunnel won't establish | VPS firewall blocking 65001/UDP | Check `ufw status` on VPS |
| Speed < 50% of single WAN | SQM not configured or wrong values | LuCI → Network → SQM, run wizard speedtest |
| Tailscale stuck on DERP relay | Bypass UDP 41641 not active | Re-add ByPass rule, restart Tailscale on client |
| VDI session disconnects after a few min | Glorytun TCP + CGNAT NAT expiry (#2418) | Set keepalive in `/etc/config/glorytun` to 15s |
| LuCI wizard 500-errors | Mainline kernel missing OMR patches | Manual config via `/etc/config/network` + restart services |

---

## Files generated

- `/root/openmptcprouter_config.txt` (VPS) — Server IP, User Key, all VPN keys
- `/etc/config/network` (R6S) — interface definitions
- `/etc/config/glorytun` (R6S) — Glorytun TCP/UDP configs
- `/etc/config/shadowsocks-libev` (R6S) — SS-MPTCP config
- `/etc/config/omr-bypass` (R6S) — bypass rules

Back these up after a successful build:
```bash
ssh root@192.168.1.1 'tar czf - /etc/config' > ~/dev/openmptcsetup/r6s-config-backup-$(date +%F).tar.gz
```

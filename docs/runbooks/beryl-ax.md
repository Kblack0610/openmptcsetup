# OMR Build Runbook — Beryl AX (GL-MT3000) + Vultr LAX

**This is the recommended setup.** Simpler than the R6S path because the Beryl AX is officially supported by OpenMPTCProuter — no vanilla-OpenWrt + opkg-feeds hackery.

Companion to `~/.claude/plans/what-would-be-the-golden-pearl.md`. Terse, command-by-command. Each phase ends with a **CHECKPOINT** — do not proceed past a failing checkpoint.

Hardware:
- GL.iNet GL-MT3000 (Beryl AX) — runs OMR directly, broadcasts Wi-Fi to clients
- Samsung Galaxy S25 — USB tether for T-Mobile 5G
- Starlink Mini — primary WAN via ethernet
- DigitalOcean SFO3 VPS — bonding endpoint (provisioned by `vps-create-do.sh`)

R6S goes back in the box for now. You can swap to the R6S runbook (`r6s.md` in this folder) if you ever outgrow 2 WANs or need 1 Gbps+ encrypted bonded throughput.

> See also: `../concepts.md` for the *why* behind MPTCP/bonding/scheduler/role choices, and `../troubleshooting.md` for failure-mode lookups when something doesn't go green.

---

## Pre-flight (do once, on your CachyOS box)

```bash
cd ~/dev/openmptcsetup
./bootstrap.sh
```

`bootstrap.sh` checks for required tools, generates the `~/.ssh/omr_vps` keypair (if missing),
and downloads + checksum-verifies the official Beryl AX firmware into `./firmware/`. This covers
Phase 2 as well — once it's done, the image is already staged and verified.

---

## Phase 1 — DigitalOcean SFO3 VPS (~10 min)

**Scripted path (recommended).** From your CachyOS box (uses your existing `doctl` auth):

```bash
cd ~/dev/openmptcsetup
./vps-create-do.sh
```

This creates a $6/mo Debian 12 droplet in **SFO3**, then auto-chains into `vps-install.sh`,
which upgrades the base system, runs the OMR server installer (MPTCP kernel 6.12 + Glorytun +
Shadowsocks-libev + MLVPN + DSVPN, with the Debian 12 install-bug workaround), opens the firewall
(Phase 1.3 below — done for you), reboots, and moves SSH to port **65222**. When it finishes it
writes your **Server IP + User Key** to `vps-credentials.txt` — that's what you paste into the
Beryl AX wizard in Phase 5.

> **Region note:** SFO3 is correct even for the Alaska cruise. The VPS should sit near your
> *destinations* (SoCal home/corp), not near your physical location; on a cruise the satellite
> uplink latency dominates anyway, and DO's only US-West region is SFO. See `../vps-options.md`.

> **Building from the ship?** Fine over **Starlink** (high ports open, no DPI). Avoid building
> over **ship wifi** — it often blocks the high SSH/tunnel ports. See `cruise-checklist.md` (sibling).

### Manual fallback (no doctl, or using Vultr/another provider)

1. Deploy a **Debian 12 x64**, KVM, 1 vCPU / 1 GB instance with native public IPv4 + IPv6,
   upload `~/.ssh/omr_vps.pub`. (Vultr LAX or DO SFO3 both work — see `../vps-options.md`.)
2. Point the installer at it and let it do the rest:

```bash
echo "VPS_IP=<paste-here>" > ~/dev/openmptcsetup/.env
./vps-install.sh    # runs the OMR installer + firewall + saves vps-credentials.txt
```

The OMR installer moves SSH to port **65222** and reboots — `vps-install.sh` handles the
reconnect and credential extraction automatically.

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

> **Already done if you ran `./bootstrap.sh` in Pre-flight** — it discovers the latest release,
> downloads the `glinet_gl-mt3000-squashfs-sysupgrade.bin`, and verifies its checksum into
> `./firmware/`. The manual steps below are a fallback / reference.

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
# Note: OMR's default root password is EMPTY on first boot — just press Enter at the prompt.
# Set a password immediately: `passwd`

# Map the physical ports to interface names — DO NOT ASSUME, the OMR default for
# the Beryl AX is *opposite* of vanilla OpenWrt convention. In current OMR builds:
#   eth1 = LAN (and is what carries 192.168.100.1 — qlen 2000 = 2.5GbE)
#   eth0 = the spare/WAN-side port (qlen 1000 = 1GbE), starts DOWN until you cable home/Starlink into it
# Verify with `ip link`:
ip link
# Expect: eth0 (DOWN until you plug into it), eth1 (UP with the LAN), wlan0, wlan1

# Plug your phone into the USB-A 3.0 port (rectangular USB-A on the back, NOT USB-C power input)
dmesg | tail -20
lsusb
# Expect: Samsung/OnePlus/Pixel device entry

# Enable USB tethering on the phone (Settings → Connections → Mobile Hotspot and Tethering → USB tethering ON)
dmesg | tail -10
ip link show usb0
# Expect: usb0 interface EXISTS with a MAC but is `state DOWN` and has NO IP yet.
# That is normal at this stage — OMR doesn't bring up or DHCP an unconfigured interface.
# `usb0` will get a 192.168.42.x lease once you assign it as a WAN in Phase 5.
```

> ### Heads-up: this OMR build uses `apk`, not `opkg`
> Current OMR images switched from `opkg` to OpenWrt's new `apk` package manager — the login
> banner tells you so. If the runbook's old `opkg install kmod-usb-net-rndis` would have been
> needed (on older builds where RNDIS wasn't built-in), the modern equivalent is `apk add`.
> But in practice **RNDIS is already in the kernel modules of the official Beryl AX image** —
> dmesg will show `rndis_host ... usb0: register 'rndis_host'` automatically when you tether,
> and no package install is needed. Skip the old `opkg` step entirely.

**CHECKPOINT 3**: `usb0` exists in `ip link` output. Don't worry that it's DOWN with no IP —
that gets fixed in Phase 5 when you wire it up as a WAN. If `usb0` is **missing entirely**, the
tether isn't enumerating: check phone-side USB-tethering toggle, replug, or try a different cable.

---

## Phase 5 — Wire WANs + configure OMR (~10 min)

### 5.1 Physical wiring
- **Laptop** → whichever Beryl AX ethernet port maps to `eth1` (the one with `192.168.100.1` — verified in Phase 4). Cable stays here for setup.
- **Phone** (USB tethering ON) → Beryl USB-A 3.0 port (back of router, NOT the USB-C power input)
- **Starlink Mini / home router uplink** → the OTHER physical ethernet port (maps to `eth0`)

> **Port mapping caveat.** OMR's Beryl AX default makes the 2.5GbE port the LAN (`eth1`) and the
> 1GbE port the WAN slot (`eth0`). Counterintuitive but harmless for current Starlink Mini
> speeds (~200 Mbps caps well under 1GbE). If you ever need 2.5GbE on the WAN side, you'd
> remap `eth0` ↔ `eth1` in `/etc/config/network` — but do that from a serial console because
> the swap drops connectivity mid-change.

### 5.2 Open the OMR Settings page

LuCI top nav → **System → OpenMPTCProuter** (URL: `http://192.168.100.1/cgi-bin/luci/admin/system/openmptcprouter`).

> **Heads-up #1 — there's no separate "Wizard" page in this OMR version.** Older OMR docs
> reference `System → OpenMPTCProuter → Wizard` as a guided form; current builds put all the
> config on one long Settings page. You're not missing a page — scroll down.
>
> **Heads-up #2 — the dark theme + the kraken/ship wallpaper makes the form fields nearly
> invisible** on first view. Fields are all there; it's just a CSS contrast issue. Highlight
> or hover to see them.

#### 5.2.1 Server settings block (top of the page)
| Field | Value |
|---|---|
| Server IP | `<VPS_IP>` from `vps-credentials.txt` |
| Server username | leave default (`openmptcprouter`) |
| Server key | paste the long hex string from `vps-credentials.txt` (the `Server key`, not the `ADMIN API Server key`) |
| Default VPN | Glorytun TCP |
| Also enable | Shadowsocks (checkbox) |

#### 5.2.2 Interfaces settings block (scroll down) — **the OMR defaults are wrong, fix them**

Out of the box, OMR ships `wan1` and `wan2` configured as **MacVLAN on `eth1`**. `eth1` is your
LAN port, and MacVLAN is the wrong virtualization type for any single-WAN-per-physical-path
setup. **You must change these or no WAN ever comes up.** Three fields per WAN block:

| Field | Set to | Gotcha |
|---|---|---|
| **Type** | **Normal** | NOT MacVLAN. MacVLAN is for "multiple modems behind one VLAN-tagged switch on one port" (see `../concepts.md`). |
| **Protocol** | **DHCP client** | NOT Static address (the default). Static requires an IP+gateway you don't have; DHCP gets them from your WAN source. |
| **Physical interface** | the **physical** name (`eth0`, `usb0`, `wwan`) | The dropdown also lists *logical* names like `wan1`/`wan2`/`wan3` — picking `wan1` here creates a circular reference, the interface never binds, dashboard shows "No IP defined". Always pick a physical: `eth0`, `eth1`, `usb0`, `wwan`. |

For a typical Beryl AX setup:

| WAN slot | Physical interface | Multipath TCP | SQM | Why |
|---|---|---|---|---|
| `wan1` | **`eth0`** (Starlink / home uplink) | **Master** | ✅ enabled, fill in your real ↓/↑ Kb/s | Most reliable, biggest pipe. Master = initiates the MPTCP connection. |
| `wan2` | **`usb0`** (cellular USB tether) | **On** (not Master) | unchecked | Cellular bandwidth is too variable for fixed-rate SQM. |
| `wan3` (Add) | **`wwan`** (Wi-Fi-as-WAN to 2nd phone hotspot — Phase 9) | **On** | unchecked | Wi-Fi-as-WAN, only when 2nd phone in play. |

> See `../concepts.md` for what **Master / On / Backup / Off** actually mean in MPTCP.

Scroll to the bottom and click **Save & Apply**. Wait ~30 seconds.

### 5.3 Scheduler tweak (per use case)

```bash
ssh root@192.168.100.1

# VDI / remote desktop — survives a WAN dropping mid-stream, no combined throughput:
uci set network.globals.mptcp_scheduler='redundant'

# OR — bulk transfer / "combine internets" speeds, brief stall on link drop:
# uci set network.globals.mptcp_scheduler='default'

uci commit network
/etc/init.d/network restart
/etc/init.d/glorytun restart
```

See `../concepts.md` for the full scheduler comparison.

### 5.3 Scheduler tweak for VDI

```bash
ssh root@192.168.100.1

uci set network.globals.mptcp_scheduler='redundant'
uci commit network
/etc/init.d/network restart
/etc/init.d/glorytun restart
```

**CHECKPOINT 4**: LuCI → **Status → OpenMPTCProuter**:
- VPS: green / reachable
- wan1 (`eth0` / Starlink): green / connected
- wan2 (`usb0` / cellular): green / connected
- Glorytun tunnel: **UP** (not "VPN is not running")
- Shadowsocks: **running** (not "empty key")

SSH check:
```bash
ip -s link show gt-tun0     # bytes incrementing under load
ping -c 4 8.8.8.8           # internet
curl -s ifconfig.me         # MUST return your VPS public IP (not your local ISP IP)
```

> **If you see "VPN is not running (empty key)" but the WAN is up:** OMR auto-fetches the per-VPN
> keys (Glorytun, Shadowsocks, MLVPN) from the VPS admin API on port 65500 using your *Server
> key* — but only once it has internet AND a Save & Apply has been triggered. Hit **Save &
> Apply** again on the Settings page without changing anything; that re-runs the fetch. Wait
> 30-60s, refresh the dashboard. See `../troubleshooting.md` for deeper diagnosis.

---

## Phase 6 — Configure Wi-Fi (~5 min)

The Beryl AX has two radios. **Field-verified mapping** (the chipset string in LuCI is the ground truth — don't trust intuition; current OMR builds map them like this):

| Radio | Band | LuCI chipset string | Use for |
|---|---|---|---|
| **`radio0`** | **2.4 GHz** | `MediaTek MT7981 802.11ax/b/g/n`, Channel 1 (2.412 GHz) | Wi-Fi-as-WAN (cruise/hotel/phone-2 hotspot client) — Phase 9. Also dual-band AP for legacy/long-range clients. |
| **`radio1`** | **5 GHz** | `MediaTek MT7981 802.11ac/ax/n`, Channel 36 (5.180 GHz) | Primary client-facing AP (faster, no contention with WAN role) |

> **Why this matters:** older OMR docs (and an earlier version of this runbook) had radio0/1
> swapped. Always verify in LuCI → Network → Wireless: the radio whose chipset string
> includes `802.11ac` is the 5GHz one (802.11ac is 5GHz-only). The other is 2.4GHz.

LuCI → **Network → Wireless**:

### 6.1 Enable the 5GHz AP (radio1) — primary AP

1. Find the `radio1` (5GHz) section
2. Click **Edit** on the existing default SSID
3. **Device Configuration** tab:
   - **Operating frequency** → Mode `AX` (or `AC` if you want WiFi 5 only), Channel `36` or `auto`, Width `80 MHz`
   - **Country Code** → **set explicitly** to your country (e.g. `US - United States`). **Do NOT leave on `driver default`** — that picks regdomain `00` (world), which (a) restricts TX power and channels, and (b) **causes modern phones to silently refuse to associate to 5GHz APs**. This is the single most common "phone won't connect" cause. See `../troubleshooting.md` § "Phone hangs trying to join 5GHz AP".
4. **Interface Configuration** tab → **General Setup**:
   - Mode = `Access Point`
   - ESSID = `<your-ssid>` (e.g. `BerylAX`)
   - Network = `lan` (binds the AP to your LAN bridge so clients get an IP via DHCP)
5. **Wireless Security** tab:
   - Encryption = `WPA2-PSK` (most compatible) or `WPA2-PSK/WPA3-PSK Mixed Mode` if your devices support WPA3.
   - **Avoid pure WPA3-only on 2.4GHz with AX mode** — known Android handshake hang. See `../troubleshooting.md`.
   - Key = strong password
6. Save & Apply
7. On the Wireless Overview page, click **Enable** on the radio1 row if it isn't already broadcasting.

### 6.2 (Optional) Dual-band: enable 2.4GHz AP (radio0) with the SAME SSID

Use the same SSID + password on radio0 so devices auto-roam between bands (5GHz when close, 2.4GHz when far). Most useful if you have legacy devices or expect to use the Beryl across a large area.

1. Click **Edit** on the radio0 SSID
2. Device Configuration: Mode `N` (avoid `AX` on 2.4GHz with WPA2 — see the Android hang note in troubleshooting), Channel `auto` or `6`, Width `20 MHz`. Country Code = your country, **not** `driver default`.
3. Interface Configuration: Mode `Access Point`, ESSID = same name as radio1, Network = `lan`.
4. Wireless Security: same encryption + same password as radio1.
5. Save & Apply, then **Enable** radio0.

**Trade-off you're accepting if you enable radio0 as AP now:** you'll need to disable it (or its AP-mode SSID) before you can flip radio0 into Wi-Fi-as-WAN client mode for Phase 9 — same radio can't be AP and Client at the same time. See `../concepts.md` § "Wi-Fi modes — AP vs Client".

### 6.3 Skip 2.4GHz AP if you'll use radio0 for Wi-Fi-as-WAN soon

If you know you're about to add cruise/hotel wifi or a phone-2 hotspot as a third WAN, leave radio0 **disabled for now**. Phase 9 will flip it directly into Client mode to join the upstream wifi. radio1 (5GHz) serves all your client devices.

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

### 9.1 Flip `radio0` (2.4GHz) into Client mode

LuCI → **Network → Wireless**:
1. If `radio0` is currently running an AP-mode SSID (from Phase 6.2), **disable that SSID first** (Disable button on the SSID row). A radio can't be both AP and Client simultaneously.
2. On the `radio0` row → click **Scan**.
3. Select the cruise/hotel/phone-2 SSID → click **Join Network**.
4. Enter password (or leave blank for open wifi).
5. **Name of the new network**: `wwan` (this becomes a new logical interface).
6. **Create / Assign firewall-zone**: `wan`.
7. Save & Apply.

> The Scan → Join Network flow auto-configures Mode=Client + the right BSSID + encryption type for you. **Don't** manually flip the Mode dropdown to "Client" — the Scan flow is easier and less error-prone. See `../concepts.md` § "Wi-Fi modes — AP vs Client" for the mental model.

> **Most cruise/hotel APs are 2.4GHz only** in the public-access spectrum, which is why we use radio0 here. If the SSID you want to join is 5GHz, swap to radio1 instead — same Scan flow, but it'll cost you your 5GHz AP for client devices.

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
| Can't log into LuCI / OMR after first boot | Empty default password not realized | Try `root` + **empty** password (just press Enter) |
| Dashboard: "No IP defined" on a WAN | Physical interface dropdown set to a logical name (e.g. `wan1`) instead of a real one (`usb0`, `eth0`) | Re-edit the WAN block, pick a **physical** interface from the dropdown |
| Dashboard: "VPN is not running (empty key)" but WAN is green | Per-VPN keys never auto-fetched from VPS | Click **Save & Apply** on Settings page again (re-triggers fetch). Wait 30-60s. |
| WAN IPv4 fields highlighted red on save | Protocol left as **Static address** (default) with no IP supplied | Change Protocol to **DHCP client** — red fields disappear |
| wan1/wan2 default to MacVLAN, never connect | OMR's stock template assumes multi-modem-on-VLAN-switch topology | Set Type to **Normal**, Physical interface to a real one (`eth0` / `usb0` / `wwan`) |
| `usb0` exists but DOWN / no IP | Interface unconfigured (normal pre-wizard) | Will come up automatically once assigned as a WAN; verify `ip addr show usb0` after Save & Apply |
| `usb0` missing entirely after tether | Phone not in RNDIS mode / cable / port | Toggle USB-tethering off+on on phone; try different cable; for non-Samsung phones check USB mode = MTP can hide RNDIS |
| `opkg: not found` error | Newer OMR build switched to **`apk`** package manager | Use `apk add <pkg>` instead; for Beryl AX, RNDIS is already built-in — skip the install |
| Glorytun tunnel won't establish | VPS firewall blocking 65001, or per-VPN keys not fetched | Check `ufw`/`shorewall` on VPS; re-Save & Apply on Beryl to refetch keys |
| Cruise/hotel wifi blocks tunnel | DPI blocking UDP VPNs / VPS high ports | Switch to Shadowsocks-only (Phase 9.4) |
| Device on Beryl Wi-Fi can't reach internet | SSID attached to wrong firewall zone | Wireless → edit SSID → Network = `lan` |
| Speed < 50% of single WAN | SQM wrong values | LuCI → Network → SQM, run wizard speedtest |
| Tailscale stuck on DERP relay | Bypass UDP 41641 not active | Recheck ByPass rules, restart Tailscale |
| VDI disconnects after a few min | Glorytun TCP + CGNAT NAT expiry (upstream #2418) | Set keepalive in `/etc/config/glorytun` to 15s |

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

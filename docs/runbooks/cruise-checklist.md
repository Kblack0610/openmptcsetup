# Cruise Checklist — Beryl AX OMR Bonding

Self-contained, offline-usable checklist for building the OpenMPTCProuter bonded
setup on the **GL.iNet GL-MT3000 (Beryl AX)** and running it on an Alaska cruise.

Full detail lives in `beryl-ax.md` (sibling). Conceptual background in `../concepts.md`,
diagnostic recipes in `../troubleshooting.md`. This file is the **condensed field guide** —
keep it on the laptop because **you won't have good internet to look things up on the ship.**

Hardware: Beryl AX (runs OMR + broadcasts Wi-Fi) · Samsung S25 (USB cellular tether) ·
Starlink Mini (primary WAN, cruise-approved) · DigitalOcean SFO3 droplet (bonding endpoint).

---

## Can I build this from the cruise internet?

| Uplink | Build over it? | Why |
|---|---|---|
| **Starlink** (cruise-approved) | ✅ Yes — fine | Normal internet: low latency, high ports open, no VPN-hostile DPI. Full build works. |
| **Ship wifi** | ❌ Avoid | Satellite-backhauled, metered, high-latency, and often blocks high outbound ports (65222 SSH, 65001 tunnel). Build *and* tunnel can both fail. |
| **No internet** | Flash step only | Part A steps 3–4 (flashing) are fully local — work anywhere. |

**Best plan:** build Part A at the hotel on clean wifi. Fallback: build on the ship **over Starlink**, never over ship wifi.

## Region note (Alaska)

VPS stays in **DigitalOcean SFO3** even though you're physically in Alaska. The VPS should sit
near your *destinations* (SoCal home/corp), not near your body. On a cruise the satellite uplink
latency dominates everything; a VPS region difference is noise. DO's only US-West region is SFO anyway.

---

# PART A — Build at the hotel (~45–60 min)

Keep your **laptop on hotel wifi** (log into the captive portal once). That leaves the **S25 free**
to be the Beryl's WAN later.

## 1. Prep the laptop
```bash
cd ~/dev/openmptcsetup
./bootstrap.sh        # checks tools, makes ~/.ssh/omr_vps, downloads + verifies Beryl firmware
```
✅ Prints "Bootstrap complete" + the firmware path in `./firmware/`.

## 2. Create the VPS (DigitalOcean SFO3)
```bash
./vps-create-do.sh    # creates $6/mo Debian 12 droplet, auto-chains into vps-install.sh
```
Installs OMR, opens the firewall, reboots the VPS (~10 min total).
✅ Writes `vps-credentials.txt` containing your **Server IP + User Key**.

> Manual fallback (no doctl): deploy a Debian 12 droplet/instance via web console, then
> `echo "VPS_IP=<ip>" > .env && ./vps-install.sh`

## 3. Flash the Beryl (no internet needed)
1. Cable laptop → Beryl **LAN port**, browse `http://192.168.8.1`, finish GL.iNet first-run (any password).
2. **System → Upgrade → Local Upgrade**, pick `...mt3000...sysupgrade.bin` from `./firmware/`.
3. ⚠️ **UNCHECK "Keep settings"** — #1 brick risk.
4. Install, wait 3–5 min for reboot. Wi-Fi goes dark (normal).

## 4. Get into OMR
1. Cable laptop → Beryl **LAN port** (1GbE, not the 2.5GbE WAN port).
2. Browse `http://192.168.100.1`, log in as `root` / **empty password**.
3. Immediately set a root password (System → Administration).

✅ **Checkpoint:** page shows "OpenMPTCProuter v0.63", uptime ticking.

## 5. Give it a WAN (your S25)
1. Plug S25 into the Beryl's **USB-A 3.0 port** (NOT USB-C power).
2. On the S25: enable **USB tethering**.
```bash
ssh root@192.168.100.1
ip link show usb0     # must exist with an IP
```
✅ **Checkpoint:** `usb0` exists in `ip link`. It will be `state DOWN` with no IP at this stage — that's normal pre-wizard. It only comes up + gets DHCP once configured as a WAN in step 6.

> If `usb0` is **missing entirely**, the phone isn't tethering (toggle USB-tethering off+on, try a different cable). The runbook's old `opkg install kmod-usb-net-rndis` step is obsolete: current OMR images use `apk`, and RNDIS is built-in to the Beryl AX kernel — `dmesg | tail` shows `rndis_host ... usb0: register 'rndis_host'` the moment tethering kicks in. No package install needed.

## 6. Configure OMR (the "Wizard" is the Settings page)
LuCI → **System → OpenMPTCProuter** (single Settings page — no separate Wizard in current builds).

**Server settings:** paste Server IP + Server key from `vps-credentials.txt`. Username stays `openmptcprouter`. Default VPN = **Glorytun TCP**; also check **Shadowsocks**.

**Interfaces — FIX THE DEFAULTS.** Stock `wan1`/`wan2` ship as **MacVLAN on `eth1`** (your LAN); nothing comes up like that. Per WAN block:

| Field | Set to |
|---|---|
| Type | **Normal** (NOT MacVLAN) |
| Protocol | **DHCP client** (NOT Static — Static needs IP+gateway) |
| Physical interface | the **physical** name (`usb0`, `eth0`, `wwan`) — never a logical name like `wan1` (circular) |
| Multipath TCP | **Master** for the most reliable WAN; **On** for the rest |
| Enable SQM | ✅ for stable links (home/Starlink); ❌ for cellular (variable bandwidth) |

For just-the-S25 build: one WAN block, Physical interface `usb0`, Master, SQM unchecked. Save & Apply, wait ~30s.

✅ **Checkpoint:**
```bash
curl -s ifconfig.me   # MUST return your DigitalOcean SFO3 IP
```
That IP = proof the bonded tunnel is your egress. **This is the milestone that means it works.**

## 7. Wi-Fi AP for your devices
LuCI → **Network → Wireless** → `radio0` (5GHz) → Edit: Mode = Access Point, set SSID + WPA2/WPA3
password, Network = `lan`. Save & Apply, toggle the radio **ON**. Connect a device, confirm
`ifconfig.me` shows the SFO3 IP again.

## 8. (If you use Tailscale) ByPass rules
LuCI → **OpenMPTCProuter → ByPass**: add UDP 41641, TCP 443, UDP 3478. Lets Tailscale ride
Starlink direct instead of through the tunnel.

## 9. Back up the config — before you leave
```bash
ssh root@192.168.100.1 'tar czf - /etc/config' > ~/dev/openmptcsetup/beryl-config-backup-$(date +%F).tar.gz
```
Restore on the ship (no internet needed):
```bash
cat beryl-config-backup-YYYY-MM-DD.tar.gz | ssh root@192.168.100.1 'tar xzf - -C /'
ssh root@192.168.100.1 reboot
```

---

# PART B — On the cruise (when you board)

## 10. Add Starlink as primary WAN
1. Starlink → Beryl **WAN port** (2.5GbE).
2. Wizard → add `eth1` (Starlink) as wan1, **Master**, DHCP, enable SQM + MPTCP.
   (S25 stays as a secondary — useful near ports.)

## 11. Add ship wifi (Wi-Fi-as-WAN)
LuCI → **Network → Wireless** → `radio1` (2.4GHz) → **Scan** → join the ship SSID → name it
`wwan`, firewall zone `wan`. Clear the captive portal from a laptop (`http://example.com` —
HTTP, not HTTPS). Add `wwan` to the wizard as a **lower-priority** WAN.

## 12. Set the MPTCP scheduler for what you're doing
```bash
ssh root@192.168.100.1
# VDI / remote desktop — survives Starlink blips during ship turns (no combined speed):
uci set network.globals.mptcp_scheduler='redundant'
# OR big downloads — combine Starlink + ship wifi throughput (brief stall if a link drops):
# uci set network.globals.mptcp_scheduler='default'
uci commit network && /etc/init.d/network restart
```

## 13. If ship wifi blocks the tunnel
OMR → Settings → make **Shadowsocks the primary tunnel** (looks like HTTPS, dodges DPI),
disable Glorytun UDP if it keeps failing.

---

## MPTCP scheduler reference

The scheduler decides how packets spread across your WANs. You **can't** max combined-speed and
seamlessness at once on a single connection — pick per use case. Swap anytime with the step-12 commands.

| Scheduler | What it does | Combined speed? | Survives a link drop? | Use for |
|---|---|---|---|---|
| **default** (lowest-RTT-first) | Fills fastest path, spills overflow to next | ✅ Yes — speeds sum | ⚠️ Brief stall while it retransmits on the live path | Downloads, browsing, streaming |
| **redundant** | Sends every packet on **all** paths at once | ❌ No — speed = fastest single link | ✅ Zero hiccup — other path already delivered it | VDI, remote desktop, VoIP, gaming |
| **round-robin** | Alternates packets evenly across paths | Partial | ⚠️ Similar to default | Rarely ideal; equal-quality links |

**Why this needs the VPS at all:** GL.iNet stock only does *failover* (switching breaks live
connections) and *load-balancing* (each single connection still rides one link). True MPTCP
bonding splits one connection's packets across both WANs and **reassembles them at the VPS** —
the single public endpoint is what makes recombination possible. No VPS = no bonding.

---

## Troubleshooting quick-ref

| Symptom | Fix |
|---|---|
| Stuck on GL.iNet after flash | Forgot to uncheck "Keep settings" → U-Boot recovery: hold reset 8s on power-on, `http://192.168.1.1`, reflash |
| `usb0` missing after S25 tether | `opkg install kmod-usb-net-rndis`, replug |
| `ifconfig.me` shows local ISP, not SFO3 IP | Tunnel down — check OMR Status, verify VPS firewall ports open |
| Tunnel won't establish on ship wifi | DPI blocking VPN → switch to Shadowsocks-only (step 13) |
| Client on Beryl Wi-Fi can't reach internet | SSID attached to wrong zone → Wireless → edit SSID → Network = `lan` |
| VDI drops every few min on Glorytun TCP | CGNAT NAT expiry — set keepalive 15s in `/etc/config/glorytun` |

## Files that hold your keys/config
- `vps-credentials.txt` (laptop) — Server IP + User Key
- `/root/openmptcprouter_config.txt` (VPS) — all VPN keys
- `/etc/config/{network,wireless,glorytun,shadowsocks-libev,omr-bypass}` (Beryl) — backed up in step 9

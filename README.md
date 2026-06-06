# openmptcsetup

Channel-bonding router build that combines multiple internet links (home + cellular +
Starlink + cruise/hotel wifi) into a single low-latency tunnel for VDI, Moonlight game
streaming, and travel use.

The implementation is **[OpenMPTCProuter (OMR)](https://www.openmptcprouter.com/)** on a
**[GL.iNet GL-MT3000 (Beryl AX)](https://www.gl-inet.com/products/gl-mt3000/)** travel
router, with a $6/mo **DigitalOcean** VPS as the bonding endpoint.

> **New here?** Start with [`docs/`](docs/) — it has a reading-order guide and an index.
> Or skip to [`docs/runbooks/beryl-ax.md`](docs/runbooks/beryl-ax.md) for the primary build.

---

## Quick start

```bash
cd ~/dev/openmptcsetup

# 1. Local prep — downloads + verifies Beryl AX firmware, generates SSH key
./bootstrap.sh

# 2. Create the VPS on DigitalOcean (SFO3, $6/mo) and install OMR server on it
#    Writes VPS_IP to ./.env, then writes Server IP + key to ./vps-credentials.txt
./vps-create-do.sh

# 3. Flash the Beryl AX with the firmware in ./firmware/
#    See docs/runbooks/beryl-ax.md Phase 3 for the exact steps
#    (or docs/runbooks/cruise-checklist.md if you're racing the clock)

# 4. Configure OMR via LuCI at http://192.168.100.1
#    docs/runbooks/beryl-ax.md Phase 4 onward
```

Manual / non-doctl path: `./bootstrap.sh`, deploy a Debian 12 droplet via the web console,
then `echo "VPS_IP=<ip>" > .env && ./vps-install.sh`. Vultr LAX, Linode Fremont, or any
KVM-virtualized Debian 12 host with native IPv4 + high-port-friendly firewall works — see
[`docs/vps-options.md`](docs/vps-options.md).

---

## Topology

```
[Home internet / Starlink] ──ethernet──► Beryl AX eth0 (WAN slot)
[Phone USB tether]         ──USB-A 3.0──► Beryl AX usb0
[Phone 2 hotspot]          ──Wi-Fi──────► Beryl AX wwan (radio0, 2.4GHz client)
                                              │
                                              ▼
                            [OMR + Glorytun TCP + Shadowsocks-MPTCP]
                                              │
                                              ▼
                          [DigitalOcean SFO3 — bonding endpoint]
                                              │
                                              ▼
                            [Internet / Tailscale to home Mac Studio]

Beryl AX 5GHz Wi-Fi (radio1) ──► your laptop, phones-as-clients, etc.
```

See [`docs/why-vps.md`](docs/why-vps.md) for the architectural rationale (why the VPS is
required and what it actually does), and [`docs/concepts.md`](docs/concepts.md) for the
networking concepts the runbooks assume.

---

## Repo layout

```
.
├── README.md                       ← this file (project entry point)
├── bootstrap.sh                    ← local prep: firmware download + SSH key
├── vps-create-do.sh                ← provision DO droplet, chain into vps-install.sh
├── vps-install.sh                  ← install OMR server on a Debian 12 host
├── firmware/                       ← Beryl AX OMR sysupgrade .bin (downloaded by bootstrap)
└── docs/
    ├── README.md                   ← documentation index + reading-order guide
    ├── concepts.md                 ← MPTCP scheduler / role / MacVLAN / TCP-vs-UDP / topology / Wi-Fi modes
    ├── testing.md                  ← verification recipes — proof-of-tunnel, throughput, jitter, Tailscale
    ├── playbook.md                 ← command cheatsheet for live monitoring + debugging
    ├── troubleshooting.md          ← symptom-indexed failure modes and fixes
    ├── why-vps.md                  ← long-form: why bonding requires a public endpoint
    ├── vps-options.md              ← provider/region comparison
    └── runbooks/
        ├── beryl-ax.md             ← primary build (GL-MT3000, official OMR image)
        ├── cruise-checklist.md     ← condensed offline field guide for hotel + cruise
        └── r6s.md                  ← alternative build (NanoPi R6S + vanilla OpenWrt)
```

---

## Use cases this build serves

1. **Corporate VDI** (Citrix HDX / VMware Horizon Blast) — jitter-sensitive, run with
   `redundant` MPTCP scheduler for seamless link-loss survival
2. **Moonlight game streaming** — latency-sensitive UDP, Tailscale-direct via OMR-ByPass
3. **General travel redundancy** — Starlink + cellular + hotel/ship wifi, all bonded

---

## Top-level gotchas

A few things that bite people on first build (full list in
[`docs/troubleshooting.md`](docs/troubleshooting.md)):

- ✅ **The one test that proves bonding works:** from a device behind the Beryl,
  `curl -s ifconfig.me` returns your VPS public IP (not your home ISP IP). See
  [`docs/testing.md`](docs/testing.md) § "Proof-of-tunnel".
- 🔍 **Live monitoring commands** when you want to see what's actually happening:
  [`docs/playbook.md`](docs/playbook.md) — interface state, MPTCP subflows, scheduler,
  service health, the lot.
- ⚠️ **Flashing the Beryl AX**: UNCHECK "Keep settings" or you'll brick the boot.
- ⚠️ **OMR's default LAN IP** after flashing is `192.168.100.1`, not GL.iNet stock `192.168.8.1`.
- ⚠️ **First LuCI login**: username `root`, **empty password** — just press Enter.
- ⚠️ **OMR default WAN config is MacVLAN on `eth1`** (your LAN port). Must change Type to
  Normal, Protocol to DHCP, Physical interface to a real one (`usb0`, `eth0`, `wwan`).
- ⚠️ **"VPN is not running (empty key)"**: hit Save & Apply again on the Settings page to
  re-trigger the per-VPN-key auto-fetch from the VPS.
- ⚠️ **Beryl AX port mapping in OMR**: `eth1` = LAN (2.5GbE port), `eth0` = WAN slot (1GbE
  port) — opposite of vanilla OpenWrt.
- ⚠️ **Beryl AX Wi-Fi country code**: leave it on `driver default` (= regdomain `00`) and
  modern phones silently refuse to join 5GHz. Set it to your actual country in
  Network → Wireless → Edit → Device Configuration.
- ⚠️ **Beryl AX radio mapping**: `radio0` = 2.4GHz, `radio1` = 5GHz (verify via the chipset
  string in LuCI — `802.11ac` = 5GHz). Earlier doc versions had this backwards.
- ⚠️ **Building from cruise wifi**: ship wifi often blocks the high ports OMR uses. Build
  from Starlink or cellular, not ship wifi.

---

## License / status

Personal infrastructure project. Scripts are tuned for the author's setup; review before
running. Not officially affiliated with OpenMPTCProuter or GL.iNet.

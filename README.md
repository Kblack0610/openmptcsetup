# OMR Setup — Beryl AX + Vultr LAX

Channel-bonding router build for combining Starlink + cellular + (optional cruise/hotel wifi) into a single low-latency tunnel for VDI and Moonlight.

## Files in this repo

| File | What it is |
|---|---|
| `RUNBOOK-BerylAX.md` | **Primary build guide.** GL.iNet GL-MT3000 (Beryl AX) with official OMR firmware. Recommended path. |
| `RUNBOOK-R6S.md` | Alternative build for NanoPi R6S (more complex, more capable). Kept for future expansion. |
| `VPS-options.md` | VPS provider comparison and Vultr LAX recommendation. |
| `Runbook_short.md` | High-level checklist version of the runbook. |
| `why-vps.md` | Explainer: why a public reassembly endpoint is required for true bonding. |
| `bootstrap.sh` | Downloads the official OMR Beryl AX firmware, verifies SHA256, stages SSH keys. |
| `vps-create-do.sh` | Provisions the VPS on DigitalOcean (SFO3, $6/mo) via doctl. |
| `vps-install.sh` | SSHes into the fresh VPS and installs the OMR server. |

---

## Quick start

```bash
cd ~/dev/openmptcsetup

# 1. Local prep — downloads firmware, generates SSH key
./bootstrap.sh

# 2. Create the VPS on DigitalOcean via doctl (SFO3, $6/mo)
#    Writes VPS_IP to ./.env automatically and chains into vps-install.sh
./vps-create-do.sh

# 3. Flash the Beryl AX with the firmware in ./firmware/
#    See RUNBOOK-BerylAX.md Phase 3 for the exact steps

# 4. Configure OMR via LuCI wizard at http://192.168.100.1
#    See RUNBOOK-BerylAX.md Phase 4 onward
```

Alternative: if you'd rather click through the DO web console (or use Vultr), run `./bootstrap.sh`, manually deploy the VPS, then `echo "VPS_IP=<ip>" > .env && ./vps-install.sh`.

---

## Architecture

```
[Starlink Mini] ──ethernet──► Beryl AX WAN port
[Galaxy S25 USB tether] ──USB-C──► Beryl AX USB
[Optional 3rd WAN — OnePlus tether via USB hub, cruise wifi via Wi-Fi-as-WAN]
                                  │
                          [OMR + Glorytun TCP + Shadowsocks-MPTCP]
                                  │
                          [Vultr LAX VPS (Glorytun + SS server)]
                                  │
                          [Internet / Tailscale to home Mac Studio]

Beryl AX 5GHz Wi-Fi ──► [OnePlus client + XREAL Pros]
```

---

## Use case priority

1. **Corporate VDI** (Citrix HDX / VMware Horizon Blast) — TCP, jitter-sensitive
2. **Moonlight game streaming** — UDP, latency-sensitive
3. **General internet redundancy** — Starlink + cellular failover

---

## Known gotchas

- ⚠️ When flashing the Beryl AX with the OMR sysupgrade image, **UNCHECK "Keep settings"** or you'll brick the boot (different config layouts).
- ⚠️ OMR's default LAN IP after flashing is `192.168.100.1`, not GL.iNet's stock `192.168.8.1`.
- ⚠️ Glorytun **UDP** drops Starlink after a few minutes from CGNAT NAT mapping expiry — use Glorytun **TCP** + Shadowsocks-MPTCP for stable bonded sessions.
- ⚠️ Tailscale-over-OMR collapses to ~5 Mbps without ByPass — always configure OMR-ByPass for Tailscale ports (41641/UDP, 3478/UDP, 443/TCP).
- ⚠️ For local-LAN traffic (OnePlus to Mac Studio at home), add an OMR-ByPass rule for your home subnet to avoid the unnecessary VPS roundtrip.

See each runbook's troubleshooting table for more.

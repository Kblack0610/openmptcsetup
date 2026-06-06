# VPS Options for OMR Endpoint

## TL;DR — DigitalOcean SFO3 or Vultr LAX, both fine

This repo's scripts (`vps-create-do.sh` / `vps-install.sh`) default to **DigitalOcean SFO3,
$6/mo, Debian 12**. **Vultr LAX** is the equally-clean alternative that the rest of this
doc was originally written around — same price tier, ~5-15ms RTT to SoCal, KVM, high ports
open, no DPI nonsense. Pick whichever you already have an account at. The rest of this doc
explains the requirements any VPS must satisfy, why Vultr/DO win, and when you might pick
something else.

> The original recommendation in this doc was Vultr LAX. The scripts ended up on DO SFO3
> because the author already had `doctl` authenticated for another project. Either is right
> for a SoCal-anchored bonding endpoint.

---

## Hard requirements (any VPS must satisfy these)

| Requirement | Why |
|---|---|
| **KVM virtualization** (not OpenVZ) | OpenVZ shares the host kernel — you can't load custom MPTCP kernel modules. OMR's install script refuses to run on OpenVZ. |
| **Native public IPv4** | The reassembly endpoint must be reachable by both your WAN paths via a single, stable public IP. NAT'd / shared-IP plans don't work. |
| **No deep packet inspection / VPN throttling** | Some budget providers (most notably some Hetzner ranges and AWS Lightsail under heavy use) interfere with VPN-like traffic. |
| **Unmetered or generous bandwidth** | At least 1 TB/month at 1 Gbps egress. Bonded traffic ~2-3x your nominal usage during peaks. |
| **Allows high ports (60000+)** | OMR uses 65001, 65101, 65222, 65400, 65500. Some providers (Hetzner's default firewall, OVH's "Game" range) block these unless explicitly opened. |

---

## Provider comparison (US West Coast latency from SoCal)

| Provider | Region | Spec @ ~$6 | RTT from SoCal | Notes |
|---|---|---|---|---|
| **Vultr** ⭐ | Los Angeles (LAX) | 1 vCPU, 1 GB, 25 GB SSD, 1 TB | 5-15 ms | Cleanest default. KVM, native IPv4, high ports open. Easy console. |
| **DigitalOcean** | San Francisco 3 (SFO3) | 1 vCPU, 1 GB, 25 GB SSD, 1 TB | 15-25 ms | Solid network, good docs. Slightly farther = slightly more latency. |
| **Linode/Akamai** | Fremont, CA | 1 vCPU, 1 GB, 25 GB SSD, 1 TB | 15-25 ms | Cheaper at $5/mo. Reliable, good for OMR. |
| **Hetzner Cloud** | Hillsboro, OR (US-West) | 2 vCPU, 4 GB, 40 GB | 25-35 ms | $4-5/mo, massive resources for the price. **But**: their default firewall blocks high ports, their abuse team is aggressive about VPN traffic complaints. |
| **OVH** | San Jose | 1 vCPU, 2 GB | 10-20 ms | DDoS protection sometimes mis-classifies bonded VPN traffic. Workable but tunable. |
| **AWS Lightsail** | Los Angeles | 1 vCPU, 1 GB, 40 GB, 2 TB | 5-15 ms | $5/mo but bandwidth overage is **expensive** ($0.09/GB) — risk if you misjudge usage. |
| **Hostinger / IONOS / smaller VPS shops** | Varies | $3-5/mo | Varies | Many oversold, some on OpenVZ. Avoid unless you've personally tested. |

---

## Why Vultr LAX wins for this specific use case

1. **Lowest practical latency to SoCal users.** LAX is the geographic minimum-RTT datacenter for someone in Del Mar.
2. **Predictable pricing.** $6/mo flat, 1 TB bandwidth included, no surprise overage bills like Lightsail.
3. **Fast deploy.** ~60 seconds from clicking "Deploy" to SSH-ready.
4. **High-port-friendly.** No default firewall on Vultr's network (you control ufw inside the VM).
5. **OMR install script works first try.** Their Debian 12 image is clean, well-supported by OMR's installer.
6. **API for automation** if you ever want to spin up/tear down VPSes programmatically.

---

## When you'd pick something other than Vultr LAX

- **You're already on DigitalOcean** and have $200+ credit to burn → SFO3 works fine.
- **You need massive bandwidth (10+ TB/mo)** → Hetzner is dramatically cheaper, but be ready to whitelist the firewall and tune away from their abuse triggers.
- **You're on the east coast / Europe / Asia** → pick a Vultr/DO/Linode region near you instead. SoCal-LAX-anchored config doesn't apply.
- **You hate Vultr for some reason** → DigitalOcean SFO3 is the closest second.

---

## Anti-recommendations

- ❌ **OpenVZ-based hosts** (Contabo's cheapest tier, some RamNode, LowEndBox specials) — OMR won't install.
- ❌ **Oracle Cloud "Always Free"** — limited regions, opaque networking restrictions, frequent outbound port blocking.
- ❌ **AWS EC2** (regular, not Lightsail) — overkill, expensive bandwidth, complex.
- ❌ **Residential ISP "static IP" / Comcast Business at home** — your home upload bandwidth becomes the bonded ceiling (defeats the point of bonding).
- ❌ **Anything in a country with hostile-to-VPN networking (e.g. some China-edge providers)** — irrelevant here but worth noting.

---

## Sizing — when 1 vCPU / 1 GB isn't enough

For your use case (bonding Starlink + 1-3 cellular WANs, ~100-300 Mbps aggregate):
- 1 vCPU / 1 GB is plenty
- CPU is the bottleneck for Glorytun encryption, NOT RAM
- Upgrade to 2 vCPU ($12/mo) only if you saturate the bond and `htop` on the VPS shows the CPU pegged

For a small group / family use case (4+ bonded clients):
- 2 vCPU / 2 GB ($12/mo Vultr or equivalent)

---

## Recommendation

**Default**: Vultr LAX, $6/mo, Debian 12, KVM, 1 vCPU, 1 GB, 25 GB SSD.

Run `./vps-install.sh` after deploying — it handles the OMR install + firewall + key extraction automatically.

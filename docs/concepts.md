# Concepts — what the OMR knobs actually mean

Reference doc for the *why* behind each setting. If you just want command-by-command steps,
go to `runbooks/beryl-ax.md`. If something's broken, go to `troubleshooting.md`. This file is
where you come when a runbook says "set X to Y" and you want to understand the choice.

Topics:
1. [Why bonding needs a VPS](#why-bonding-needs-a-vps) — the single reassembly endpoint
2. [GL.iNet stock vs OMR — "redundancy" vs true bonding](#stock-failover-vs-omr-bonding)
3. [MPTCP scheduler](#mptcp-scheduler) — `default` / `redundant` / `roundrobin`
4. [Per-WAN MPTCP role](#per-wan-mptcp-role) — Master / On / Backup / Off
5. [Interface type](#interface-type) — Normal / MacVLAN / Bridge
6. [TCP vs UDP and QUIC](#tcp-vs-udp-and-quic) — why MPTCP wraps everything in an outer TCP tunnel
7. [LAN vs WAN topology](#lan-vs-wan-topology) — behind home router vs replacing it

---

## Why bonding needs a VPS

You can't physically combine two internet links *at home* into one connection without a
single public endpoint that knows how to reassemble the split traffic. The math:

- Your home WAN egresses through one public IP (e.g., from your ISP).
- Your cellular tether egresses through another (the carrier's CGNAT block).
- They're on completely different paths through the internet.
- If you split a single TCP connection's packets across both, the *destination server* sees
  packets arriving from two different source IPs — to TCP, those look like two different
  connections, and the server will just drop them as malformed.

The VPS solves this by being the **single reassembly endpoint**:

```
   ┌─ packet over home ─┐
   │                    ▼
You ─── packet over cell ─►  VPS ── reassembled stream ──► actual destination
   │                    ▲
   └─ packet over wifi ─┘
```

Both your WANs tunnel everything to the same VPS. The VPS reassembles the split packets back
into one coherent stream, unwraps them, and forwards them to the actual destination using
its own single public IP. The destination only ever sees the VPS — clean.

This is why all OMR-style bonding solutions need a server somewhere in the cloud. It's not
optional; it's the architectural pivot point. See `why-vps.md` for the longer explainer.

---

## Stock failover vs OMR bonding

GL.iNet's stock firmware (and most travel-router firmware) offers two things people call
"multi-WAN":

- **Failover.** WAN1 dies → switch to WAN2. Only one link carries traffic at a time. Active
  TCP connections **break** when the switch happens (your VDI session drops, your SSH dies).
  Call this "redundancy" but understand the brittleness.
- **Load balancing.** Different connections take different WANs. Connection A goes via home,
  connection B via cellular. Any *single* connection still rides one link (no combined speed
  for one download), and because each WAN has its own public IP, sticky/authenticated
  sessions break.

What stock can **not** do: take one TCP connection, split its packets across both WANs,
reassemble them, and have a single stream that survives either link dying mid-stream without
dropping. That's **MPTCP bonding**, and it physically requires the VPS as the reassembly
point. No VPS = no real bonding = no seamless mid-stream link loss.

---

## MPTCP scheduler

Once you have MPTCP, the **scheduler** decides how packets are distributed across the active
paths. The trade-off is fundamental and per-connection: **you cannot maximize combined
throughput and seamlessness at the same time**. Pick per use case.

| Scheduler | What it does | Combined speed? | Survives a link drop mid-stream? | Best for |
|---|---|---|---|---|
| **default** (lowest-RTT-first) | Fills the fastest path first, spills overflow to the next | ✅ Yes — speeds sum | ⚠️ Brief stall while MPTCP detects + retransmits | Big downloads, browsing, streaming |
| **redundant** | Sends **every packet on every active path** | ❌ No — speed = your single fastest link | ✅ Zero hiccup — the other path already delivered it | VDI, remote desktop, VoIP, gaming, anything latency-sensitive |
| **roundrobin** | Alternates packets across paths evenly | Partial | ⚠️ Similar to default | Lab / equal-quality links; rarely ideal in practice |
| **BLEST** (if exposed) | Aggregation that avoids the slow path stalling the fast one | ✅ Mostly | Better than default | Paths with very different latencies (cellular + Starlink mix) |

Practical rule:

- "I want my VDI session to NOT drop when Starlink blinks during a ship turn" → `redundant`
- "I want to combine my home + cellular bandwidth for a big download" → `default`

Swap live:

```bash
ssh root@192.168.100.1
uci set network.globals.mptcp_scheduler='default'    # or 'redundant', 'roundrobin'
uci commit network && /etc/init.d/network restart
```

---

## Per-WAN MPTCP role

Separate knob from the scheduler. While the scheduler decides how *packets* are distributed
across active paths, the **role** flag (per WAN) decides what *job* this specific path does
in the MPTCP connection.

| Role | What it does |
|---|---|
| **Master** | This WAN is the *initiating* subflow. The first SYN of a new MPTCP connection goes out on this interface; other WANs MP_JOIN as additional subflows once the bootstrap succeeds. Put your most reliable WAN here — if the master is flaky at bootstrap time, new connections can't start. |
| **On** | Actively participates as a subflow alongside the master. Carries data per the scheduler's decisions. This is the "yes, use this WAN for bonding" setting. |
| **Backup** | Joins the MPTCP connection but **only carries traffic when the active paths fail**. Useful for expensive metered data (engages only when unmetered links die) or a true failover-only path. |
| **Off** | Not part of MPTCP at all. Interface may still exist for non-MPTCP traffic / bypass rules. |

Why have a "Master"? TCP needs *somebody* to send the first SYN. With multiple WANs, MPTCP
picks one as the bootstrap path, then advertises the others. After bootstrap, the master is
just one of many active subflows — it's not specially favored for ongoing traffic.

Sensible defaults by scenario:

| Scenario | Roles |
|---|---|
| Home test (home eth + cellular + 2nd phone) | `eth0` = Master, `usb0` = On, `wwan` = On |
| Cruise / VDI (Starlink + ship wifi + cellular) | `eth0` (Starlink) = Master, ship wifi = Backup or On, cellular = Off (saves data) or On (in port) |
| Hotel build (just cellular) | `usb0` = Master (only WAN) |

---

## Interface type

OMR / OpenWrt lets you set each WAN interface's "Type" — the choices that matter:

- **Normal** — use a physical interface (or pre-existing logical one like `wwan`) directly.
  This is the right choice for almost every realistic setup. Each WAN = one physical path =
  Normal.
- **MacVLAN** — create a virtual sub-interface on top of a physical one, each with its own
  MAC address. Looks like multiple NICs sharing one wire. Useful **only** when you have
  multiple modems behind a VLAN-tagged switch all coming in through one Beryl ethernet port.
  OMR ships MacVLAN as the **default** for `wan1`/`wan2` on the Beryl AX template, on the
  assumption you have the "pro multi-modem rack" setup. For 99% of users, this is wrong.
  See the MacVLAN deep-dive below.
- **Bridge** — combine multiple physical interfaces into one L2 segment. Not used for WAN
  configuration in OMR; LAN-side bridging only.

### Mental model for MacVLAN

| Topology | Use MacVLAN? |
|---|---|
| One physical port, one WAN | No — use Normal |
| One physical port, multiple modems behind a VLAN switch | **Yes** — one MacVLAN per VLAN |
| Multiple physical ports, one WAN per port | No — Normal on each |
| One port, multiple Docker containers needing LAN presence | Yes (containers use case) |
| USB tether / Wi-Fi-as-WAN | No, never |

If your three WANs are on three physical paths (home eth, USB tether, Wi-Fi client) — like
the standard Beryl AX setup — there's nothing for MacVLAN to slice and it just adds
brittleness. **Use Normal.**

---

## TCP vs UDP and QUIC

This used to be a clean answer. Then HTTP/3 happened.

**Traditional split (still mostly true by connection count):**
- TCP: HTTP/1.1/2, HTTPS, SSH, email, file transfer, most APIs
- UDP: DNS, NTP, VoIP, video calls, online games

**The QUIC shift (~2019-now):** HTTP/3 runs over UDP via the QUIC protocol. Google, Cloudflare,
Meta, Netflix, YouTube and most major CDNs migrated significant HTTPS traffic to QUIC. By
byte volume on big CDNs, ~30-40% of HTTPS is now HTTP/3 (UDP). So "load YouTube" is now a
substantial UDP flow even though it *feels* like web browsing.

**Implication for MPTCP / your setup:** MPTCP is literally an extension of TCP. You can't
MPTCP-bond a raw UDP stream — there's no TCP state machine to extend.

OMR sidesteps this by wrapping **everything** (TCP, UDP, ICMP, all of it) in an outer
**Glorytun TCP tunnel**, and *that tunnel* is what's MPTCP-bonded across your WANs:

```
Your laptop's QUIC/UDP packet
       │
       ▼
Beryl wraps it in Glorytun TCP (MPTCP)
       │
       ├── subflow over eth0 (home)        ─┐
       ├── subflow over usb0 (cellular)    ─┤  packet bits split per scheduler
       └── subflow over wwan (phone 2)     ─┘
       │
       ▼
VPS reassembles, unwraps, forwards to real destination as the original UDP/TCP
```

So whether your apps are TCP or UDP doesn't matter for bonding — it all rides the outer TCP
tunnel, which is MPTCP-aware.

OMR offers Glorytun in two variants:

- **Glorytun TCP** — tunnel is itself TCP → MPTCP-bondable → real aggregation across paths.
  Slight TCP-over-TCP overhead for inner TCP traffic, irrelevant in practice. **Default.**
- **Glorytun UDP** — lighter, lower per-packet overhead. But UDP can't be MPTCP'd at the
  tunnel layer, so multi-path aggregation works differently (per-flow rather than
  per-connection). Use only when you have a reason to.
- **Shadowsocks-libev (MPTCP-patched)** — TCP-based proxy that looks like HTTPS traffic.
  Best for dodging DPI on cruise / hotel / corporate wifi that blocks plain VPNs. Make this
  the **primary tunnel** on the cruise (`Phase 9.4` in `runbooks/beryl-ax.md`).

---

## LAN vs WAN topology

The direction matters. Get this wrong and you lock yourself out.

- **LAN** = "the side your devices connect **to**" — laptop, phones-as-clients, etc. The
  Beryl serves DHCP here (`192.168.100.x`).
- **WAN** = "the side the Beryl uses to **reach the internet**" — home modem, USB tether,
  ship wifi.

**Never set LAN's Physical interface to `usb0` or `wwan`** thinking "that's where my internet
comes from" — you'd be telling the Beryl to serve DHCP out to your phone's tether, and your
laptop loses its way back into the router. Factory reset to recover.

### Two ways to wire the Beryl into your home

**Option A — Beryl behind the home router (recommended for testing).**

```
[ISP] → [Home router] → [Beryl WAN port (eth0)]
                              │
                              ▼
                        [Beryl LAN (eth1)] → your devices via wifi or cable
```

Home router keeps doing its thing for other devices. Beryl gets a DHCP lease from the home
router (e.g., `192.168.1.115`), uses that as one of its bonded WANs. Mild double-NAT — fine
for OMR testing.

**Option B — Beryl replaces the home router.**

```
[ISP modem] → [Beryl WAN port (eth0)] → [Beryl LAN] → all your devices
```

Cleaner topology, no double-NAT. But you've made the Beryl the only router for your
network — anyone else in the house is affected. Don't do this casually.

For development/testing **go with A**. For long-term primary-use, B is fine if you're ready
to maintain it as your house's router.

### Beryl AX port mapping gotcha

In current OMR builds, the Beryl AX physical port mapping is **opposite** of vanilla OpenWrt:

| Physical port (label on case) | Speed | Interface name in OMR | OMR default role |
|---|---|---|---|
| WAN | 2.5GbE | `eth1` | **LAN** (yes, really) |
| LAN | 1GbE  | `eth0` | spare / WAN slot |

So when the runbook says "plug Starlink into the WAN port," reality is: plug Starlink into
whichever **physical port maps to `eth0`** — which in this firmware is the port physically
labeled "LAN." Always verify with `ip link show` after first boot — don't trust the case
labels.

Why is it this way? OMR's template puts the LAN on the faster port because bonded throughput
between LAN devices and the VPS tunnel can saturate the LAN side. If your WAN sources max
out under 1GbE (Starlink Mini ~200 Mbps, most home internet < 1Gbps), the 1GbE WAN port is
fine. If you ever need 2.5GbE on the WAN side, remap `eth0` ↔ `eth1` in `/etc/config/network`
from a serial console (the swap drops connectivity mid-change).

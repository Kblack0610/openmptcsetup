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
8. [Wi-Fi modes — AP vs Client](#wifi-modes-ap-vs-client) — same radio, opposite roles
9. [Bridges and `br-lan`](#bridges-and-br-lan) — why LAN needs to be a virtual switch
10. [OMR's internal interfaces](#omr-internal-interfaces) — what `omrvpn` and `omr6in4` actually are
11. [WAN sources — counting paths and trading them off](#wan-sources-counting-and-tradeoffs) — how many WANs the Beryl AX can do and what each costs
12. [Ethernet tethering as a WAN source](#ethernet-tether-as-wan) — swapping a phone in for the home cable
13. [WAN slot configuration — every field explained](#wan-slot-fields) — the OMR Settings page field-by-field
14. [Wi-Fi-as-WAN deep dive](#wifi-as-wan-deep-dive) — Scan + Join, mode/channel, travelmate auto-switching
15. [Multiple WANs to the same upstream](#multiple-wans-same-upstream) — `eth0 + wwan_home`, redundancy vs throughput
16. [SQM with cellular WANs — when to bother](#sqm-with-cellular-wans) — and why mostly not
17. [Verifying all WANs are actively bonded](#verifying-bonded-wans) — dashboard, SSH, MPTCP introspection
18. [Device fleet for a mobile bonded build](#device-fleet) — how many phones, SIMs, cables, batteries to carry

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

---

## Wi-Fi modes — AP vs Client {#wifi-modes-ap-vs-client}

A Beryl AX has two radios — `radio0` (2.4GHz) and `radio1` (5GHz) — and each can be in
one of several modes at a time. The two that matter for this build are **Access Point** and
**Client**.

| Mode | What the radio does | Who's the AP, who's the client | OMR / OpenWrt zone |
|---|---|---|---|
| **Access Point** | Broadcasts a SSID, accepts incoming connections | Beryl is the AP; your laptop/phone are clients | `lan` (clients land on your LAN bridge → get a 192.168.100.x lease → reach internet through the bonded tunnel) |
| **Client** (a.k.a. STA / "Join Network") | Connects outward to an upstream SSID | Beryl is a client; some other device (cruise wifi AP, phone hotspot) is the AP | `wan` zone (the new `wwan` interface becomes a *source of internet* the Beryl can bond) |

### The critical constraint

A radio is in **one mode at a time**. You can't run radio0 as both "the 2.4GHz AP for my laptop" AND "the 2.4GHz client joining ship wifi" simultaneously. Same physical radio, opposite roles, mutually exclusive.

This is why the build typically reserves the bands by role:

| Radio | Band | Suggested role |
|---|---|---|
| `radio0` | 2.4 GHz | **Wi-Fi-as-WAN client** (joins ship wifi / hotel wifi / phone-2 hotspot) — most public/portable APs are 2.4GHz |
| `radio1` | 5 GHz | **Client-facing AP** (your laptop/phone connect to it) — faster, less contention with the WAN job |

If you want dual-band AP for client devices (5GHz close, 2.4GHz for range), you give up Wi-Fi-as-WAN until you flip radio0 back to Client mode. Pick based on where you are: at home or in a hotel room with ethernet, dual-band AP is fine; on a cruise where ship wifi is your WAN, radio0 belongs in Client mode.

### How to switch modes — use Scan / Join Network, not the Mode dropdown

LuCI's wireless edit dialog has a Mode dropdown that includes `Client`. You can change it there, but you also have to manually enter the upstream BSSID, encryption type, password — all by hand. Easier and less error-prone:

1. Wireless Overview → click **Scan** on the radio you want as a Client
2. Pick the upstream SSID from the scan results → click **Join Network**
3. Enter the upstream password, set "Name of the new network" → `wwan`, set firewall zone → `wan`
4. Submit

That flow auto-configures Mode=Client + BSSID + encryption + creates the `wwan` interface in one shot. Save & Apply on the parent page.

### Why the network zone matters

For AP mode, Network = `lan` is correct: the radio joins the LAN bridge, clients get DHCP from the Beryl, traffic flows out via the bonded WANs.

For Client mode, Network = `wwan` on firewall zone `wan` is correct: the radio is a *source of internet*, not a destination for clients. If you accidentally put a Client-mode interface on the `lan` zone, the firewall blocks it from being a WAN and OMR can't bond it.

### Common confusion: "should my phone connect to the Beryl's wifi for phone-2 hotspot?"

No — direction is reversed. For phone-2-as-WAN:
- **Phone 2 hosts** a Mobile Hotspot (it's the AP)
- **Beryl joins** phone 2's hotspot in Client mode on radio0 (it's the client)
- Beryl then has internet *from* phone 2, which it bonds with its other WANs

You only "connect your phone to the Beryl's wifi" for phones that are clients of your bonded setup (i.e., they receive internet from the Beryl). Phones that *provide* internet to the Beryl are upstream APs, and the Beryl joins them.

---

## Bridges and `br-lan` {#bridges-and-br-lan}

A **bridge** in Linux networking is a virtual L2 switch implemented in the kernel. You give it a name (`br-lan`) and add *member ports* — physical interfaces (`eth1`), Wi-Fi interfaces (`phy1-ap0`), VLAN sub-interfaces — and the kernel forwards frames between all members as if they were ports on a real Ethernet switch.

The bridge itself becomes an interface you can assign an IP to. Anything on any member port reaches that IP. Anything *behind* that IP (the DHCP server, the firewall rules) sees traffic from all members as if it arrived on one logical LAN.

### Why Wi-Fi specifically needs this

When you create an Access Point in OpenWrt, the kernel materializes a virtual interface called `phy1-ap0` (or `wlan0`, depending on the driver). `hostapd` runs on it and handles WPA authentication. But `phy1-ap0` has no IP, no DHCP server, no firewall policy of its own — it's just a frame source/sink at L2.

For a Wi-Fi client to:
- Get an IP via DHCP
- Reach the router's gateway
- Cross into the WAN side

…something has to wire `phy1-ap0` to the same L2 segment as the LAN. The standard mechanism is a bridge:

```
  br-lan  (192.168.100.1, dnsmasq listens here, firewall zone "lan")
   ├── eth1        (wired LAN port — laptops, switches, etc.)
   └── phy1-ap0    (Wi-Fi AP — phones, wireless laptops)
```

Now a DHCP request from a Wi-Fi client arrives on `phy1-ap0`, bridges to `br-lan`, hits dnsmasq, gets answered, and returns the same way. The client and a wired laptop are indistinguishable from the firewall's perspective — both on the LAN.

### What goes wrong without a bridge

If `lan` is configured against a raw port (`network.lan.device='eth1'` rather than `'br-lan'`), the IP and dnsmasq live on `eth1` only. Wired clients work. But `phy1-ap0` has no path to anything — it's an orphaned L2 interface. WPA handshake completes because `hostapd` runs locally on the radio and only needs the password to match. DHCP fails because the frames never reach dnsmasq.

The symptom: phone associates, holds for ~18 seconds, drops with "couldn't connect." See `troubleshooting.md` § "Phone associates to Wi-Fi but never gets an IP."

### Why most OpenWrt builds ship `lan` as a bridge by default

Single-port "switches" exist as bridges in stock OpenWrt precisely so that adding Wi-Fi later is a no-op — `option network 'lan'` on the wireless config plugs `phy1-ap0` into the existing bridge automatically. The Beryl AX (gl-mt3000) OMR build is a notable exception: it ships `lan` as raw `eth1`, and you have to convert it manually the first time you enable Wi-Fi.

---

## OMR's internal interfaces — `omrvpn` and `omr6in4` {#omr-internal-interfaces}

When you first look at LuCI's Network → Interfaces page on a fresh OMR install, you see two interfaces that don't correspond to any physical hardware: `omrvpn` and `omr6in4`. Both are tunnels from the router to the VPS. They are the substrate that the entire bonded setup runs on.

### `omrvpn` — the aggregation tunnel

This is **the main MPTCP tunnel from your router to the VPS** — the single logical pipe that all LAN traffic gets shoved into. It's typically a `tun0` device with a DHCP-assigned address pulled from the VPS side.

What's actually happening underneath:

```
[LAN client] → br-lan → omrvpn (tun0) ← single logical tunnel from client's POV
                          │
                          ↓
              ┌───────────┴───────────┐
            wan1 (eth0)            wan2 (usb0)    ← physical WANs
              ↓                       ↓
             ISP A                   ISP B         ← different egress paths
              └───────────┬───────────┘
                          ↓
                         VPS  → real internet
```

`omrvpn` is what your client devices think they're using. The Beryl multiplexes traffic across `wan1` + `wan2` underneath using MPTCP (or `glorytun`, `mlvpn`, `dsvpn` depending on which protocol you picked for the primary tunnel). The VPS reassembles and forwards to the actual destination.

If `omrvpn` shows green and is pulling DHCP packets (any non-zero RX/TX), the bonded tunnel is up. If it's red or "Network device is not present," the VPN didn't start — usually a key issue (see `troubleshooting.md` § "VPN not running — empty key").

This is the interface to think about when you ask "is my bonded internet working?" — not the individual WANs. The WANs being green just means they have a path to the VPS; `omrvpn` being green means they're successfully aggregated.

### `omr6in4` — IPv6 over the IPv4 tunnel

This is an **IPv6-in-IPv4 tunnel** (RFC 4213), used to give LAN clients real IPv6 connectivity by wrapping IPv6 packets inside IPv4 ones and sending them to the VPS, which decapsulates and forwards them onto the v6 internet.

Why it exists: your home ISP and your cellular carrier may not hand you native IPv6, but the VPS does. Tunneling lets LAN devices get a v6 prefix delegated from the VPS even when the underlying WANs are v4-only.

In a fresh install, `omr6in4` is usually idle ("Not started on boot", 0 packets) because:
- The default OMR setup doesn't enable v6 on the VPS unless you opted in during install
- Most apps work fine over v4 alone

Leave it as-is unless you specifically need IPv6 on the LAN. It doesn't block anything and consumes no resources while inactive.

### Putting it together: the full stack

```
┌───────────────────────────────────────────────────────────────┐
│ Wi-Fi client (your phone, laptop, etc.)                       │
│        ↓                                                       │
│ phy1-ap0  ─┐                                                   │
│            ├─→ br-lan (192.168.100.0/24, DHCP, firewall "lan") │
│ eth1     ──┘                                                   │
│        ↓                                                       │
│ omrvpn / tun0  (single logical tunnel, looks like a normal WAN)│
│        ↓                                                       │
│   ┌────┴────┐                                                  │
│ wan1     wan2     ← real WANs (eth0, usb0, wwan, etc.)         │
│   ↓        ↓                                                   │
│  ISP A   ISP B                                                 │
│   └────┬────┘                                                  │
│        ↓                                                       │
│       VPS  (reassembly, NAT, real public IP)                   │
│        ↓                                                       │
│   The actual internet                                          │
└───────────────────────────────────────────────────────────────┘
```

Bottom-up debugging tip: when something's broken, isolate the layer. WANs red? Physical/uplink problem. WANs green but `omrvpn` red? Tunnel/key problem. `omrvpn` green but LAN clients have no internet? Bridge/DHCP problem (the topic of this session's debugging trail).

---

## WAN sources — counting paths and trading them off {#wan-sources-counting-and-tradeoffs}

A common question once the bonded setup is working: "how many WANs can I actually have?" The answer is a tradeoff matrix, not a single number. The Beryl AX has five physical/logical slots that *could* be WAN sources, but every slot you flip from its default role costs you something else.

| Physical | Default role in OMR | Can become a WAN as… | Cost of repurposing |
|---|---|---|---|
| `eth0` (1GbE port, labeled WAN on the chassis) | WAN | Home internet, Ethernet-tethered phone, second router uplink — anything that speaks DHCP | None on its own — already a WAN slot |
| `eth1` (2.5GbE port, labeled LAN on the chassis) | LAN bridge member | A second Ethernet WAN | **You lose wired LAN.** Wi-Fi-only for clients; nothing wired plugs in. |
| `usb0` (USB-A 3.0 port) | unused unless tether configured | USB-tethered phone, USB-Ethernet adapter, powered hub with multiple adapters | None directly; powered hub adds cost/bulk if going multi |
| `radio0` (2.4 GHz Wi-Fi) | usually disabled or AP | Wi-Fi-as-WAN client (joins phone hotspot, hotel/ship wifi) | Can't also be the 2.4GHz AP — pick one |
| `radio1` (5 GHz Wi-Fi) | client-facing AP | Wi-Fi-as-WAN client | **You lose 5GHz AP for your client devices** — they'd fall back to 2.4 or no AP |

**Theoretical maximum:** five WANs simultaneously. **Practical maximum:** three to four. After that, two ceilings start to dominate:

- **Beryl CPU.** The MT7981 dual-core ARM tops out around 600-800 Mbps of aggregate bonded throughput across tunnel encryption + MPTCP scheduling + firewall. Adding a fourth or fifth path past that ceiling adds latency, not bandwidth.
- **VPS CPU.** Glorytun and Shadowsocks both encrypt every packet. On a 1-vCPU $6 droplet you'll saturate around the same range. The VPS becomes the bottleneck before the Beryl does on a faster home connection.

**Recommended priority order for a travel / cruise / nomad build:**

1. **`eth0` — fastest available wired uplink** (home Ethernet at home; phone Ethernet tether on the road)
2. **`usb0` — USB-tethered phone** (most stable cellular path, no Wi-Fi airtime tax)
3. **`wwan` via `radio0` — Wi-Fi-as-WAN** (phone hotspot or hotel/ship wifi when available)
4. *(optional 4th)* **`eth1` — second Ethernet tether** (only if you've consciously decided to drop wired LAN)

Three carriers + Starlink covers nearly every realistic scenario without hitting the diminishing-return wall.

### Carrier diversity matters more than path count

When the goal is *resilience while traveling*, the math is:

- Three plans on three **different carriers** (Verizon, T-Mobile, AT&T) → one of the three works almost everywhere with cellular coverage
- Three plans on the **same carrier or MVNOs that ride the same upstream** → all fail together in a carrier outage or coverage gap

US MVNO upstream map (as of 2026 — verify, this shifts): Mint → T-Mobile, US Mobile Warp 5G → Verizon, US Mobile GSM → T-Mobile, Cricket → AT&T, Visible → Verizon, Google Fi → primarily T-Mobile. Two plans on the "same underlying carrier" buy you no resilience.

### Why I'd stop at 3 even with the hardware budget

- The Beryl AX's bonding ceiling is ~600-800 Mbps total — three modest WANs already saturate the router CPU on the encryption path.
- Each path past saturation adds failure modes to debug rather than throughput.
- Each cellular WAN burns one phone's data plan. Aggressive aggregation is expensive — keep some plans as cold spares rather than hot bonded paths.
- Three paths give clean redundancy (any one can die, the remaining two cover) without the complexity tax of larger fan-out.

---

## Ethernet tethering as a WAN source {#ethernet-tether-as-wan}

Once `wan1` is configured against `eth0` with Type **Normal** and Protocol **DHCP client**, the port is *physical-agnostic*: it doesn't care what device is on the other end of the cable, as long as that device hands out a DHCP lease. This is what makes Ethernet tethering work as a drop-in swap for home internet.

### The seamless-swap workflow

The procedure for replacing your home Ethernet with a phone Ethernet tether is just:

1. Unplug the home ISP cable from the Beryl's WAN port (`eth0`)
2. Plug in a USB-C-to-Ethernet adapter that's connected to your phone
3. Enable Ethernet tethering on the phone (see per-phone toggle paths below)
4. Wait ~5-10 sec for `wan1` to re-DHCP

**No OMR config changes required.** No re-running any wizard. No `wifi reload`. The OMR Settings page's `wan1` block stays as-is. Mentally renaming "wan1 = home" to "wan1 = whatever's plugged into eth0" is the framing that makes this make sense.

### What changes under the hood

| Layer | Before swap (home cable) | After swap (phone tether) | Who handles it |
|---|---|---|---|
| Upstream MAC | home router's MAC | phone's RNDIS MAC | netifd / ARP — automatic |
| `eth0` IP | home subnet (e.g., 192.168.1.115) | phone's RNDIS subnet (e.g., 192.168.42.x) | udhcpc on the Beryl — automatic |
| Public IP (egress) | home ISP's public IP | carrier's CGNAT/public range | n/a — both still tunnel to your VPS, so destinations only see the VPS IP either way |
| MTU | usually 1500 | usually 1428-1500 depending on carrier | MPTCP path MTU discovery — automatic, may stutter briefly |
| MPTCP subflow | one subflow over old path | old subflow dropped, new subflow opened | omr-tracker + kernel MPTCP — ~10 sec |
| Active TCP connections | running | continue on surviving subflows (`usb0`, `wwan`) during the swap | MPTCP — that's the point |

If your bond has at least one other active WAN (e.g., `usb0` from a different tether or `wwan` from a Wi-Fi-as-WAN), live sessions (SSH, Zoom, VDI, streaming) **survive the cable swap** because MPTCP keeps the connections alive on the other paths while `eth0`'s subflow reconverges.

### Per-phone Ethernet-tethering toggle paths

| Phone OS | Path | Persistence behavior |
|---|---|---|
| **Samsung (OneUI 6+)** | Settings → Connections → Mobile Hotspot and Tethering → **Ethernet tethering** | Greyed out until USB-Ethernet adapter is connected. Re-enable per session. |
| **OnePlus (OxygenOS 14/15)** | Settings → Wi-Fi & network → Personal Hotspot → **Ethernet tethering** (some builds bury or omit this) | Per-session. Use USB tethering with USB-Ethernet adapter as fallback. |
| **Pixel (Android 14+)** | Settings → Network & internet → Hotspot & tethering → **Ethernet tethering** | Per-session. |
| **iPhone** | Not supported. Apple does not expose Ethernet tethering. | Use USB or Wi-Fi tether instead. |

### Gotchas worth knowing

- **Carrier tether detection.** Some US carriers (Verizon and AT&T on lower-tier plans) detect tethering via deep packet inspection — TTL fingerprinting, user-agent matching, traffic-pattern analysis — and throttle tethered traffic to ~600 Kbps or block it outright. T-Mobile and most MVNOs are more permissive. Test each plan in tether before relying on it for the bond.
- **Battery + heat.** Ethernet tethering keeps the cellular radio busy and the USB peripheral powered — phone burns through battery and gets warm. Plug the phone into a charger separately during long sessions.
- **Adapter quality matters.** Cheap unbranded USB-C-to-Ethernet adapters drop link under sustained throughput. Stick with Anker / UGREEN / CalDigit. Verify with `dmesg` after plugging in — you want to see a clean `cdc_ether` or `r8152` driver attach, no resets.
- **Phone-side hotspot timeout.** Some Android builds disable hotspot/tether after N minutes of "no client traffic." If the Beryl is mid-rebound and not actively pulling DHCP, the phone may pre-emptively disable tethering. Solution: have the phone's hotspot/tether config set to "never auto-disable" if the option exists.

### When Ethernet tether beats USB tether or Wi-Fi tether

Use **Ethernet tether** when:
- You want the most stable wired link with the lowest jitter (Ethernet's 1500-byte MTU, no airtime contention)
- The phone's hotspot Wi-Fi shares spectrum with your client AP and you're seeing interference
- The Beryl's USB-A port is already occupied by another tether

Use **USB tether** when:
- You don't have a USB-C-to-Ethernet adapter handy
- The phone doesn't expose Ethernet tethering (OnePlus on some builds, all iPhones)
- You're powering the phone off the Beryl's USB-A simultaneously (USB-A can do both data + 500mA charging)

Use **Wi-Fi-as-WAN** when:
- You want no cables at all (cruise cabin, hotel room with phone in pocket)
- You're joining someone else's hotspot you can't physically connect to (ship wifi, conference wifi)
- You're accepting more jitter and shared-spectrum overhead for the convenience

A practical multi-WAN build often uses all three styles — Ethernet for the strongest carrier on the strongest plan, USB for a second carrier, Wi-Fi-as-WAN for the third or for joining external APs.

---

## WAN slot configuration — every field explained {#wan-slot-fields}

When you edit a WAN slot in **LuCI → System → OpenMPTCProuter → Settings**, you're presented with a dense form. Most fields are wrong by default for the typical "phone tether" or "home Ethernet" use case. Here's what each field actually does and what to set it to.

| Field | Default | What to set | Why |
|---|---|---|---|
| **Label** | empty | any short string ("S25 hotspot", "Home eth", "OnePlus USB") or leave blank | Cosmetic only. Shows on dashboard cards so future-you can tell paths apart. |
| **Type** | `MacVLAN` | **`Normal`** | MacVLAN creates a virtual interface stacked on a physical one — only useful when one physical port carries multiple VLAN-tagged uplinks (e.g., a single switch port feeding several modems). The Beryl AX has no such setup. Normal binds the WAN to a real physical interface directly. |
| **Protocol** | `Static address` | **`DHCP client`** for tethers, Wi-Fi-as-WAN, and most home connections; Static only if your ISP gave you a fixed IP block | Static needs IP/netmask/gateway fields filled in — leave-them-blank-and-Static is the most common "No IP defined" cause. |
| **Physical interface** | logical name like `wan1` (wrong) | A real **kernel netdev name**: `eth0`, `eth1`, `usb0`, `phy0-sta0`, `phy1-sta0` | The "logical" names in the dropdown are circular references (wan1's physical = wan1). Pick the actual kernel device. See troubleshooting if `phy0-sta0` doesn't appear — usually a hard refresh fixes it. |
| **VLAN** | empty | empty | Only used with VLAN-tagged uplinks. Irrelevant for tethers and standard home connections. |
| **Multipath TCP** | `Disabled` | **`On`** for active bonded paths; **`Backup`** for hot-spare paths; **`Off`** to remove from the bond | Disabled = MPTCP doesn't use this path at all. On = active subflow contributing to bonded throughput. Backup = subflow only activates when On paths fail (clean failover with no airtime/data cost in normal operation). Master = MPTCP initiates new connections here; one Master per bond. |
| **Force TTL** | empty | **`65`** for cellular tethers; leave empty for home Ethernet | Carriers (Verizon, AT&T) detect tethering by checking IP TTL — phone-originated traffic has TTL 64-65, tethered traffic from a downstream device has lower TTL (each hop decrements). Forcing TTL to 65 on egress makes tethered traffic look like it originated on the phone. Bypasses the throttle on detection-enabled plans. Harmless if your carrier doesn't check. |
| **MPTCP over VPN** | unchecked | **unchecked** unless your carrier blocks MPTCP at the network layer | Wraps the MPTCP subflow inside a VPN to disguise it. Almost never needed — most carriers don't filter MPTCP. Check this only if you've verified MPTCP itself is being blocked (rare). |
| **Enable SQM** | unchecked | **unchecked** for cellular WANs; **checked** for stable home Ethernet (with calibrated rates) if you observe bufferbloat | SQM controls bufferbloat by under-shaping the egress rate to keep queues empty. Needs a known stable bandwidth to calibrate against. Cellular bandwidth is too variable. See § SQM with cellular WANs. |
| **Enable SQM autorate** | unchecked | usually **unchecked** | Requires the `cake-autorate` package (not in stock OMR). Adds latency-based rate auto-adjustment. Useful for stable LTE links but adds CPU + maintenance cost. Skip unless you've committed to SQM-on-cellular. |
| **Calculate speed** | unchecked | **unchecked** unless SQM is on | Runs an automatic speedtest to populate the Download/Upload fields. Only useful when SQM needs rate values. |
| **Download speed (Kb/s)** | 0 | leave 0 unless SQM is on | Used by Glorytun UDP rate shaping and by SQM. Setting it without SQM gates Glorytun UDP throughput. |
| **Upload speed (Kb/s)** | 0 | leave 0 unless SQM is on | Same as above. |

**One field is missing from most discussions but matters:** the WAN's **MPTCP role within the bond**, sometimes a separate dropdown on the OMR Settings page or accessible via `uci show openmptcprouter`. Values are typically:

- **Master** — the path that initiates new TCP connections. Choose your fastest, most reliable, lowest-latency WAN. One Master per bond.
- **On** — active subflow. Joins after Master establishes the connection. Contributes to bonded throughput.
- **Backup** — subflow defined but inactive until an On/Master path fails.
- **Off** — defined but not part of the bond.

A typical 3-WAN cruise/travel build:

| WAN | Type | Protocol | Physical | MPTCP role | Force TTL |
|---|---|---|---|---|---|
| `wan1` (home eth0) | Normal | DHCP | eth0 | **Master** | empty |
| `wan2` (OnePlus USB) | Normal | DHCP | usb0 | **On** | 65 |
| `wan3` (S25 Wi-Fi) | Normal | DHCP | phy0-sta0 | **On** | 65 |

---

## Wi-Fi-as-WAN deep dive {#wifi-as-wan-deep-dive}

Wi-Fi-as-WAN is when the Beryl is a *client* of another AP — joining a phone hotspot, cruise wifi, hotel wifi, family Wi-Fi at someone's house — and that joined connection becomes one of the bonded WAN paths.

### Configuration flow: Scan + Join Network

The right way to set this up isn't the Mode dropdown — that requires hand-entering BSSID, encryption, password. Instead:

1. **Wireless Overview** → on the radio you want as a client, click **Scan**
2. Find the upstream SSID in the scan results → click **Join Network**
3. Dialog:
   - **WPA passphrase:** the upstream's password
   - **Name of the new network:** descriptive — `wwan_s25`, `wwan_home`, `wwan_cruise`
   - **Firewall zone:** `wan` (critical — putting it on `lan` makes the Beryl unable to use it as a WAN)
4. Submit → Save & Apply on the parent page

LuCI auto-creates the wifi-iface section in Client mode, sets the right encryption, links it to the named network.

### Mode and channel — the AP dictates, but defaults matter

In Client mode, the **AP** (the phone, the cruise router) chooses mode and channel. The Beryl just speaks whatever's broadcast. So the Mode dropdown in the Client edit dialog isn't truly authoritative — it sets the client's capability, not the channel that gets used.

Practical defaults:
- **Mode = N** for radio0 (2.4GHz) — broadest compatibility with phone hotspots. AX in client mode is fine but no benefit because the cellular pipe behind the hotspot is your bottleneck.
- **Channel** — auto. Don't pin a channel for client mode; the AP picks.

### Why 2.4GHz hotspot beats 5GHz hotspot for Wi-Fi-as-WAN

Counter-intuitive but: **prefer a 2.4GHz phone hotspot for Wi-Fi-as-WAN over 5GHz**, even though 5GHz is faster on paper.

- **2.4GHz N (~130 Mbit/s link rate) is already faster than your cellular pipe.** Most phone hotspots backhaul 50-300 Mbps cellular. 2.4GHz delivers plenty for that.
- **5GHz client mode hits DFS channels (52-144) which require radar avoidance.** Some phones pick a DFS channel for hotspot; some Beryl drivers handle it cleanly, others silently fail to associate or drop randomly.
- **5GHz range is shorter.** If the phone moves to a different pocket or backpack, 2.4GHz tolerates the change; 5GHz might drop.
- **5GHz is congested in dense areas** (conferences, cruise ships) — 2.4GHz, while noisier, is more reliable for low-throughput control.

Set your phone hotspots to 2.4GHz mode for hotspot-as-WAN use.

### Country Code on client interfaces

Set the Country Code explicitly on the wifi-iface (not just the radio). Set to your actual country (e.g., **US - United States**). Default is "driver default" which can resolve to `00` (world domain) and prevent association — same root cause as the AP-side bug documented in troubleshooting.

### Multiple upstream candidates — `travelmate`

Vanilla OpenWrt's Wi-Fi-as-WAN is **one configured upstream per radio**. To switch, you change the SSID in the wifi-iface and reload. Clunky if you switch often.

**`travelmate`** is an OpenWrt package designed for travel routers with multiple known upstreams. You preconfigure a prioritized list: S25 hotspot, OnePlus hotspot, home Wi-Fi, mom's house, common coffee shops. The daemon scans periodically and joins the highest-priority available SSID. When that drops, it falls back to the next.

**Install:**

```bash
ssh root@192.168.100.1
apk update
apk add travelmate luci-app-travelmate
/etc/init.d/travelmate enable
/etc/init.d/travelmate start
```

(If `apk search travelmate` returns nothing, the OMR repos may not have it yet — fall back to manual SSID switching.)

**Configure:** LuCI → Services → Travelmate → Add Uplink. Each entry: SSID, password, priority. Lower priority number = preferred.

Example prioritization for a nomad/cruise build:

| Priority | SSID | Why |
|---|---|---|
| 1 | Home Wi-Fi | Fastest free path when in range |
| 2 | KENNETH's S25 | Primary cellular WAN candidate |
| 3 | OnePlus Hotspot | Secondary cellular WAN |
| 4 | (preconfigured cruise SSID) | Auto-join when boarding |
| 5 | (preconfigured hotel SSIDs) | Auto-join at known hotels |

After install, switching between WANs is automatic — the Beryl just finds the best available upstream. Combined with phone-tether-on-eth0 swap, your router adapts to wherever you are without manual reconfiguration.

### Wi-Fi-as-WAN gotchas

- **Phone hotspot timeout.** Some Android builds auto-disable hotspot after N minutes of no activity. With Wi-Fi-as-WAN, the Beryl IS the active client, so this shouldn't trigger — but watch for it on phones with aggressive battery management.
- **Captive portal.** Hotel/cruise/coffee-shop Wi-Fi often requires login. The Beryl associates but no internet until you complete the captive portal in a browser on a LAN client. Plug a laptop in, open the portal page, log in once — applies to all LAN clients afterward.
- **MAC filtering.** Some networks bind sessions to MAC. If you reboot the Beryl mid-session, you may need to re-do captive portal login because OpenWrt's STA MAC stays consistent but session state on the AP side resets.
- **MAC randomization.** OpenWrt 23+ supports STA MAC randomization. Off by default; can be enabled per wifi-iface. Useful for privacy but breaks MAC-bound sessions.

---

## Multiple WANs to the same upstream {#multiple-wans-same-upstream}

A common question once you have Wi-Fi-as-WAN working: "if I'm home, can I have both `eth0` (wired to home router) AND `wwan_home` (Wi-Fi to the same home router) configured at the same time?"

**Short answer: yes, no conflict, but it's redundancy not throughput multiplication.**

### What works

OMR uses per-WAN routing tables (mark-based routing). Each WAN gets its own routing table; the kernel uses fwmark to direct traffic via the right interface. Two interfaces with IPs on the same subnet (both 192.168.1.x from your home router's DHCP) don't fight because they're explicitly bound to their own tables:

```
ip rule show
# Includes:
#   100: from <eth0 IP> lookup wan1_table
#   101: from <phy0-sta0 IP> lookup wwan_home_table

ip route show table wan1_table
#   default via 192.168.1.1 dev eth0
ip route show table wwan_home_table
#   default via 192.168.1.1 dev phy0-sta0
```

Both paths function. MPTCP can use both as subflows. ARP works fine because the MACs differ. The home router happily DHCPs two addresses to two MACs on its LAN.

### What you actually get

- **Same public IP egress.** Both paths exit through your home router's WAN port → ISP → public IP. From the VPS's perspective, both subflows arrive from the same IP. No aggregation benefit beyond what one path delivers.
- **Same upstream bottleneck.** Bonded throughput is capped at the home ISP's bandwidth, no matter how many parallel Beryl-to-router paths exist.
- **Redundancy.** If the Ethernet cable is unplugged or eth0 link drops, the Wi-Fi subflow continues. MPTCP's connection-survival property means live TCP sessions don't die.

### Recommended configuration if you do this

| WAN | Role | Effect |
|---|---|---|
| `eth0` (home wired) | **Master** | Default for new connections. No airtime cost, low latency. |
| `wwan_home` (home Wi-Fi) | **Backup** | Idle while Master works. Activates within ~10 sec if Ethernet drops. |

`Backup` mode means no actual traffic uses the wireless-to-home path during normal operation. The Beryl maintains association so it's ready to switch instantly if Ethernet dies. Zero data plan impact (it's your own home Wi-Fi). Modest Wi-Fi airtime overhead from association beacons only.

### When the trade isn't worth it

Honestly, for most builds **skip wwan_home and just use eth0 wired**:

- Most home failure modes (router crashed, ISP outage, power blip) take **both** paths down at once. The wireless path doesn't help.
- The narrow case where wired is broken but wireless to the same router works (e.g., chewed Ethernet cable) is real but rare.
- Your `radio0` slot is more valuable as a Wi-Fi-as-WAN client for cellular hotspots when you're *away* from home.
- For mobile-first builds, the redundancy budget is better spent on a third cellular WAN than a second path to the same home.

The exception: if you have a known-good reason — Ethernet jack location is inconvenient, basement office with weak Wi-Fi where you want wired-when-possible-Wi-Fi-when-not — then wired Master + wireless Backup is the right pattern. Otherwise: keep it simple.

### Same upstream + different schedulers

This is where it gets interesting. With MPTCP scheduler = `redundant`, both eth0 and wwan_home would carry **every packet** in parallel — the destination de-duplicates at the kernel layer. For latency-critical workloads (VDI sessions, voice calls) this gives zero-packet-loss failover even on millisecond drops. Doubles your Beryl→router traffic and your Wi-Fi airtime cost, but the throughput cap is still home ISP bandwidth.

Useful for "I cannot have my Zoom drop during a presentation, even briefly." Wasteful otherwise.

---

## SQM with cellular WANs — when to bother {#sqm-with-cellular-wans}

SQM (Smart Queue Management, using the `cake` algorithm) prevents bufferbloat — the bloat in upstream queues that makes loaded latency 200ms+ when an idle link is 20ms. With SQM correctly calibrated, loaded latency stays within 10ms of unloaded.

**The catch:** SQM works by shaping egress to slightly *under* your real bandwidth, keeping queues empty in upstream hardware (ISP modem, cell tower) where you can't control them. The rate you set has to match real bandwidth. Set too high → SQM does nothing because the bottleneck is upstream. Set too low → you self-throttle.

### Why SQM is hard for cellular WANs

Cellular bandwidth is variable: signal strength, tower congestion, time of day, weather all shift the available throughput by 30-90% over a single day. A static SQM rate that's correct at 8am is wrong by 8pm.

Two responses:

1. **Static conservative rate.** Set SQM to ~50% of your worst-case observed cellular throughput. You leave bandwidth on the floor most of the time, but you keep latency tame.
2. **`cake-autorate` dynamic adjustment.** A shell script (not in stock OMR; install with `apk add cake-autorate`) pings a known host continuously and adjusts SQM rate based on observed latency. Tracks moving bandwidth at the cost of extra CPU + complexity.

Neither is great. Reasonable verdict for most builds: **SQM off on cellular WANs.**

### When SQM is worth turning on

| WAN type | SQM recommendation | Why |
|---|---|---|
| Home Ethernet (cable/fiber) | **On**, rate = measured speed × 0.9 | Stable enough to calibrate once. Big bufferbloat win on cable/DSL. |
| Home Ethernet (Starlink) | **On**, rate = measured speed × 0.8 | Starlink has known bufferbloat (~200ms loaded → ~30ms with SQM). Recalibrate quarterly as Starlink performance evolves. |
| Phone Ethernet tether | **Off** | Cellular variability defeats static rates. |
| Phone USB tether | **Off** | Same. |
| Wi-Fi-as-WAN (phone hotspot) | **Off** | Same + Wi-Fi link adds another variable. |
| Wi-Fi-as-WAN (joining cable/fiber router) | **Maybe**, rate = measured ÷ 2 | The Beryl is doubly behind a queue (Wi-Fi link + the other router's WAN). Only helps if Wi-Fi link itself is the bottleneck. Usually not. |

### How to tell if you have a bufferbloat problem

From a LAN client (laptop, phone) while the Beryl is your gateway:
1. Open [Waveform's bufferbloat test](https://www.waveform.com/tools/bufferbloat)
2. Note "Unloaded latency" and "Loaded latency"
3. **Loaded > 150ms = bufferbloat present, SQM would help**
4. **Loaded < 50ms = your existing path is well-managed, SQM is overkill**
5. Repeat per WAN by temporarily disabling others.

### SQM and MPTCP interaction

SQM operates at the per-physical-interface layer. MPTCP runs above it. No inherent conflict — SQM shapes each WAN's egress; MPTCP aggregates the resulting smoothed pipes. The decision is per-WAN, not per-bond.

---

## Verifying all WANs are actively bonded {#verifying-bonded-wans}

After configuration, the question becomes: are all WANs actually carrying packets, or is one configured-but-idle? Three layers of evidence, increasing rigor.

### Layer 1: Dashboard visual

**LuCI → Dashboard** and **Status → OpenMPTCProuter**:
- Each WAN card should be **green**
- Each card should show a **distinct public IP** (different ISPs, different CGNAT ranges)
- `omrvpn` card green + the VPS's public IP shown as your egress
- Per-WAN throughput graphs should update during a sustained download

What this tells you: WANs are *configured and reachable*. It does **not** tell you they're actively carrying packets right now.

### Layer 2: Byte counter live watch

```bash
ssh root@192.168.100.1
watch -d -n 1 'echo "=== eth0 (home) ==="; grep eth0 /proc/net/dev; \
                echo "=== usb0 (OnePlus) ==="; grep usb0 /proc/net/dev; \
                echo "=== phy0-sta0 (S25 Wi-Fi) ==="; grep phy0-sta0 /proc/net/dev'
```

(`-d` highlights changed digits between refreshes — makes deltas obvious.)

From a LAN client, start a sustained download:

```bash
# A speedtest, or:
curl -o /dev/null https://speed.cloudflare.com/__down?bytes=10000000000
```

All three WANs should show RX byte counters incrementing simultaneously. **If only one increments, only one WAN is actually being used right now** — the others are configured but idle. That usually means:
- MPTCP scheduler = `default` (assigns based on RTT/throughput, may pin to fastest path under low load)
- Or one of the supposed-On WANs is silently down at L2/L3 (despite dashboard green from a stale check)

To force all WANs into use, switch scheduler to `roundrobin` temporarily:

```bash
uci set network.globals.mptcp_scheduler='roundrobin'
uci commit network
/etc/init.d/network restart
```

Re-run the speedtest. If all three counters now move, the WANs are bonded; `default` scheduler was just being efficient (no need to spray a small download across multiple paths). Switch back to `default` after testing if that's what you prefer.

### Layer 3: MPTCP subflow introspection

The strongest evidence — ask the kernel directly which subflows are part of an active MPTCP socket:

```bash
ssh root@192.168.100.1

# Registered MPTCP endpoints (one per WAN, populated by OMR)
ip mptcp endpoint show

# Active MPTCP sockets with subflow detail
ss -tiM | head -40

# MPTCP-wide counters
nstat -a | grep -i mptcp
# Key counters:
#   MPTcpExtMPCapableSYNTX   — MPTCP-enabled SYNs you sent
#   MPTcpExtMPCapableACKRX   — server agreed to MPTCP
#   MPTcpExtMPJoinSynRx      — additional subflows joining the connection
#   MPTcpExtMPJoinAckTx      — you ACKed a subflow join
```

`MPJoinSynRx > 0` and `MPJoinAckTx > 0` are the proof that additional subflows are being established beyond the initial single-path connection. If only `MPCapableSYNTX` increments but `MPJoinSynRx` stays at zero, you're getting MPTCP-capable connections but they're not actually multipathing — usually means the VPS isn't advertising additional addresses, or carrier middlebox is stripping MPTCP options.

### Path-health view from OMR

```bash
ubus call openmptcprouter status 2>/dev/null | head -80
# Per-WAN: UP/DOWN, latency to VPS, loss percentage, throughput
```

This is what powers the dashboard cards. If `ubus` is unavailable, check `logread -f | grep omr-tracker` for the periodic health probes.

---

## Device fleet for a mobile bonded build {#device-fleet}

How many phones, SIMs, cables, batteries do you actually need? This depends on the build's purpose. The framework below covers a "work from anywhere — cruise/RV/hotel/home" use case.

### The minimum viable kit

| Item | Count | Why |
|---|---|---|
| Travel router (Beryl AX or equivalent) | 1 | The bonding endpoint |
| Phones with hotspot/tether capability | 2 | Primary cellular WAN + backup carrier. Single phone = single point of failure on the cellular side. |
| Active SIM/eSIM plans | 2 | One per phone, ideally on different carriers (carrier diversity > path count) |
| USB-A to USB-C cables (for tether) | 2 | One for active tether, one spare. Cheap cables drop link under load. |
| USB-C to Ethernet adapter | 1 | For Ethernet-tether option (better link stability than USB tether) |
| USB-C charger or battery pack for the phones | 2 | Tethering keeps the cellular radio + USB peripheral hot; phones drain fast. Plug them in while in use. |
| Beryl power source (USB-C PD or 12V DC adapter) | 1 + spare | Don't be stuck with a broken charger on day one of a trip |

### The recommended kit (what I'd actually carry)

| Item | Count | Why |
|---|---|---|
| Beryl AX | 1 | + a spare Beryl if traveling for weeks; they're $80 and shipping replacements is hard from a cruise |
| Phones (different OSes ok) | 2-3 | 2 = minimum, 3 = comfortable. Each one is a redundant uplink + carrier. |
| Active plans on different carriers | 3 | Verizon + T-Mobile + AT&T (or country equivalent). Different MVNO upstreams count if different. |
| Spare SIM tray pin | 1 | Trivial cost, prevents the "I can't activate my backup SIM because no pin" stress |
| USB-A to USB-C cables | 3-4 | Stuff happens. One reliably-good Anker per active tether + spares. |
| USB-C to Ethernet adapters | 1-2 | Anker / UGREEN / CalDigit. Cheap ones drop link under sustained load. |
| Powered USB-A hub (if going past 2 USB tethers) | 0-1 | Optional. Only if you want >2 USB-tethered phones simultaneously. |
| Battery pack (10000+ mAh) | 1-2 | For phone charging mid-day. Each tethered phone drains 30-50% per hour under load. |
| Charger bricks | 2-3 | One for Beryl, one for each phone. PD-capable so they can fast-charge during use. |
| Ethernet cable | 1-2 | For wired LAN to laptop when stationary, or for Ethernet-tethering tests |

### Carrier diversity — pick three different upstreams

The resilience math is **different carriers**, not different plans. Three Mint plans (all T-Mobile MVNO) survive zero T-Mobile outages. One Mint + one Cricket + one US Mobile Warp 5G survives any single-carrier outage.

US MVNO upstream map (verify quarterly — it shifts):
- **T-Mobile network:** Mint, US Mobile GSM, Google Fi (primarily), Metro PCS
- **Verizon network:** Visible, US Mobile Warp 5G, Total Wireless
- **AT&T network:** Cricket, AT&T Prepaid, Consumer Cellular (AT&T side)

International builds: pick three carriers from the local market. EE / Vodafone / O2 in the UK, Bell / Telus / Rogers in Canada, etc. For cruise/cross-border travel, eSIM services like Airalo or GigSky give you on-demand local data but tend to be expensive and slow — they're an addition to, not a replacement for, your home-country carriers.

### Why not more than 3 phones for the bond

- **Beryl CPU ceiling.** ~600-800 Mbps aggregate bonded throughput. Three modest cellular WANs already saturate.
- **VPS encryption ceiling.** Same range on a 1-vCPU $6 droplet. Upgrade to 2-vCPU ($12) if you need more.
- **Data plan economics.** Each plan is $15-40/mo. Three plans is reasonable insurance; five is hobbyist territory.
- **Physical bulk.** Three phones + their cables + their chargers is already a small bag. Each additional phone is another charge cycle to track.
- **Complexity tax.** More paths = more failure modes = more 3am debugging on a cruise ship.

### Phone selection criteria

Optimizing for tethering use:
- **5G/LTE support on multiple bands** — single-band phones miss carrier coverage in some areas
- **Ethernet tethering support** — Samsung yes, OnePlus mostly yes, Pixel yes, iPhone no
- **USB tethering quality** — all Androids do RNDIS; quality varies by build
- **Hotspot mode reliability** — older phones may auto-disable hotspot aggressively
- **Battery capacity** — bigger = longer tether sessions between charges
- **Heat management** — phones that throttle under sustained cellular use drop tether speed silently

A practical fleet: **flagship Samsung** (best ethernet tether), **flagship OnePlus** (good USB tether), **older spare Android** (cold backup, different carrier). Avoid making iPhones primary tether sources — no Ethernet tether option is a real limitation.

### Spares and resilience scaling

For a long trip (weeks) or critical work (live broadcasts, on-call), add:
- A **spare Beryl AX** ($80, pre-configured identically) — failover device if the primary fails
- A **second VPS** in a different region (warm standby, replicate config) — failover if the primary VPS region goes down
- A **spare USB hub + adapters kit** — cables and adapters fail more than anything else

Don't carry these for casual travel; they're 0.5 lb of insurance for someone whose income depends on always-on connectivity.

### Why fewer devices than you'd think — the law of diminishing return

You can construct a 5-WAN bond on the Beryl AX. You usually shouldn't:
- After 3 paths, throughput stops growing (CPU-bound)
- Each path past 3 is another battery to charge, cable to track, plan to pay for
- The marginal resilience from a 4th path is small if the first 3 cover different carriers
- Maintenance burden compounds: more devices = more updates = more "why did this one suddenly stop working"

The 80/20 build: **Beryl + 2 phones + Ethernet-tether-capable Samsung + diverse-carrier SIMs.** Add a 3rd phone or SIM only if you've experienced enough outages to justify it.

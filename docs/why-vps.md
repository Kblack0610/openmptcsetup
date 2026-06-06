# Why a VPS is required for real WAN bonding

A natural first question when you see this setup is: "Why do I need to rent a $6/mo cloud
server? Can't the Beryl just bond my home internet and cellular itself?" Short answer: **no,
not without a single public reassembly endpoint somewhere in the cloud**. This doc unpacks
why, what's actually happening under the hood, and what the VPS is doing for its $6/mo.

## The physics of "splitting one connection across two paths"

Imagine you want to download a file at the combined speed of your home internet + your
cellular tether. To get genuinely combined throughput on a *single* TCP connection — meaning
one logical stream, not just "different downloads on different links" — you need to:

1. Split that one connection's packets across both WANs (some go via home, some via cell)
2. Have the destination server receive all those packets
3. Have the destination reassemble them in order

Steps 1 and 3 are MPTCP's job — that part the kernel handles. **Step 2 is where everything
breaks without the VPS.**

Your home WAN egresses through one public IP (say, `66.27.123.93` from your cable ISP). Your
cellular tether egresses through a totally different one (say, `172.58.x.x` from T-Mobile's
CGNAT block). They're on completely different paths through the internet — different ASNs,
different physical fiber paths, different upstream providers.

If you try to send a single TCP connection's packets to, say, `google.com`, half through
home and half through cellular, what does Google's server see?

> "Some packets claiming to be part of TCP connection X are arriving from `66.27.123.93`.
> Other packets claiming to be the same connection X are arriving from `172.58.x.x`. That's
> not a valid TCP connection — it's two different connections, or someone is trying to spoof
> my session. Drop."

To TCP, packets from two source IPs are two separate connections. The server has no way to
know they're meant to be one logical stream. There's no extension to vanilla TCP that says
"hey, these are coming from the same client on multiple paths, just reassemble them." MPTCP
adds that, but it requires both endpoints to speak MPTCP and to agree on a single logical
connection at both ends.

You'd need either:
- Google to speak MPTCP and accept multi-path subflows from your two source IPs (it
  doesn't — almost no destination servers on the public internet do)
- Or **a server you control, in front of the actual destination, that speaks MPTCP, accepts
  the multi-path subflows, reassembles them into one stream, and forwards them to the real
  destination using a single public IP**

That second thing is the VPS. It's the only way.

## What the VPS actually does

```
                     ┌──── home internet ────► VPS subflow A
You (Beryl AX) ──────┤                                  ║
                     ├──── cellular tether ──► VPS subflow B    ╠══► reassembled stream ──► google.com
                     │                                  ║
                     └──── cruise wifi ──────► VPS subflow C
```

Concretely:

1. The Beryl AX runs an outer MPTCP-aware tunnel (Glorytun TCP, in our setup) and opens a
   single logical MPTCP connection to the VPS.
2. MPTCP creates subflows — one per available WAN. Each subflow is its own TCP connection
   from a different source IP, all targeting the same VPS public IP.
3. Your actual traffic (HTTPS to google.com, your VDI session, etc.) gets wrapped inside
   this outer MPTCP tunnel.
4. The MPTCP scheduler distributes the wrapped packets across the subflows — per
   scheduler policy (`default` for throughput aggregation, `redundant` for seamless
   failover; see `concepts.md` § MPTCP scheduler).
5. The VPS receives all the subflows, reassembles them into the original outer stream, then
   unwraps to recover your original traffic and forwards it to the real destination using
   the VPS's own single public IP.
6. Return traffic flows the reverse way — back to the VPS, wrapped, split across subflows,
   reassembled on your Beryl, delivered to your local device.

The destination (google.com, your corp VDI gateway, the Mac Studio you're streaming from) only
ever sees the **VPS's** public IP. It has no idea you're actually two-or-three-WAN-bonding
behind the scenes. From its perspective, this is just normal traffic from one IP.

## What you give up if you don't have the VPS

People sometimes try to "bond" without a VPS by using local techniques. Each one has a
significant catch:

- **Failover (active/passive)**. WAN1 dies → switch to WAN2. Only one link in use at a time.
  No throughput combining. **Connections break on failover** — your VDI/SSH sessions drop.
  GL.iNet stock firmware can do this. It's not bonding; it's just keep-something-alive.

- **Load balancing (active/active, no reassembly)**. Different *connections* take different
  WANs — connection A via home, connection B via cellular, etc. Any *single* connection
  still rides one link. No combined speed for a single download. Different public IPs per
  connection break sticky/authenticated sessions (your bank logs you out when one of three
  source IPs shows up unexpectedly).

- **SOCKS / HTTP-proxy splitting**. Some browser-extension solutions try to round-robin
  HTTPS requests across two upstream proxies on different WANs. Works for some web
  browsing. Breaks for anything stateful (logged-in apps), can't help non-browser apps,
  utterly fails for streaming/VDI/games.

- **WireGuard tunnels to home, no MPTCP**. A single WAN, encrypted. Doesn't help with
  bonding multiple WANs at all.

None of these give you "one TCP connection's bandwidth equals the sum of multiple WAN
speeds" or "the connection survives a WAN dying mid-stream without dropping." Only an MPTCP
endpoint you control — the VPS — does both.

## Why "in the cloud" instead of "at home"

Why can't the home server (Mac Studio, Synology, anything on the home LAN) be the
reassembly point?

Because **the bonding endpoint has to be on the *other* side of your WANs from the Beryl**.
The whole point is to combine paths going *out* from your home — so the reassembly point
needs to be somewhere those paths can converge before reaching the destination. If you put
it at home, your cellular path would have to traverse... home internet... to get to your
home server. That defeats the entire purpose; cellular contributes nothing.

It has to be in a place that all of your WANs can reach as a single, common destination.
The public cloud is the natural answer. A VPS in DigitalOcean SFO3 (or Vultr LAX, or AWS
Lightsail, or wherever) is reachable from your home internet, from your cellular tether,
from cruise wifi, from anywhere — all over standard internet routing. That's why the VPS is
the right architectural location.

## Sizing — why $6/mo is enough

A bonded MPTCP endpoint isn't doing heavy compute. The work is:

- Maintain a single MPTCP connection state (small)
- Process incoming subflow packets, reorder by sequence number, reassemble
- Encrypt/decrypt the Glorytun tunnel layer (Chacha20 — fast even on weak CPUs)
- Forward outbound to the real destination via standard kernel routing

For typical home + cellular bonding (~200-400 Mbps aggregate), **1 vCPU / 1 GB RAM is
plenty**. The CPU bottleneck, when it shows up, is always Glorytun's Chacha20 encryption,
not memory or network. A $6/mo droplet handles it.

You'd upgrade to 2 vCPU ($12/mo) if:
- You're sustaining 1 Gbps+ bonded throughput continuously
- Multiple bonded clients (4+) on the same VPS
- `htop` on the VPS shows `glorytun-tcp` pegged at 100% CPU during your speed tests

For everything else, 1 vCPU / 1 GB is sized right.

## Region choice

The VPS should sit near your **destinations**, not near you. If your home and your corporate
VDI gateway and your Tailscale Mac Studio are all in SoCal, you want a VPS in US-West (SFO,
LAX) regardless of whether you're physically at home, on a cruise in Alaska, or in a hotel
in Tokyo. The Beryl-to-VPS leg is the bonded encrypted path; the VPS-to-destination leg
should be short.

See `vps-options.md` for the provider/region comparison.

## One more architectural note: the VPS is also your egress identity

A side effect of the architecture: your public IP, as seen by every destination server, is
the **VPS's** IP, not any of your WAN IPs. That means:

- Geolocation-based services see you as wherever the VPS is. SFO3 = San Francisco.
- IP-pinned services (some bank logins, corporate IP allowlists) see one stable IP — no
  more "you logged in from a different IP" alarms when your cellular flips towers.
- DDoS or CGNAT issues at any one of your WAN paths don't expose you — the destination
  sees only the VPS.

This isn't the goal of the setup, but it's a useful side effect, especially for remote work
where corp VPNs / VDI gateways want to see a consistent client IP.

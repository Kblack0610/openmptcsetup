# Testing — verification commands and recipes

How to *prove* the bonded setup is working at each stage, not just hope it is. Organized by
what you're trying to verify, in roughly the order you hit them during a build.

If you're trying to diagnose something broken, go to `troubleshooting.md`. This doc is for
the **green-path checks** that confirm forward progress.

Sections:
1. [The single proof-of-tunnel test (most important)](#proof-of-tunnel)
2. [Per-WAN status](#per-wan-status) — each WAN up, has an IP, has a gateway
3. [Per-WAN egress identity](#per-wan-egress) — which WAN is each interface using?
4. [Bonded throughput / aggregation tests](#aggregation-tests)
5. [Scheduler-aware behavior tests](#scheduler-tests) — does redundant actually survive a drop?
6. [Tailscale direct vs DERP](#tailscale-direct)
7. [Latency / jitter for VDI](#vdi-quality)
8. [Sanity-check the VPS side](#vps-checks)

---

## The single proof-of-tunnel test (most important) {#proof-of-tunnel}

The one command that proves the entire chain works:

```bash
curl -s ifconfig.me
```

**Run it from a device behind the Beryl** (your laptop on Wi-Fi, a phone on the Beryl's
SSID, etc. — NOT from the Beryl itself, NOT from the VPS).

Expected output:
- ✅ **Your VPS's public IP** (e.g., `137.184.180.60`) — the tunnel is your egress. Bonded
  setup is working end-to-end: client → Beryl → Glorytun (MPTCP across WANs) → VPS →
  internet → reply path same in reverse.
- ❌ **Your home ISP's IP** (e.g., `66.27.123.93`) — your client traffic is *bypassing* the
  tunnel. Either the tunnel is down (see `troubleshooting.md` § "VPN is not running") or
  ByPass rules are diverting your traffic around it.
- ❌ **Your cellular carrier's CGNAT IP** (e.g., `172.58.x.x` for T-Mobile) — your client
  is somehow not using the Beryl at all, or only one WAN is active and your traffic isn't
  going through the tunnel.

> Why this works: each WAN exits through a different public IP, but with the bonded tunnel
> running, all your traffic enters the Beryl → gets MPTCP-split across WANs → recombines
> at the VPS → exits to `ifconfig.me` from the VPS. The reply comes back via the same
> route. So `ifconfig.me` only ever sees the VPS — that's the single-egress-IP property
> that proves bonding is real.

### Variants for narrowing things down

```bash
# Use a different IP-echo service in case ifconfig.me cached / rate-limited:
curl -s https://api.ipify.org
curl -s https://icanhazip.com
curl -s https://ipinfo.io/ip

# IPv6 — if your VPS has IPv6 and IPv6 connected:
curl -s https://api64.ipify.org
```

If all of them show the VPS IP, the tunnel is genuinely the egress. If `ifconfig.me` shows
VPS but `ipinfo.io/ip` shows ISP, that's a per-domain bypass rule (unlikely unless you
configured one).

---

## Per-WAN status {#per-wan-status}

```bash
ssh root@192.168.100.1

# All configured WANs, one line each
ifstatus wan1 wan2 wan3 2>/dev/null | grep -E '"up"|"address"|"gateway"|"device"'

# Specific WAN, full detail
ifstatus wan1

# Live link state across all interfaces
ip addr show | grep -E '^[0-9]+:|inet '
```

For each WAN you expect to be up, you want:
- `"up": true`
- A populated `"address":` line
- A populated `"gateway":` line
- A populated `"device":` line matching the physical interface you assigned (e.g., `"device": "usb0"`)

If any of these are missing, that WAN isn't actually connected — see
`troubleshooting.md` § "No IP defined".

---

## Per-WAN egress identity {#per-wan-egress}

You want to confirm that each WAN's egress IP matches the expected upstream provider — useful
during build to make sure you wired things correctly.

```bash
ssh root@192.168.100.1

# What public IP does each WAN egress through, independently?
curl --interface eth0 -s ifconfig.me   # home / Starlink — expect your home WAN IP
curl --interface usb0 -s ifconfig.me   # cellular — expect a carrier CGNAT IP
curl --interface wwan -s ifconfig.me   # Wi-Fi-as-WAN — expect ship/hotel/phone-2 NAT IP

# And the default route (with the tunnel up, the default goes via the tunnel)
curl -s ifconfig.me                    # expect VPS public IP
```

The first three target individual WANs and bypass the tunnel — confirms each WAN works on
its own. The fourth is the same as the proof-of-tunnel test above.

If `--interface eth0` returns nothing or times out, that WAN doesn't have a working
internet path. If `curl -s ifconfig.me` (no interface) returns one of your individual WAN
IPs instead of the VPS IP, the tunnel isn't acting as the default route.

---

## Bonded throughput / aggregation tests {#aggregation-tests}

The goal is to compare *single-WAN* throughput against *bonded* throughput on the same test
methodology, so the comparison is meaningful.

### Single-WAN baselines (do this first)

Disable all but one WAN in LuCI (Settings page → uncheck Multipath TCP for the ones you want
out of the test) → Save & Apply. Then from a device behind the Beryl:

```bash
# 500 MB download — adjust size to ~10-20s of transfer at your line speed
curl -o /dev/null https://speed.cloudflare.com/__down?bytes=500000000 \
  -w "speed_download=%{speed_download} bytes/s\ntime_total=%{time_total}s\n"
```

Note the `speed_download` value (it's in bytes/sec — divide by 125_000 for Mbps).

Repeat with **only home** enabled, **only cellular** enabled, etc. Now you have a baseline
per WAN.

### Bonded (default scheduler)

Re-enable all WANs in LuCI. Confirm the scheduler:

```bash
ssh root@192.168.100.1
uci get network.globals.mptcp_scheduler   # should be 'default' for aggregation tests
# If it's 'redundant', set it for this test:
# uci set network.globals.mptcp_scheduler='default'
# uci commit network && /etc/init.d/network restart
```

Re-run the same Cloudflare download from the same client device. Expected result:

- **Bonded ≈ sum of individual WANs × 0.85** — that ~15% loss is tunnel overhead (Glorytun
  + MPTCP per-packet headers, plus path-stall stragglers in default scheduler).
- **Bonded ≈ max(individual WANs)** with **`redundant`** scheduler — by design, redundant
  doesn't aggregate; it duplicates packets across paths.

If bonded is much less than the expected aggregate with `default`, see
`troubleshooting.md` § "Bonded throughput is way less than the sum of individual WANs."

### iperf3 — for cleaner numbers when speed.cloudflare.com is the variable

The VPS install does NOT install iperf3 (the OMR installer script's `IPERF="no"` flag
explicitly skips it). To enable on the VPS:

```bash
# On the VPS (port 65222):
ssh -p 65222 root@<VPS_IP>
apt install -y iperf3
ufw allow 65400/tcp comment 'iperf3'
iperf3 -s -p 65400 &
```

Then from your client behind the Beryl:

```bash
iperf3 -c <VPS_IP> -p 65400 -t 30      # 30-second TCP throughput
iperf3 -c <VPS_IP> -p 65400 -t 30 -u -b 200M   # UDP at 200 Mbps offered
```

The TCP run rides the MPTCP-bonded tunnel and shows real aggregation. The UDP run shows raw
path capacity through Glorytun TCP (UDP-in-TCP wrapping).

---

## Scheduler-aware behavior tests {#scheduler-tests}

### Confirm `redundant` actually survives a mid-stream link drop

```bash
# On your laptop behind the Beryl:
# Start a long-running download:
curl -o /dev/null https://speed.cloudflare.com/__down?bytes=2000000000 \
  -w "%{speed_download}\n" &
DLPID=$!

# In another terminal, SSH to the Beryl and drop a WAN:
ssh root@192.168.100.1 'ifdown wan1; sleep 30; ifup wan1'

# Watch your download. With `redundant`, it should NOT pause or error.
# With `default`, expect a 2-5 second stall while MPTCP retransmits on the live paths.
wait $DLPID
```

This is the headline `redundant`-scheduler claim. Worth verifying once on your real setup
because the survival window depends on the specific WAN that drops.

### Switch scheduler live (no reboot)

```bash
ssh root@192.168.100.1
# Pick one:
uci set network.globals.mptcp_scheduler='default'      # aggregation
uci set network.globals.mptcp_scheduler='redundant'    # seamless
uci set network.globals.mptcp_scheduler='roundrobin'   # alternating
uci commit network
/etc/init.d/network restart   # ~5s, drops connections briefly
```

After restart, re-run the proof-of-tunnel `curl -s ifconfig.me` to confirm the tunnel came
back. Then re-run whatever throughput test you care about.

---

## Tailscale direct vs DERP {#tailscale-direct}

If you use Tailscale through this setup, you want it going **direct**, not via DERP relay.
Direct goes peer-to-peer through your bonded WANs; DERP relays through shared Tailscale
servers (slow).

```bash
# From a Tailscale client (your laptop or phone behind the Beryl):
tailscale ping <peer-name>

# Look for "direct" in the response — e.g.:
#   pong from <peer> (...) via DERP(sea)   ← BAD: relay-routed
#   pong from <peer> (...) via 192.0.2.42:41641   ← GOOD: direct
```

If you see DERP, you're missing the ByPass rules for Tailscale's UDP ports. See
`troubleshooting.md` § "Tailscale collapses to ~5 Mbps over the bonded tunnel" and
`runbooks/beryl-ax.md` Phase 7.

---

## Latency / jitter for VDI {#vdi-quality}

VDI quality is bounded by jitter (latency variability), not just raw latency. Measure both.

```bash
# From a client behind the Beryl, target the VPS:
ping -c 100 <VPS_IP> | tail -5
# Look at: rtt min/avg/max/mdev = ... — mdev is the standard deviation (jitter)

# Better — mtr for a moving window:
mtr -n -r -c 100 <VPS_IP>
# Wnt = packet loss should be 0.0%, StDev should be low (< 5 ms ideal for VDI)
```

For VDI specifically:
- **Average RTT** to VPS: < 100ms (typical home + SFO3 ≈ 30-60ms)
- **Jitter (mdev / StDev)**: < 10ms tolerable, < 5ms ideal
- **Packet loss**: 0% — anything else means a WAN is unhealthy

The `redundant` scheduler trades throughput for *consistent* latency — packet duplication
across paths means the first arrival wins, so the perceived jitter is `min(jitter_each_path)`.

```bash
# Force-test with redundant scheduler on, then default off:
ssh root@192.168.100.1 'uci set network.globals.mptcp_scheduler=redundant; uci commit network; /etc/init.d/network restart'
sleep 10
# Run ping/mtr again from client
ssh root@192.168.100.1 'uci set network.globals.mptcp_scheduler=default; uci commit network; /etc/init.d/network restart'
sleep 10
# Run again, compare jitter
```

---

## Sanity-check the VPS side {#vps-checks}

Confirm the VPS is in a healthy state. Useful when the Beryl shows "Can't ping server" or
"VPN is not running" — you want to know if the issue is at the Beryl, the network in
between, or the VPS itself.

```bash
# From your laptop (NOT from the Beryl — testing reachability the same way the Beryl does):
# Replace <VPS_IP> with the address in ./.env or vps-credentials.txt

# Quick TCP probe of every port the Beryl uses
for p in 22 443 65001 65101 65222 65400 65500; do
  timeout 4 bash -c "exec 3<>/dev/tcp/<VPS_IP>/$p" 2>/dev/null \
    && echo "$p: OPEN" || echo "$p: CLOSED/FILTERED"
done
```

Expected on a healthy install:
- `22: CLOSED/FILTERED` — sshd moved to 65222 by OMR
- `443: CLOSED/FILTERED` — unless you specifically opened it
- `65001: OPEN` — Glorytun TCP
- `65101: OPEN` — Shadowsocks
- `65222: OPEN` — sshd (post-OMR-install port)
- `65400: OPEN` only if you installed iperf3
- `65500: OPEN` — OMR admin API

The OMR admin API on 65500 is the one the Beryl talks to for key sync — verify it
specifically:

```bash
curl -sk --max-time 8 https://<VPS_IP>:65500 -o /dev/null -w "%{http_code}\n"
# Expect 200 (or 401 — the API is up but you didn't auth, which is also "alive")
```

If `65500: OPEN` and `curl -sk ... :65500` returns 200, the VPS is healthy and the
"VPN not running" problem is at the Beryl. See `troubleshooting.md` § "VPN not running".

If `65500: CLOSED/FILTERED`, the VPS firewall is closed or `omr-admin` isn't running:

```bash
ssh -p 65222 root@<VPS_IP>
systemctl status omr-admin
ufw status numbered                  # confirm 65500 is allowed
ss -tlnp | grep 65500                # is anything actually listening?
```

### Confirm the right kernel is running

The OMR installer flips the VPS to a custom MPTCP-patched kernel. If a kernel upgrade
clobbered it, things break silently.

```bash
ssh -p 65222 root@<VPS_IP>
uname -r
# Expect: something like 6.12.x+deb13.1-amd64 (the MPTCP kernel from OMR's deb repo).
# If you see a stock 6.1.x or 6.5.x without the +deb suffix, the kernel got swapped — you'll
# need to reinstall the MPTCP kernel.
```

### Reading the credentials file

```bash
cat ~/dev/openmptcsetup/vps-credentials.txt
```

Should contain at minimum:
- `Server IP: <ip>`
- `Server username: openmptcprouter`
- `Server key: <hex>` (this is what goes into LuCI)
- `ADMIN API Server key: <different hex>` (NOT what you paste into LuCI — wrong key is a
  common "can't auth" cause; see `troubleshooting.md` § "VPN not running")

---

## When you're at the hotel before a cruise — the must-pass tests

If you're racing against a departure, the minimum set that proves you're ready to board:

1. **Proof-of-tunnel:** `curl -s ifconfig.me` from a client returns VPS IP — not your hotel
   wifi's IP, not your S25 carrier IP. **This is the only non-negotiable.**
2. **Dashboard:** OMR Status shows VPS row green, Glorytun TCP UP, Shadowsocks running, no
   "empty key" warnings.
3. **Failover:** drop a WAN with `ssh root@192.168.100.1 'ifdown wan1; sleep 10; ifup wan1'`
   while watching the dashboard. Other WANs stay up, tunnel survives.
4. **Config backup:** `ssh root@192.168.100.1 'tar czf - /etc/config' >
   ./beryl-config-backup-$(date +%F).tar.gz` — so you can restore on the ship without
   internet if anything goes sideways.

Skip iperf3 and detailed throughput characterization at the hotel — those are nice-to-have,
not blockers. You can do those at sea.

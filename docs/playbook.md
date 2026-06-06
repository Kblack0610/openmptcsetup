# Command playbook — monitor the bonded setup

Quick-reference cheatsheet for the commands you actually reach for during day-to-day
monitoring and live debugging. Copy-paste friendly, grouped by what you're trying to learn.

- For **"prove it works"** verification recipes (proof-of-tunnel, throughput, scheduler
  tests), use `testing.md`.
- For **"something specific is broken"** failure-mode lookups, use `troubleshooting.md`.
- This file is for **"show me what the system is doing right now."**

---

## Cheatsheet — the 10 commands

Once you're SSH'd in (`ssh root@192.168.100.1`), these answer 90% of "is it working?" questions:

```bash
# 1. Interface state — what's up, what's not, which IPs?
ip -br addr show

# 2. One specific WAN, full detail (replace wan1 with wan2/wan3 as needed)
ifstatus wan1

# 3. Live byte counters across all WANs — kick off a download and watch both move
watch -d -n 1 'grep -E "eth0|usb0|wwan" /proc/net/dev'

# 4. MPTCP endpoint list — which paths the kernel knows about
ip mptcp endpoint show

# 5. Active MPTCP sockets with their subflows — proof that one app is using multiple WANs
ss -tiM

# 6. MPTCP kernel counters — how many MPCapable handshakes, MPJoins, fallbacks
nstat -a | grep -iE 'mptcp|tcpext.*MPCapable'

# 7. Tunnel service health — is Glorytun / Shadowsocks actually running?
service glorytun-tcp status; service shadowsocks-libev-ss-redir-mptcp status; service omr-tracker status

# 8. Live tunnel logs
logread -f | grep -iE 'omr|glorytun|shadowsocks|mptcp'

# 9. Current MPTCP scheduler
uci get network.globals.mptcp_scheduler

# 10. From a LAN client (laptop, phone) — the canonical proof-of-tunnel
curl -s ifconfig.me           # MUST return your VPS IP, not your ISP/carrier IP
```

If you have to memorize one: **#10 from a LAN client**. The whole stack works ⇔ that returns
the VPS IP.

---

## By task

### "Is bonding active right now?" {#bonding-active}

The dashboard gives a visual answer, but for the real proof drop to SSH:

```bash
# Both WANs have IPs?
ip -br addr show | grep -E 'eth0|usb0|wwan'
# Expect: eth0 UP <ip>/24, usb0 UP <ip>/24, etc. — any DOWN means that path is dead.

# Both moving traffic at the same time?
watch -d -n 1 'grep -E "eth0:|usb0:|wwan:" /proc/net/dev'
# Run a speedtest from a LAN client (https://speed.cloudflare.com). Both RX columns
# should increment together. If only one moves, only one WAN is being used.

# Multiple subflows on a single MPTCP connection?
ss -tiM | head -40
# Look for the same connection ID appearing on multiple subflows. If you see only
# one subflow per connection, MPTCP fell back to single-path.
```

The most rigorous proof is `ss -tiM` showing multi-subflow sockets during sustained
traffic. Counters can be misleading if traffic happens to favor one path; subflows can't.

### "Which interface is each WAN, and is it up?" {#wan-status}

```bash
# Single-line summary
ip -br addr show
ip -br link show

# Per-WAN OMR-aware status (netifd's view)
ifstatus wan1 2>/dev/null | grep -E '"up"|"address"|"gateway"|"device"|"uptime"'
ifstatus wan2 2>/dev/null | grep -E '"up"|"address"|"gateway"|"device"|"uptime"'
ifstatus wan3 2>/dev/null | grep -E '"up"|"address"|"gateway"|"device"|"uptime"'

# All three at once if you want JSON
ifstatus wan1 wan2 wan3
```

### "What public IP does each WAN egress through?" {#wan-egress}

```bash
curl --interface eth0 -s ifconfig.me       # home — expect your ISP's public IP
curl --interface usb0 -s ifconfig.me       # cellular — expect carrier CGNAT (10.x or 100.64.x or 172.58.x)
curl --interface wwan -s ifconfig.me       # Wi-Fi-as-WAN — depends on what AP you joined
curl -s ifconfig.me                         # default route — expect your VPS public IP (= tunnel egress)
```

If the first three return your real WAN IPs but the fourth doesn't return the VPS IP, the
tunnel isn't acting as the default route. See `troubleshooting.md` § "VPN is not running".

### "Are the tunnel services running?" {#service-health}

```bash
# Individual services
service glorytun-tcp status
service shadowsocks-libev-ss-redir-mptcp status
service omr-tracker status
service omr-bypass status

# Everything OMR-related at a glance
systemctl list-units --state=active 2>/dev/null | grep -iE 'glorytun|shadow|omr|mptcp'

# Listening ports — confirms services are actually bound
ss -tlnp | grep -E '65001|65101|65500'

# Or via uci, the OMR config knobs the services run with
uci show glorytun
uci show shadowsocks-libev | grep -E 'server|key|method' | head -10
```

### "What is MPTCP doing under the hood?" {#mptcp-internals}

The MPTCP kernel exposes its state via `ip mptcp` and `/proc/net/netstat`. Useful when
"the dashboard says green but throughput is wrong":

```bash
# Endpoints the kernel knows about (one per WAN should be registered)
ip mptcp endpoint show

# Limits — how many subflows the kernel will allow per connection
ip mptcp limits show

# All active MPTCP sockets with subflow detail (the strongest "is it bonding?" signal)
ss -tiM

# Cumulative kernel counters since boot
nstat -a | grep -iE 'mptcp'
# Watch for:
#   MPTcpExtMPCapableSYNTX     ← MPTCP-enabled SYNs you sent
#   MPTcpExtMPCapableACKRX     ← server agreed to MPTCP (positive = MPTCP path is alive)
#   MPTcpExtMPJoinSynRx        ← additional subflows joining = the 2nd+ WAN activating
#   MPTcpExtMPCapableFallbackACK ← fell back to plain TCP — bad signal if growing

# Raw netstat counters
cat /proc/net/netstat | grep -i MPTcp | tr ' ' '\n' | head -50
```

`ss -tiM` is the killer command. During a sustained download, you'll see one user-facing
TCP socket with **multiple subflows** listed under it — one per WAN. Single subflow = MPTCP
fell back to single-path (often a config or upstream MPTCP-blocking issue).

### "What does the scheduler / config say?" {#config-inspection}

```bash
# Current scheduler
uci get network.globals.mptcp_scheduler

# All MPTCP-related config knobs
uci show network | grep -iE 'mptcp|scheduler'

# Per-WAN MPTCP role (master / on / backup / off)
uci show network.wan1
uci show network.wan2

# LAN bridge configuration (the gl-mt3000 gotcha — lan must be a bridge for Wi-Fi clients)
uci show network.lan
ip -br link show master br-lan 2>&1

# Firewall zones
uci show firewall | grep -E 'name|network'

# OMR bypass rules
uci show omr-bypass | head -40
```

### "What's the USB tether doing?" {#usb-tether}

```bash
# Did the phone enumerate?
lsusb

# Did RNDIS bind?
dmesg | grep -iE 'rndis|usb0|cdc_ether' | tail -10

# Did netifd bring usb0 up?
ip addr show usb0
ifstatus wan_usb 2>/dev/null    # or whatever you named the OMR WAN block

# Live dmesg while you plug/unplug
dmesg -w
```

If `lsusb` shows the phone but `dmesg` shows no RNDIS line → wrong USB mode (the phone is
in MTP/PTP not USB-tethering). Toggle USB tethering on the phone.

### "What's the Wi-Fi side doing?" {#wifi-state}

```bash
# Which interfaces does each radio have, in which mode?
iw dev
# AP mode = the Beryl is broadcasting an SSID for clients
# managed mode = the Beryl is a client joining someone else's SSID (Wi-Fi-as-WAN)

# AP status / which clients are connected
iw dev phy1-ap0 station dump | head -30

# What clients have a DHCP lease?
cat /tmp/dhcp.leases

# Live Wi-Fi + DHCP log — invaluable when "phone connects then drops"
logread -f | grep -iE 'hostapd|wpa|dnsmasq|dhcp'
```

The combined `hostapd|wpa|dnsmasq|dhcp` filter is the fastest way to root-cause "phone
associates but never gets an IP" — see `troubleshooting.md` § "Phone associates to Wi-Fi
but never gets an IP."

### "Watch live activity" {#live-monitoring}

```bash
# Per-WAN byte counters, highlighting changes
watch -d -n 1 'grep -E "eth0:|usb0:|wwan:" /proc/net/dev'

# Per-WAN OMR-state polling
watch -d -n 2 'ifstatus wan1 | grep -E "up|address|gateway"; echo; ifstatus wan2 | grep -E "up|address|gateway"'

# Live OMR / tunnel log (the most useful live tail)
logread -f | grep -iE 'omr|glorytun|shadowsocks|mptcp|wan'

# CPU + memory + network interfaces in one view (if htop is installed)
htop
# If htop missing, use: top -d 1

# Live MPTCP subflows during a transfer
watch -n 2 'ss -tiM | head -20'
```

### "What does the VPS see?" {#vps-side}

```bash
# From your laptop (the SSH port moved to 65222 post-install)
ssh -p 65222 root@<VPS_IP>

# On the VPS — confirm tunnel services
ss -tlnp | grep -E '65001|65101|65222|65500'
systemctl status glorytun-tcp@tun0 omr-admin

# Confirm the MPTCP kernel is the one running
uname -r        # expect 6.12.x+deb13.x — the OMR MPTCP-patched kernel

# Is the server receiving traffic on the tunnel?
ip -s link show gt-tun0      # bytes incrementing = tunnel is carrying traffic

# Server-side logs
journalctl -u glorytun-tcp@tun0 -n 100 --no-pager
```

If the VPS shows `gt-tun0` bytes incrementing but the Beryl dashboard says "no tunnel,"
network between Beryl and VPS is fine but the *Beryl side* lost state — usually a Save &
Apply re-trigger fixes it.

---

## One-liners you'll actually re-use

A few combos that show up over and over in this codebase's debug sessions:

```bash
# "Show me everything about the bonded path in one shot"
ssh root@192.168.100.1 'echo "=== Interfaces ==="; ip -br addr show; \
  echo "=== WAN status ==="; for w in wan1 wan2 wan3; do \
    ifstatus $w 2>/dev/null | grep -E "\"up\"|\"address\"|\"gateway\""; echo "---"; \
  done; \
  echo "=== MPTCP endpoints ==="; ip mptcp endpoint show; \
  echo "=== Scheduler ==="; uci get network.globals.mptcp_scheduler; \
  echo "=== Tunnel services ==="; \
  for s in glorytun-tcp shadowsocks-libev-ss-redir-mptcp omr-tracker; do \
    printf "%s: " "$s"; service "$s" status 2>&1 | head -1; done'

# "Watch the bond do its thing during a download"
ssh root@192.168.100.1 \
  'watch -d -n 1 "echo --WANs--; grep -E \"eth0:|usb0:|wwan:\" /proc/net/dev; \
                  echo --tunnel--; ip -s link show gt-tun0 2>/dev/null | tail -3; \
                  echo --subflows--; ss -tiM | head -10"'

# "Compare per-WAN egress IPs vs tunnel egress"
ssh root@192.168.100.1 'echo "Per-WAN egress:"; \
  for i in eth0 usb0 wwan; do \
    printf "  %s: " "$i"; curl --interface "$i" -s --max-time 5 ifconfig.me; echo; \
  done; \
  echo "Default route egress: $(curl -s --max-time 5 ifconfig.me)"'

# "Dump the diagnostic bundle to paste somewhere"
ssh root@192.168.100.1 'logread | tail -200; echo "===="; \
  ip -br addr; echo "===="; ifstatus wan1; echo "===="; ifstatus wan2; \
  echo "===="; uci show network | grep -E "wan|mptcp|lan"' > /tmp/beryl-debug.txt
```

---

## See also

- `testing.md` — verification recipes (proof-of-tunnel, throughput, scheduler behavior,
  Tailscale direct vs DERP)
- `troubleshooting.md` — symptom-indexed failure modes when one of these commands shows
  something wrong
- `concepts.md` — what MPTCP/scheduler/role/bridge actually mean

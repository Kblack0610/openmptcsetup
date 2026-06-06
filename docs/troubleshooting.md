# Troubleshooting — failure modes and fixes

Cross-reference for the failure modes that actually happened during real builds. Organized
by symptom. If you're trying to *understand* a knob rather than fix a broken thing, go to
`concepts.md` instead.

Sections:
1. [Dashboard says "No IP defined" on a WAN](#dashboard-no-ip-defined)
2. [Dashboard says "VPN is not running (empty key)"](#vpn-not-running-empty-key)
3. [`usb0` exists but is DOWN with no IP](#usb0-exists-but-down)
4. [`usb0` missing entirely after tether](#usb0-missing-entirely)
5. [Can't log into LuCI after first OMR boot](#cant-log-into-luci)
6. [`opkg: command not found`](#opkg-not-found)
7. [VPS install: SSH never came back on port 65222](#vps-install-ssh-65222)
8. [VPS install: apt-get lock error](#vps-install-apt-lock)
9. [`vps-create-do.sh` exits silently after "Registering SSH key"](#vps-create-do-silent-exit)
10. [Bonded throughput is way less than the sum of individual WANs](#bonded-throughput-low)
11. [Tailscale collapses to ~5 Mbps over the bonded tunnel](#tailscale-derp-relay)
12. [Cruise / hotel wifi: tunnel won't establish](#cruise-tunnel-blocked)
13. [Building VPS from cruise/hotel internet fails on high ports](#building-from-cruise-wifi)
14. [Phone hangs trying to join 5GHz AP (`radio1`)](#phone-hangs-5ghz)
15. [Phone hangs trying to join 2.4GHz AP (`radio0`)](#phone-hangs-2ghz)
16. [Phone refuses an SSID whose password you just changed](#phone-cached-credentials)
17. [Wireless Overview shows "Encryption: None" but you set WPA2](#encryption-none-after-save)
18. [Which radio is which? I have `radio0` and `radio1` backwards](#radio-mapping-confused)

---

## Dashboard: "No IP defined" {#dashboard-no-ip-defined}

The OMR Status dashboard shows a WAN card with **"No IP defined"** + "No gateway defined."

**Cause #1 (most common):** Physical interface dropdown set to a **logical** name (e.g.
`wan1`/`wan2`) instead of a real physical (`eth0`, `eth1`, `usb0`, `wwan`). Picking `wan1`
here creates a circular reference; the interface never binds.

**Fix:** edit the WAN block, change Physical interface to the actual physical (`usb0` for a
USB tether, `eth0` for home/Starlink, `wwan` for Wi-Fi-as-WAN). Save & Apply.

**Cause #2:** Protocol left as **Static address** (the OMR default) with no IPv4 fields
filled in. Static needs an IP+netmask+gateway you don't have because the WAN source uses
DHCP.

**Fix:** change Protocol to **DHCP client**. The red required-field markers vanish.

**Cause #3:** Type is **MacVLAN** (the OMR default) pointing at a physical that doesn't have
a VLAN-tagged upstream. MacVLAN can't get an address out of a normal modem/tether/wifi.

**Fix:** change Type to **Normal**. See `concepts.md` § Interface type for when MacVLAN is
actually useful.

---

## VPN not running — "ShadowSocks Rust is not running (empty key)" {#vpn-not-running-empty-key}

Dashboard's OMR card is red with one or more of:

- "ShadowSocks Rust is not running (empty key)"
- "VPN is not running"
- "DNS issue: can't resolve hostname"
- "Can't ping server"

But your WAN cards are green and `curl ifconfig.me` works (returning your local ISP IP, not
the VPS IP).

**Cause:** OMR auto-fetches the per-VPN keys (Shadowsocks, Glorytun, MLVPN, DSVPN) from the
VPS admin API on port 65500, authenticating with your **Server key**. The fetch runs when:
(a) the router has internet AND (b) a Save & Apply triggers the OMR config-sync. If you
configured the WAN *after* pasting the Server key but the fetch never re-ran, the per-VPN
keys stay empty and Glorytun/Shadowsocks can't start.

**Fix:** go to System → OpenMPTCProuter → Settings, hit **Save & Apply** at the bottom
*without changing anything*. This re-triggers the fetch. Wait 30-60s. Dashboard goes green.

**Verify it worked:**

```bash
ssh root@192.168.100.1
grep -iE 'key|host' /etc/config/glorytun | head -10
# Expect: key=<long hex>, host=<VPS IP>
service glorytun-tcp status   # active
curl -s ifconfig.me           # NOW returns your VPS IP, not your ISP IP
```

If the keys *still* don't populate after Save & Apply:

```bash
logread | grep -iE 'omr-server|tracker|glorytun' | tail -30
```

Look for "connection refused," "unauthorized," or "no route to host." Most common deeper
issue: the **Server key** you pasted has a typo, or it's the **ADMIN API Server key** by
mistake (a different key in the same `vps-credentials.txt` file). Re-copy from the line
labeled exactly `Your OpenMPTCProuter Server key:` — not the ADMIN API one.

---

## `usb0` exists but `state DOWN`, no IP {#usb0-exists-but-down}

`ip addr show usb0` shows the interface present (with a MAC), but `state DOWN` and no `inet`
line.

**Cause:** Normal pre-configuration state. OpenWrt's netifd doesn't bring up or DHCP an
interface until something — a WAN config block in `/etc/config/network`, typically — points
at it. The phone's tether driver loaded (RNDIS attached, `usb0` MAC assigned), but OMR
hasn't been told to use this interface yet.

**Fix:** configure `usb0` as a WAN in OMR Settings (Type Normal, Protocol DHCP, Physical
interface `usb0`). Save & Apply. Within 5-10s, `usb0` comes UP with a 192.168.42.x lease
from the phone.

**Quick manual proof if you want to validate the tether independently first:**

```bash
ssh root@192.168.100.1
ip link set usb0 up
udhcpc -i usb0 -n -q
ip addr show usb0   # should now show inet 192.168.42.x
```

This proves the phone is handing out DHCP correctly. The wizard step then formalizes it
via netifd.

---

## `usb0` missing entirely after tethering {#usb0-missing-entirely}

`ip link` doesn't list `usb0` at all after plugging in the phone and enabling USB tethering.

**Diagnose:**

```bash
dmesg | tail -30
lsusb
```

- If `lsusb` doesn't list your phone → the phone isn't enumerating at all. Bad cable, USB-C
  data lane disabled (some Samsung "USB controlled by" prompts default to "Phone" rather
  than "Connected device" — switch it), or the phone is in a non-data charging-only mode.
- If `lsusb` shows the phone but `dmesg` shows no `rndis_host` line → phone enumerated but
  in the wrong USB mode (MTP/PTP). On the phone, explicitly toggle USB tethering off and
  back on, or in some Samsung firmwares the toggle is under Settings → Connections →
  Mobile Hotspot and Tethering → USB tethering.
- If `dmesg` shows `rndis_host ... usb0: register 'rndis_host'` but `ip link` doesn't list
  `usb0` → very rare, likely a kernel state issue. Replug and re-check.

**Note:** the runbook's older `opkg install kmod-usb-net-rndis` step is **obsolete** for
current Beryl AX OMR images — RNDIS is in the kernel modules built into the official image.
Also, current builds use `apk`, not `opkg`. Don't waste time fighting the package manager.

---

## Can't log into LuCI after first OMR boot {#cant-log-into-luci}

Browser at `http://192.168.100.1`, username `root`, "password incorrect" no matter what you
try.

**Cause:** OMR's default root password on first flash is **empty**. People often type
something — anything — because the field looks like it requires input.

**Fix:** at the password prompt, just press **Enter** with an empty field. You'll get in.
Then immediately set a real password at System → Administration → Router Password.

If that doesn't work and you've already set a password and forgotten it:

```bash
# OpenWrt failsafe boot recovery:
# 1. Power off
# 2. Plug laptop into LAN port
# 3. Power on, immediately start pressing the reset button (you have ~5s)
# 4. Keep pressing until LED flashes rapidly
# 5. From laptop:
telnet 192.168.1.1
mount_root
passwd          # set new password
reboot
```

---

## `opkg: command not found` {#opkg-not-found}

Trying to run `opkg update` returns `-ash: opkg: not found`.

**Cause:** Current OpenWrt/OMR builds switched from `opkg` to **`apk`** (OpenWrt's new
Alpine-style package manager). The login banner literally tells you so — there's a cheat
sheet shown on every SSH login.

**Fix:**
| Old `opkg` | New `apk` |
|---|---|
| `opkg update` | `apk update` |
| `opkg install <pkg>` | `apk add <pkg>` |
| `opkg remove <pkg>` | `apk del <pkg>` |
| `opkg list-installed` | `apk info` |
| `opkg search <pkg>` | `apk search <pkg>` |

For the Beryl AX, you usually don't need *any* package install — RNDIS, USB serial, and the
core kernel modules are all in the official image.

---

## VPS install: SSH never came back on port 65222 {#vps-install-ssh-65222}

`vps-install.sh` runs the OMR installer over SSH, sleeps 90s for the reboot, then tries to
reconnect on port 65222 — and every attempt fails. Script exits with "VPS did not come back
on port 65222."

**Cause #1 — apt lock contention with cloud-init (the actual culprit historically).** Fresh
DO Debian droplets run `apt-daily` / `unattended-upgrades` on first boot. Our script's
`apt-get update` collided with it and failed. The remote script's `set -e` aborted before
the OMR installer ever ran. Then the reconnect failed because sshd was still on port 22, not
65222 (OMR never installed).

This is fixed in the current `vps-install.sh` (wait-for-apt-lock loop at the top of the
remote script). If you're on an older version, update the repo before retrying.

**Cause #2 — the OMR installer doesn't reboot automatically.** Newer OMR `debian-x86_64.sh`
prints "you need to reboot" but doesn't issue one. Our remote script needs to explicitly
trigger a reboot. Also fixed in the current `vps-install.sh`.

**Cause #3 — genuine network/install error.** If both fixes are in place and it still fails,
log into the VPS directly to see what state it's in:

```bash
# From the DO web console (Droplet → Access → Console) — bypasses SSH/firewall
cat /root/.omr-install-done     # marker the script writes on success
cat /root/openmptcprouter_config.txt   # keys (if install actually ran)
systemctl status sshd           # is sshd up?
ss -tlnp | grep -E '22|65222'   # what port is it on?
shorewall status                # firewall state
```

**Recovery:** if the keys exist on the VPS but vps-credentials.txt wasn't written locally
(SSH retrieval failed), you can read them off the DO web console and paste them manually.
Or `doctl compute droplet delete <id> --force` + `./vps-create-do.sh` for a clean rebuild —
$6 droplet, throwaway, cheap to redo.

---

## VPS install: apt-get lock error {#vps-install-apt-lock}

`vps-install.sh` log shows:

```
E: Could not get lock /var/lib/apt/lists/lock. It is held by process 710 (apt-get)
E: Unable to lock directory /var/lib/apt/lists/
```

**Cause:** Cloud-init's `apt-daily` ran in parallel with our install. Race condition.

**Fix:** already in current `vps-install.sh` (wait-for-apt-lock loop). If you somehow hit
it on an old build:

```bash
# Wait for cloud-init to finish, then retry vps-install.sh manually
ssh -i ~/.ssh/omr_vps root@<VPS_IP>
while pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null \
      || pgrep -x dpkg >/dev/null || pgrep -x unattended-upgrade >/dev/null \
      || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
  echo "waiting for apt..."; sleep 5
done
echo "apt clear — safe to run installer"
```

Then re-run `./vps-install.sh` from your laptop. The next time it should sail through.

---

## `vps-create-do.sh` exits silently after "Registering SSH key" {#vps-create-do-silent-exit}

Script prints `=== Registering SSH key with DigitalOcean ===` and immediately exits with
code 1. No droplet created, no `.env` written.

**Cause:** The SSH-key-lookup pipeline (`doctl ... | grep -F <fingerprint> | awk | head -1`)
returns exit 1 from `grep` when there's no match (your key isn't yet registered in DO — the
common first-run case). Combined with `set -euo pipefail`, the non-zero exit aborts the
script before the import step.

**Fix:** already in current `vps-create-do.sh` (`|| true` appended to the grep pipeline so
no-match is tolerated). If on an older build, that one-line patch fixes it.

---

## Bonded throughput is way less than the sum of single-WAN baselines {#bonded-throughput-low}

You measured each WAN alone (home alone, cellular alone) and they add up to X. Bonded with
`default` scheduler, you're seeing way less than X.

**Diagnose in order:**

1. **What scheduler are you on?** `redundant` ≠ aggregation; speed = your single fastest
   link. For combined-throughput tests, use `default`.

   ```bash
   uci get network.globals.mptcp_scheduler   # confirm
   ```

2. **VPS CPU bottleneck.** Glorytun encryption is CPU-bound. SSH to the VPS and `htop` while
   you run a speed test. If `glorytun-tcp` is pegged at ~100% on a 1-vCPU droplet, that's
   your ceiling. Upgrade to 2 vCPU ($12/mo) or use `default`-scheduler-only `wan` (drop
   one of the bonded paths to lighten encryption load).

3. **Path-latency mismatch.** Default scheduler stalls when one path is dramatically slower
   than others (head-of-line blocking). Cellular at 200 ms vs home eth at 20 ms is a 10x
   gap. **BLEST** scheduler (if exposed) handles this better:

   ```bash
   uci set network.globals.mptcp_scheduler='blest'
   uci commit network && /etc/init.d/network restart
   ```

4. **SQM misconfigured.** Per-WAN SQM with wrong rate values can crater throughput. Disable
   SQM on each WAN temporarily and re-test; if speed jumps, fix the rates. SQM rates should
   be your *real measured* speed, not your ISP's marketing number.

5. **Per-WAN MTU mismatch.** Cellular tethers sometimes have MTU 1428 vs Ethernet 1500.
   MPTCP path MTU discovery handles this but with some throughput cost. `ifconfig usb0`
   to see the MTU; if it's odd, set it explicitly in OMR's WAN config.

---

## Tailscale collapses to ~5 Mbps over the bonded tunnel {#tailscale-derp-relay}

Tailscale runs but `tailscale ping` shows it routing through a DERP relay instead of direct,
and throughput is terrible.

**Cause:** Tailscale's direct-connection probes (UDP 41641 + STUN on UDP 3478) get caught in
the OMR tunnel by default. The latency/jitter through Glorytun confuses Tailscale's NAT
traversal, it falls back to DERP relay (slow shared servers), and your bandwidth craters.

**Fix:** add OMR-ByPass rules so Tailscale traffic skips the tunnel and rides the WANs
directly. LuCI → OpenMPTCProuter → ByPass:

| Source | Destination | Protocol | Port | Why |
|---|---|---|---|---|
| LAN | any | UDP | 41641 | Tailscale direct |
| LAN | any | UDP | 3478 | STUN for NAT traversal |
| LAN | any | TCP | 443 | Tailscale DERP fallback (still need this) |

Save & Apply. Verify from a Tailscale client:

```bash
tailscale ping <peer>   # should say "via DERP" before, "direct" after
```

---

## Cruise / hotel wifi: tunnel won't establish {#cruise-tunnel-blocked}

WAN is up (you have internet from a captive-portal hotspot), but Glorytun won't connect.
Dashboard shows "VPN is not running."

**Cause:** Cruise/hotel wifi commonly uses deep packet inspection (DPI) to throttle or
block VPN-like UDP traffic. Glorytun UDP gets noticed and dropped.

**Fix:** make **Shadowsocks** the primary tunnel — it's TCP-based and looks like HTTPS,
which DPI almost never blocks. LuCI → OpenMPTCProuter → Settings:

- Primary tunnel: **Shadowsocks**
- Disable **Glorytun UDP** if it keeps failing
- Keep **Glorytun TCP** as a secondary if you want backup paths

Some captive portals are MAC-locked. If you reboot the Beryl mid-cruise, you may need to
re-do the captive-portal login from a laptop on the LAN.

---

## Building VPS from cruise/hotel internet fails on high ports {#building-from-cruise-wifi}

`./vps-install.sh` from cruise wifi: SSH to port 22 times out, or reconnect to 65222 never
succeeds, even though the droplet is healthy.

**Cause:** Cruise / hotel / corporate wifi often blocks outbound traffic to non-standard
ports. Ports 22, 65001, 65101, 65222, 65500 — all OMR's working ports — are commonly filtered.

**Diagnose:**

```bash
# Test outbound 22 to a known-good host
timeout 6 bash -c 'exec 3<>/dev/tcp/github.com/22' && echo OPEN || echo BLOCKED
# Test outbound to your VPS on each port
for p in 22 65001 65101 65222 65500 443; do
  timeout 6 bash -c "exec 3<>/dev/tcp/<VPS_IP>/$p" 2>/dev/null \
    && echo "$p: OPEN" || echo "$p: BLOCKED/FILTERED"
done
```

If GitHub:22 is blocked, your local network is filtering high ports — you can't run the
install from here.

**Fix:**
- **Best:** switch your laptop to **Starlink** (high ports open, no DPI) and build from
  there. Mid-cruise this works fine.
- **OK:** use your **S25 hotspot** to get the laptop online (cellular networks generally
  don't filter outbound high ports).
- **Workaround:** if you only have ship wifi and need to retrieve credentials, use the **DO
  web console** (Droplet → Access → Console — bypasses SSH entirely) and read
  `/root/openmptcprouter_config.txt` off the screen.

Don't try to build the VPS over ship wifi unless you've confirmed high ports are open.
See `runbooks/cruise-checklist.md` § "Can I build this from the cruise internet?"

---

## Phone hangs trying to join 5GHz AP (`radio1`) {#phone-hangs-5ghz}

You've configured the 5GHz radio as an AP, set WPA2-PSK with a password, and your phone scans the SSID, taps it, types the password, and **just hangs on "Connecting…" forever** — or fails without a useful error. The laptop on the same SSID may work fine.

**Cause #1 (overwhelmingly likely on 5GHz): Country Code is `00` / `driver default`.**

Country `00` is the "world / unset" regulatory domain. Modern Android and iOS implementations refuse to associate to 5GHz APs broadcasting country `00` because the phone can't validate that the AP's channel/power is legal in its current location. Symptom is exactly "hangs on Connecting…" — no error, no association complete.

The Status box in LuCI's Edit screen tells you: look for `Country: 00`. That's it.

**Fix:**
1. Edit the radio1 SSID → **Device Configuration** tab → **Country Code** dropdown
2. Change from `driver default` to **`US - United States`** (or your actual country)
3. Save (in dialog), then Save & Apply on the Wireless Overview page
4. Re-try phone. Association completes within a second or two.

**Verify from SSH:**
```bash
ssh root@192.168.100.1
iw reg get        # should show "country US:" not "country 00:"
uci get wireless.radio1.country    # should show your country code, not empty
```

**Cause #2 (much rarer): channel restricted under your country's DFS rules.**

Channel 36 works in nearly every country. Channels 52-144 (DFS) require radar avoidance. If you picked one of those manually and your country forbids it without certified DFS, the radio falls back silently. Stick to **Channel 36 or `auto`** for the AP. (5GHz client mode for Wi-Fi-as-WAN is fine on DFS channels — different rules.)

**Cause #3 (rare, model-specific): some older phones don't do WPA3 on 5GHz cleanly.**

If you used `WPA3-PSK` exclusively and your phone is pre-2020, drop to `WPA2-PSK/WPA3-PSK Mixed Mode` or pure `WPA2-PSK`.

---

## Phone hangs trying to join 2.4GHz AP (`radio0`) {#phone-hangs-2ghz}

Same symptom as above but on 2.4GHz. Country code matters less on 2.4GHz (channels 1-11 are universal), so `00` is less likely to be the immediate culprit. Different cause.

**Cause: AX (Wi-Fi 6) mode + WPA2-PSK on 2.4GHz, with some Android phones.**

Wi-Fi 6 on 2.4GHz is fragile in real-world driver/firmware combinations. The WPA2 handshake during association sometimes hangs because the spec increasingly expects WPA3 for AX-mode APs, and the 4-way handshake gets confused with TKIP/CCMP negotiation. Samsung Galaxy phones (S22 / S23 / S24 generation, certain firmware revisions) and some Pixel firmware are documented to exhibit this.

**Fix:**

1. Edit the radio0 SSID → **Device Configuration** tab → **Operating frequency**
2. Mode dropdown: change from `AX` → **`N`** (Wi-Fi 4)
3. Keep Width = `20 MHz`, Channel = `auto` or `6`
4. Save & Apply
5. Re-try phone.

If you also need to set the Country Code while you're there (see § Phone hangs trying to join 5GHz), do both at once.

**Why this works:** 802.11n + WPA2-PSK is the most universally tested combination in existence. Any phone made after ~2010 handshakes against it cleanly. You sacrifice some peak throughput (which 2.4GHz can't deliver anyway in a noisy band), and you get reliable connectivity.

If you don't want to lose AX on 2.4GHz, the alternative workaround is pure `WPA3-PSK` (not mixed) on 2.4GHz — but that locks out any device without WPA3 (most pre-2019 phones, many IoT). Drop-to-N is the safer fix.

---

## Phone refuses an SSID whose password / encryption you just changed {#phone-cached-credentials}

You changed the SSID's encryption (e.g., None → WPA2-PSK) or the password. Your phone scans the SSID, taps it, types the new password, and either rejects it ("incorrect password" — even though you typed it right) or hangs forever.

**Cause:** Phone has a cached profile for that SSID with the OLD encryption / password. When you tap the SSID, the OS reuses the cached profile and ignores what you just typed, then silently fails the handshake.

**Fix on the phone:** WiFi settings → tap-and-hold (Android) or tap the (i) (iOS) on the SSID → **Forget network** → re-scan → tap again → enter password fresh.

This is the **#1 cause** of "I just changed the WPA settings and now I can't connect." Always forget + re-add when you've changed encryption on the AP side.

---

## Wireless Overview shows "Encryption: None" but you set WPA2 {#encryption-none-after-save}

You went into the Wireless Security tab, picked WPA2-PSK, set a password, clicked **Save** — but the Wireless Overview still shows the SSID with `Encryption: None`. Phones connect without a password / hang on connect.

**Cause:** LuCI's wireless edit dialog has **two save buttons**:
- **Save** (inside the Edit modal) — *stages* the change in the candidate config
- **Save & Apply** (on the parent Wireless Overview page) — *commits and deploys* the candidate config to running config

Hitting only the inner Save dismisses the dialog but never applies the change. The Status box on the dialog itself is cached from when the page loaded, so re-opening the dialog shows your changes (because they're staged), but the live AP still runs the old open config.

**Fix:** after closing the Edit dialog, you should land back on Wireless Overview with a yellow banner saying "Unsaved Changes." Click **Save & Apply** there. Wait 5-10s for hostapd to restart. SSH check:

```bash
ssh root@192.168.100.1
uci show wireless | grep -E 'ssid|encryption|key'   # what's in the saved config
ps | grep hostapd                                    # hostapd process
logread | grep -iE 'hostapd|wlan' | tail -20         # recent association events
```

You want to see `encryption='psk2'` (or `'psk-mixed'`) and a `key='...'` line. If you see `encryption='none'`, the Save & Apply never went through.

---

## Which radio is which? I have `radio0` and `radio1` backwards {#radio-mapping-confused}

OpenWrt's `radio0` / `radio1` naming is **not standardized by band** — different drivers and devices assign them differently. The Beryl AX (MediaTek MT7981) current OMR build assigns them like this:

| LuCI label | Band | LuCI chipset string | Notes |
|---|---|---|---|
| **`radio0`** | **2.4 GHz** | `MediaTek MT7981 802.11ax/b/g/n`, Channel 1 (2.412 GHz) | Slower, longer range. Use for Wi-Fi-as-WAN client mode. |
| **`radio1`** | **5 GHz** | `MediaTek MT7981 802.11ac/ax/n`, Channel 36 (5.180 GHz) | Faster, shorter range. Primary client-facing AP. |

**Ground truth check:** the radio whose chipset string includes **`802.11ac`** is always 5GHz (802.11ac is a 5GHz-only spec). The other one is 2.4GHz. Don't trust memorized band/`radioN` pairings — verify from the chipset string in Network → Wireless.

If you see `2.412 GHz` in the Channel field, that's 2.4GHz. If you see `5.180 GHz` (or any `5.xxx`), that's 5GHz.

**Older versions of these docs had `radio0` and `radio1` swapped.** If a runbook step seems backwards relative to LuCI, trust LuCI (the chipset strings) and file an issue against the doc.

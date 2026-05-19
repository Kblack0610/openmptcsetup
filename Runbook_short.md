
● Here's the simple version — what you need to do, in order:

  Before you start (gather/prep)

  1. Confirm you have: NanoPi R6S, Beryl AX, S25 + USB-C cable, Starlink
   Mini, microSD card (32GB+, quality brand — Samsung EVO or SanDisk
  Extreme), USB-C PD power supply for the R6S
  2. Sign up for Vultr at https://my.vultr.com (have a credit card
  ready, ~$6/mo)

  Build day (~1 hour if nothing breaks)

  Step 1 — Spin up the VPS (~10 min)
  - Deploy a $6/mo Debian 12 instance in Los Angeles
  - SSH in, run the OMR server install script
  - Copy the Server IP + User Key it spits out
  - Open firewall ports

  Step 2 — Flash OpenWrt to the SD card (~10 min)
  - Download the R6S OpenWrt 24.10 image on your CachyOS box
  - Verify checksum
  - dd it to the microSD card
  - Insert into R6S, power on

  Step 3 — Smoke-test the R6S ⚠️ critical (~5 min)
  - SSH in at 192.168.1.1
  - Plug your S25 in, enable USB tethering
  - Check that usb0 appears with an IP
  - If USB doesn't work here, STOP — fallbacks documented in the runbook

  Step 4 — Install OMR packages (~5 min)
  - Add the OMR opkg feed
  - Install luci-app-openmptcprouter, glorytun, shadowsocks-libev-mptcp,
   etc.
  - Reboot

  Step 5 — Run the OMR wizard (~10 min)
  - Plug Starlink into one 2.5GbE port
  - LuCI → System → OpenMPTCProuter → Wizard
  - Paste Server IP + Key, pick Glorytun TCP + Shadowsocks, assign WANs
  - Set MPTCP scheduler to redundant
  - Save & Apply

  Step 6 — Wire up the Beryl AX (~5 min)
  - Set it to Access Point mode at 192.168.8.1
  - Cable from R6S LAN port → Beryl
  - Configure SSID/password

  Step 7 — Tailscale ByPass (~3 min)
  - LuCI → OpenMPTCProuter → ByPass
  - Add rules for UDP 41641, TCP 443, UDP 3478
  - Install Tailscale on OnePlus + Mac Studio if not done

  Step 8 — Test (~5 min)
  - Connect OnePlus to Beryl Wi-Fi
  - Try your VDI client
  - Add rules for UDP 41641, TCP 443, UDP 3478
  - Install Tailscale on OnePlus + Mac Studio if not done

  Step 8 — Test (~5 min)
  - Connect OnePlus to Beryl Wi-Fi
  - Try your VDI client
  Step 7 — Tailscale ByPass (~3 min)
  - LuCI → OpenMPTCProuter → ByPass
  - Add rules for UDP 41641, TCP 443, UDP 3478
  - Install Tailscale on OnePlus + Mac Studio if not done

  Step 8 — Test (~5 min)
  - Connect OnePlus to Beryl Wi-Fi
  - Try your VDI client
  - Test failover: unplug Starlink, confirm session survives

  ---
  The exact commands for each step are in ~/dev/openmptcsetup/RUNBOOK.md. I'd suggest opening that side-by-side when you start, and going one
  phase at a time. Each phase ends with a CHECKPOINT — don't proceed if a checkpoint fails, ping me instead.

  What I'd actually do first right now: nothing technical. Just confirm you have a decent microSD card on hand. If you don't, order one (Samsung
   EVO Select 64GB, ~$10 on Amazon, ships same-day Prime). The build is much smoother when you don't have to stop halfway to wait for hardware.

  Want me to walk through Step 1 (Vultr setup) live when you're ready, or are you good to start solo?



● Runbook restored at ~/dev/openmptcsetup/RUNBOOK.md. Pro tip: git add . && git commit before git push, and if you do mess up, git reflog can
  usually recover it from your local repo.

  ---
  On GigSky Cruise + Land — yes, but here's the nuance

  Can you add it as a third bonded WAN? Technically yes. Practically — it's better as a backup, not a bonded path.

  How you'd physically wire it

  The R6S has one USB-C port and one or two USB-A ports. GigSky is an eSIM, which means it needs a device with eSIM capability to actually
  activate. Your options:

  1. Put GigSky on a spare phone, USB-tether that into a second USB port on the R6S. It shows up as usb1 alongside your S25's usb0. OMR bonds it
   just like any other WAN.
  2. Use a dedicated 5G USB modem with eSIM support (Quectel RM520N-GL with an M.2-to-USB adapter). Cleaner but ~$200+ and more wiring.
  3. Use a GL.iNet Spitz AX or similar cellular puck that accepts eSIMs, ethernet it into the R6S.

  For a single trip, option 1 (spare phone with GigSky eSIM) is by far the easiest. Any old eSIM-capable Android phone (Pixel 4+, Galaxy S20+)
  works — could even be your OnePlus if it's not the active client.

  The Princess Alaska reality check

  This matters more than the hardware question.

  Princess Alaska routes (Vancouver → Whittier and reverse, Inside Passage, Glacier Bay) hit cellular coverage in port stops (Juneau, Skagway,
  Ketchikan, Sitka, Icy Strait Point) and occasionally glimpses near coastal towns. The rest of the time you're in open water or fjords with
  zero terrestrial cellular.

  What GigSky actually does at sea: it roams onto Cellular at Sea (CaS) — the maritime satellite-backhauled cellular network installed on most
  cruise ships. This is:
  - High latency (600-1500 ms RTT typical — satellite backhaul)
  - Slow (often capped at 2-5 Mbps per user)
  - Pricey — GigSky's at-sea data is significantly more expensive than land data on the same plan

  Bonding CaS with Starlink is a bad idea because:
  - The CaS path adds 500+ ms of latency to every packet that traverses it
  - With OMR's default scheduler, packets randomly take the slow path and your stream tanks
  - With redundant scheduler, you're sending every packet over CaS too — burning GigSky data at 2x the rate for no speed benefit
  - Starlink Mini's latency on a clear sky shot is ~30-50 ms. CaS is ~10x worse. They don't mix well.

  What does work well:
  - GigSky in port — when the ship docks in Juneau/Skagway/Ketchikan, GigSky drops onto AT&T/Verizon terrestrial Alaska networks. That's real
  cellular at land-like speeds. Worth having for shore excursions even if you don't bond it. You'd add it to the R6S only on port days.
  - GigSky as Starlink failover — omr-tracker can keep GigSky idle until Starlink dies, then switch over. Failover, not bonding. Configure
  GigSky as a backup-only WAN in OMR with priority lower than Starlink and the ship wifi.

  Recommended Princess Alaska config

  ┌─────────────────────────────────────┬─────────────────────┬───────────────────────────────────────────────────────────┐
  │                 WAN                 │        Role         │                        When active                        │
  ├─────────────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────────────┤
  │ Starlink Mini                       │ wan1, Master        │ Primary at sea, balcony cabin with sky view               │
  ├─────────────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────────────┤
  │ Princess MedallionNet (cruise wifi) │ wan2, MPTCP         │ Secondary — bonded with Starlink, redundancy via SS-MPTCP │
  ├─────────────────────────────────────┼─────────────────────┼───────────────────────────────────────────────────────────┤
  │ GigSky-equipped phone               │ wan3, failover only │ Activates if both above die, or in port for shore use     │
  └─────────────────────────────────────┴─────────────────────┴───────────────────────────────────────────────────────────┘

  This keeps your GigSky data consumption low (only used as backup), gives you redundancy across three very different failure modes, and avoids
  the latency disaster of bonding satellite-backhauled cellular.

  One more Princess-specific thing to verify

  Princess's MedallionNet uses Starlink Maritime as backhaul on most ships now. So you're potentially bonding "Starlink (your terminal)" +
  "Starlink (Princess's terminal)" — same underlying constellation. If one has a constellation-wide outage, both go down simultaneously.
  GigSky's CaS or terrestrial-in-port becomes legitimately useful as the only non-Starlink path on the boat.

  Princess's official policy on passenger-brought Starlink Mini terminals as of recent reports is "don't ask, don't tell" — they don't
  explicitly ban it like Royal Caribbean does, but they reserve the right to ask you to disable it. Balcony cabin = much easier to set up
  discreetly than interior. The Mini's small form factor helps.

  Want me to add the GigSky-as-failover-WAN config to the runbook as a Phase 9, or keep it as a separate "on the cruise" addendum?

✻ Brewed for 2m 3s

※ recap: You're building an OpenMPTCProuter rig (NanoPi R6S + Beryl AX + Vultr VPS) to bond Starlink with cellular/cruise wifi for VDI and
  Moonlight. Runbook is restored at ~/dev/openmptcsetup/RUNBOOK.md. Next: decide whether to add GigSky as a Phase 9 failover WAN or keep it
  separate. (disable recaps in /config)

❯ b

──────────────────────────────────────────────────────────────────────────────────────────────────────────── openmptcrouter-starlink-5g-setup ──
❯ 

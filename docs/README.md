# Documentation index

The docs are split by purpose: **how to build** (runbooks), **why things are the way they
are** (concepts), and **what to do when it breaks** (troubleshooting). Pick the one that
matches what you're trying to do.

## Where to start

| Goal | Read this |
|---|---|
| First-time build, at a desk with a fast connection | [`runbooks/beryl-ax.md`](runbooks/beryl-ax.md) |
| Build at a hotel before a trip, condensed field guide | [`runbooks/cruise-checklist.md`](runbooks/cruise-checklist.md) |
| Build on an Alaska cruise specifically | [`runbooks/cruise-checklist.md`](runbooks/cruise-checklist.md) (Part B) |
| Alternative R6S build (more capable, more complex) | [`runbooks/r6s.md`](runbooks/r6s.md) |
| Understand *why* you need a VPS at all | [`why-vps.md`](why-vps.md) |
| Compare VPS providers / regions | [`vps-options.md`](vps-options.md) |
| Understand a setting before you change it (scheduler, role, MacVLAN, etc.) | [`concepts.md`](concepts.md) |
| Diagnose a specific failure / red dashboard card | [`troubleshooting.md`](troubleshooting.md) |

## Map

```
docs/
├── README.md                ← you are here
├── concepts.md              ← MPTCP scheduler / role / MacVLAN / TCP-vs-UDP / topology
├── troubleshooting.md       ← symptom-indexed failure modes and fixes
├── why-vps.md               ← long-form architectural rationale
├── vps-options.md           ← provider comparison (DigitalOcean / Vultr / Linode / Hetzner / etc.)
└── runbooks/
    ├── beryl-ax.md          ← primary build (GL.iNet GL-MT3000, official OMR image)
    ├── cruise-checklist.md  ← condensed offline field guide for hotel + cruise
    └── r6s.md               ← alternative build (NanoPi R6S, vanilla OpenWrt + OMR feeds)
```

## Reading order for someone new

If you're starting from zero and want to understand before you start clicking, this order
works well:

1. [`why-vps.md`](why-vps.md) — what problem this whole setup solves
2. [`concepts.md`](concepts.md) — the mental models that the runbooks assume
3. [`runbooks/beryl-ax.md`](runbooks/beryl-ax.md) — actual step-by-step
4. [`troubleshooting.md`](troubleshooting.md) — keep this open in another tab while building

If you're building under time pressure (hotel before a cruise), skip straight to
[`runbooks/cruise-checklist.md`](runbooks/cruise-checklist.md). It's self-contained and
points back into the other docs only when you hit something unexpected.

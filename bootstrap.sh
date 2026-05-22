#!/usr/bin/env bash
# bootstrap.sh — local prep for the Beryl AX OMR build
# Downloads the official OMR firmware for GL-MT3000, verifies it,
# stages SSH keys, and prints next-step instructions.
#
# Usage: ./bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="${SCRIPT_DIR}/firmware"
OMR_RELEASE_BASE="https://releases.openmptcprouter.com"
SSH_KEY="${HOME}/.ssh/omr_vps"

# ──────────────────────────────────────────────────────────────
# Color helpers
# ──────────────────────────────────────────────────────────────
c_blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

step() { c_blue "=== $* ==="; }
ok()   { c_green "  ✓ $*"; }
warn() { c_yellow "  ! $*"; }
fail() { c_red "  ✗ $*"; exit 1; }

# ──────────────────────────────────────────────────────────────
# 1. Sanity check tools
# ──────────────────────────────────────────────────────────────
step "Checking required tools"
for tool in curl wget sha256sum gunzip ssh-keygen; do
  if ! command -v "$tool" &>/dev/null; then
    fail "$tool not found in PATH"
  fi
done
ok "curl, wget, sha256sum, gunzip, ssh-keygen all present"

# ──────────────────────────────────────────────────────────────
# 2. Discover latest OMR release directory
# ──────────────────────────────────────────────────────────────
step "Discovering latest OpenMPTCProuter release"
LATEST_DIR=$(curl -fsSL "${OMR_RELEASE_BASE}/" \
  | grep -oE 'href="v[0-9]+\.[0-9]+-[0-9.]+/"' \
  | sed -E 's/href="(.+)\/"/\1/' \
  | sort -V \
  | tail -1)

if [[ -z "${LATEST_DIR}" ]]; then
  fail "Could not parse latest release directory from ${OMR_RELEASE_BASE}/"
fi
ok "Latest release: ${LATEST_DIR}"

RELEASE_URL="${OMR_RELEASE_BASE}/${LATEST_DIR}"

# ──────────────────────────────────────────────────────────────
# 3. Find the Beryl AX (GL-MT3000) sysupgrade image
# ──────────────────────────────────────────────────────────────
# OMR's release layout for GL.iNet devices is:
#   /v{VER}/gl-mt3000/targets/mediatek/filogic/openmptcprouter-*-glinet_gl-mt3000-squashfs-sysupgrade.bin
step "Locating GL-MT3000 (Beryl AX) sysupgrade image"
TARGET_URL="${RELEASE_URL}/gl-mt3000/targets/mediatek/filogic"
LISTING=$(curl -fsSL "${TARGET_URL}/" || true)

if [[ -z "${LISTING}" ]]; then
  fail "Could not fetch ${TARGET_URL}/ — check your internet or OMR release dir"
fi

# grep returning no match is OK; capture in a way that doesn't kill -e/pipefail
IMAGE_NAME=$(printf '%s' "${LISTING}" \
  | grep -oE 'openmptcprouter-[^"]*glinet_gl-mt3000-squashfs-sysupgrade\.bin' \
  | head -1 || true)

if [[ -z "${IMAGE_NAME}" ]]; then
  c_red "Could not find a sysupgrade image at ${TARGET_URL}/"
  c_red "Files available:"
  printf '%s' "${LISTING}" | grep -oE 'href="[^"]*\.bin"' | sed -E 's/href="(.+)"/  \1/' | sort -u >&2 || true
  fail "Open ${TARGET_URL}/ in a browser to check the layout"
fi
ok "Found image: ${IMAGE_NAME}"

# ──────────────────────────────────────────────────────────────
# 4. Download image + per-file checksum
# ──────────────────────────────────────────────────────────────
step "Downloading firmware to ${FIRMWARE_DIR}"
mkdir -p "${FIRMWARE_DIR}"
cd "${FIRMWARE_DIR}"

if [[ -f "${IMAGE_NAME}" ]]; then
  warn "Image already downloaded, skipping"
else
  wget -q --show-progress "${TARGET_URL}/${IMAGE_NAME}"
  ok "Downloaded ${IMAGE_NAME}"
fi

# OMR ships a per-file .sha256sum (not a combined sha256sums file)
CHECKSUM_FILE="${IMAGE_NAME}.sha256sum"
if [[ ! -f "${CHECKSUM_FILE}" ]]; then
  wget -q "${TARGET_URL}/${CHECKSUM_FILE}" || warn "No .sha256sum companion file — skipping verification"
fi

if [[ -f "${CHECKSUM_FILE}" ]]; then
  step "Verifying SHA256"
  if sha256sum -c "${CHECKSUM_FILE}"; then
    ok "Checksum verified"
  else
    fail "Checksum verification FAILED — do not flash this image"
  fi
else
  warn "Skipped checksum verification"
fi

# ──────────────────────────────────────────────────────────────
# 5. SSH keypair for the VPS
# ──────────────────────────────────────────────────────────────
step "SSH keypair for VPS access"
if [[ -f "${SSH_KEY}" ]]; then
  ok "Existing key at ${SSH_KEY}"
else
  ssh-keygen -t ed25519 -f "${SSH_KEY}" -C "omr-vps" -N ""
  ok "Generated ${SSH_KEY}"
fi

# ──────────────────────────────────────────────────────────────
# 6. Show next steps
# ──────────────────────────────────────────────────────────────
cat <<EOF

$(c_green '════════════════════════════════════════════════════════════')
$(c_green '  Bootstrap complete')
$(c_green '════════════════════════════════════════════════════════════')

Firmware ready at:
  ${FIRMWARE_DIR}/${IMAGE_NAME}

SSH public key (already on disk; vps-create-do.sh will upload it for you):
  $(cat "${SSH_KEY}.pub")

────────────────────────────────────────────────────────────
Next steps:
────────────────────────────────────────────────────────────

1. Create the VPS on DigitalOcean (uses your existing doctl auth):
   ./vps-create-do.sh

   This creates a \$6/mo droplet in SFO3 and auto-chains into
   ./vps-install.sh to install the OMR server.

   Alternative: deploy manually via the DO or Vultr web console,
   then: echo "VPS_IP=<ip>" > ${SCRIPT_DIR}/.env && ./vps-install.sh

2. Flash the Beryl AX:
   • Connect to its default Wi-Fi or LAN port
   • Browse to http://192.168.8.1, complete first-run
   • System → Upgrade → Local Upgrade
   • Upload ${IMAGE_NAME}
   • ⚠ UNCHECK "Keep settings"
   • Wait 3-5 min for reboot

3. Configure OMR via wizard (see RUNBOOK-BerylAX.md Phase 4 onward):
   http://192.168.100.1  (root / set a password)

EOF

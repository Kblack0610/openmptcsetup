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
step "Locating GL-MT3000 (Beryl AX) sysupgrade image"
LISTING=$(curl -fsSL "${RELEASE_URL}/")

IMAGE_NAME=$(echo "${LISTING}" \
  | grep -oE 'href="[^"]*glinet[_-]gl-mt3000[^"]*sysupgrade[^"]*"' \
  | sed -E 's/href="([^"]+)"/\1/' \
  | head -1)

if [[ -z "${IMAGE_NAME}" ]]; then
  # Try alternate naming (some OMR releases use "mt3000" without "gl-")
  IMAGE_NAME=$(echo "${LISTING}" \
    | grep -oE 'href="[^"]*mt3000[^"]*sysupgrade[^"]*"' \
    | sed -E 's/href="([^"]+)"/\1/' \
    | head -1)
fi

if [[ -z "${IMAGE_NAME}" ]]; then
  c_red "Could not auto-find an MT3000 sysupgrade image in ${RELEASE_URL}/"
  c_red "Available files matching 'mt3000' or 'glinet':"
  echo "${LISTING}" | grep -oE 'href="[^"]*(mt3000|glinet)[^"]*"' | sed -E 's/href="([^"]+)"/  \1/' | sort -u >&2
  fail "Manual download required — see ${RELEASE_URL}/"
fi
ok "Found image: ${IMAGE_NAME}"

# ──────────────────────────────────────────────────────────────
# 4. Download image + checksums
# ──────────────────────────────────────────────────────────────
step "Downloading firmware to ${FIRMWARE_DIR}"
mkdir -p "${FIRMWARE_DIR}"
cd "${FIRMWARE_DIR}"

if [[ -f "${IMAGE_NAME}" ]]; then
  warn "Image already downloaded, skipping"
else
  wget -q --show-progress "${RELEASE_URL}/${IMAGE_NAME}"
  ok "Downloaded ${IMAGE_NAME}"
fi

# Find the checksum file (varies: sha256sums, SHA256SUMS, etc.)
CHECKSUM_FILE=$(echo "${LISTING}" \
  | grep -oE 'href="(sha256sums?|SHA256SUMS)"' \
  | sed -E 's/href="([^"]+)"/\1/' \
  | head -1)

if [[ -n "${CHECKSUM_FILE}" ]]; then
  if [[ ! -f "${CHECKSUM_FILE}" ]]; then
    wget -q "${RELEASE_URL}/${CHECKSUM_FILE}"
  fi
  step "Verifying SHA256"
  if grep -F "${IMAGE_NAME}" "${CHECKSUM_FILE}" | sha256sum -c -; then
    ok "Checksum verified"
  else
    fail "Checksum verification FAILED — do not flash this image"
  fi
else
  warn "No checksum file found at ${RELEASE_URL}/ — proceed at your own risk"
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

SSH public key (paste into Vultr when deploying the VPS):
  $(cat "${SSH_KEY}.pub")

────────────────────────────────────────────────────────────
Next steps:
────────────────────────────────────────────────────────────

1. Provision a VPS at Vultr (or alternative — see VPS-options.md):
   https://my.vultr.com → Deploy New Server
   • Cloud Compute, Los Angeles, Debian 12, \$6/mo plan
   • Paste the SSH public key above

2. Save the VPS IP:
   echo "VPS_IP=<paste-here>" > ${SCRIPT_DIR}/.env

3. Run the VPS bootstrap (installs OMR server):
   ./vps-install.sh

4. Flash the Beryl AX:
   • Connect to its default Wi-Fi or LAN port
   • Browse to http://192.168.8.1, complete first-run
   • System → Upgrade → Local Upgrade
   • Upload ${IMAGE_NAME}
   • ⚠ UNCHECK "Keep settings"
   • Wait 3-5 min for reboot

5. Configure OMR via wizard (see RUNBOOK-BerylAX.md Phase 4 onward):
   http://192.168.100.1  (root / set a password)

EOF

#!/usr/bin/env bash
# vps-install.sh — installs OpenMPTCProuter server on a fresh Debian 12 VPS.
#
# Prerequisites:
#   1. VPS provisioned (Debian 12 x64) with your SSH key authorized
#   2. ./bootstrap.sh has been run (generates ~/.ssh/omr_vps)
#   3. .env file exists with VPS_IP=...
#
# Usage: ./vps-install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${HOME}/.ssh/omr_vps"
ENV_FILE="${SCRIPT_DIR}/.env"

c_blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
step() { c_blue "=== $* ==="; }
ok()   { c_green "  ✓ $*"; }
warn() { c_yellow "  ! $*"; }
fail() { c_red "  ✗ $*"; exit 1; }

# ──────────────────────────────────────────────────────────────
# Load VPS_IP
# ──────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Missing ${ENV_FILE} — create it with: echo 'VPS_IP=<your-vps-ip>' > ${ENV_FILE}"
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"
if [[ -z "${VPS_IP:-}" ]]; then
  fail "VPS_IP not set in ${ENV_FILE}"
fi
ok "VPS_IP=${VPS_IP}"

# ──────────────────────────────────────────────────────────────
# Confirm SSH access works (initial port 22, OMR moves it to 65222)
# ──────────────────────────────────────────────────────────────
step "Verifying initial SSH access (port 22)"
if ssh -i "${SSH_KEY}" -p 22 -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
     "root@${VPS_IP}" "true" 2>/dev/null; then
  ok "SSH (port 22) reachable"
  SSH_PORT=22
elif ssh -i "${SSH_KEY}" -p 65222 -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "root@${VPS_IP}" "true" 2>/dev/null; then
  warn "Port 22 closed but 65222 open — OMR may already be installed"
  SSH_PORT=65222
  read -rp "Continue anyway and re-run install? [y/N] " yn
  [[ "${yn,,}" == "y" ]] || exit 0
else
  fail "Cannot SSH to ${VPS_IP} on either port 22 or 65222"
fi

# ──────────────────────────────────────────────────────────────
# Push the install script to the VPS and run it
# ──────────────────────────────────────────────────────────────
step "Upgrading base system + running OMR server install"
warn "This will take 5-10 minutes and reboot the VPS at the end."
warn "SSH will move from port 22 to port 65222 after install."
read -rp "Proceed? [y/N] " yn
[[ "${yn,,}" == "y" ]] || { warn "Aborted"; exit 0; }

REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[VPS] Updating base packages..."
apt-get update -qq
apt-get -y -qq upgrade

echo "[VPS] Running OMR server installer..."
# Workaround for known iperf3/openvpn fetch bugs on Debian 12 (#4171)
wget -qO - https://www.openmptcprouter.com/server/debian-x86_64.sh \
  | IPERF="no" OPENVPN="no" KERNEL="6.12" sh

echo "[VPS] OMR install complete — system will reboot."
REMOTE
)

ssh -i "${SSH_KEY}" -p "${SSH_PORT}" "root@${VPS_IP}" "${REMOTE_SCRIPT}" || true

step "Waiting for VPS to reboot (90s)"
sleep 90

# ──────────────────────────────────────────────────────────────
# Connect on new port (65222) and grab credentials
# ──────────────────────────────────────────────────────────────
step "Reconnecting on port 65222 to fetch credentials"
for i in 1 2 3 4 5 6; do
  if ssh -i "${SSH_KEY}" -p 65222 -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "root@${VPS_IP}" "true" 2>/dev/null; then
    ok "Connected on port 65222"
    break
  fi
  warn "Attempt $i failed, waiting 15s..."
  sleep 15
  if [[ "$i" == "6" ]]; then
    fail "VPS did not come back on port 65222 — check the Vultr console"
  fi
done

step "Fetching OMR credentials"
CREDS_FILE="${SCRIPT_DIR}/vps-credentials.txt"
ssh -i "${SSH_KEY}" -p 65222 "root@${VPS_IP}" \
  "cat /root/openmptcprouter_config.txt" > "${CREDS_FILE}"
chmod 600 "${CREDS_FILE}"
ok "Credentials saved to ${CREDS_FILE}"

# ──────────────────────────────────────────────────────────────
# Configure ufw firewall
# ──────────────────────────────────────────────────────────────
step "Opening firewall ports"
ssh -i "${SSH_KEY}" -p 65222 "root@${VPS_IP}" bash <<'REMOTE'
set -e
ufw allow 65222/tcp comment 'SSH'
ufw allow 65001/tcp comment 'Glorytun TCP'
ufw allow 65001/udp comment 'Glorytun UDP'
ufw allow 65101/tcp comment 'Shadowsocks'
ufw allow 65500/tcp comment 'OMR admin'
ufw allow 65400/tcp comment 'iperf3'
ufw --force enable
REMOTE
ok "Firewall configured"

# ──────────────────────────────────────────────────────────────
# Sanity test
# ──────────────────────────────────────────────────────────────
step "Sanity-testing tunnel endpoint reachability from your laptop"
for port in 65222 65500; do
  if nc -zv -w 3 "${VPS_IP}" "${port}" 2>&1 | grep -q 'succeeded\|open'; then
    ok "TCP/${port} reachable"
  else
    warn "TCP/${port} not reachable — check Vultr's external firewall console"
  fi
done

if nc -uzv -w 3 "${VPS_IP}" 65001 2>&1 | grep -q 'succeeded\|open'; then
  ok "UDP/65001 (Glorytun) reachable"
else
  warn "UDP/65001 may not be reachable — UDP nc tests are unreliable, verify after flashing Beryl"
fi

cat <<EOF

$(c_green '════════════════════════════════════════════════════════════')
$(c_green '  VPS install complete')
$(c_green '════════════════════════════════════════════════════════════')

Credentials saved to:
  ${CREDS_FILE}

Server IP and User key (paste these into the OMR wizard on the Beryl AX):

$(grep -E 'IP|key|Key' "${CREDS_FILE}" | head -20)

Next: flash the Beryl AX with the firmware in ./firmware/, then follow
RUNBOOK-BerylAX.md Phase 3 onward.

EOF

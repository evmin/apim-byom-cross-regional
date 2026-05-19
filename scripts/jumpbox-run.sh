#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox-run.sh — DJ-014 — non-interactive remote exec via Bastion.
# =============================================================================
# Opens an `az network bastion tunnel` to the jumpbox, ssh's into it on
# localhost:<random-port>, runs the supplied shell command(s), tears down the
# tunnel via an EXIT trap.
#
# Usage:
#   scripts/jumpbox-run.sh "/opt/mreg-validate/smoke-dns.sh"
#   scripts/jumpbox-run.sh "/opt/mreg-validate/smoke-bridge.sh"
#
# Env:
#   JUMPBOX_SSH_PRIVATE_KEY=~/.ssh/mreg-jumpbox
#   JUMPBOX_ADMIN_USERNAME=azureuser
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "usage: $0 \"<remote-command>\"" >&2
  exit 2
fi

REMOTE_CMD="$*"
KEY="${JUMPBOX_SSH_PRIVATE_KEY:-${HOME}/.ssh/mreg-jumpbox}"
USER="${JUMPBOX_ADMIN_USERNAME:-azureuser}"

ENV_VALUES=$(azd env get-values)
get() { echo "${ENV_VALUES}" | awk -F= -v k="$1" '$1==k {gsub(/^"|"$/,"",$2); print $2}'; }

BASTION_NAME=$(get jumpboxBastionName)
BASTION_RG=$(get jumpboxBastionResourceGroup)
VM_ID=$(get jumpboxVmId)

if [[ -z "${BASTION_NAME}" || -z "${BASTION_RG}" || -z "${VM_ID}" ]]; then
  echo "jumpbox-run: jumpbox outputs missing — has \`azd up\` run?" >&2
  exit 2
fi
if [[ ! -f "${KEY}" ]]; then
  echo "jumpbox-run: SSH private key not found at ${KEY}" >&2
  exit 2
fi

# Pick a random local port in the ephemeral range (avoids collisions on hosts
# that already have local listeners; az network bastion tunnel binds to it).
LOCAL_PORT=$(( RANDOM % 10000 + 50000 ))

LOG=$(mktemp -t jumpbox-tunnel.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
  if [[ -n "${TUNNEL_PID:-}" ]] && kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi
  rm -f "${LOG}"
}

echo "jumpbox-run: opening Bastion tunnel on localhost:${LOCAL_PORT} -> 22"
az network bastion tunnel \
  --name "${BASTION_NAME}" \
  --resource-group "${BASTION_RG}" \
  --target-resource-id "${VM_ID}" \
  --resource-port 22 \
  --port "${LOCAL_PORT}" >"${LOG}" 2>&1 &
TUNNEL_PID=$!

# Wait for the tunnel to be ready (poll the port).
for _ in $(seq 1 60); do
  if (echo > "/dev/tcp/127.0.0.1/${LOCAL_PORT}") >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! (echo > "/dev/tcp/127.0.0.1/${LOCAL_PORT}") >/dev/null 2>&1; then
  echo "jumpbox-run: tunnel did not come up within 60s" >&2
  echo "--- tunnel log ---" >&2
  tail -40 "${LOG}" >&2 || true
  exit 1
fi

echo "jumpbox-run: ssh -> ${USER}@127.0.0.1:${LOCAL_PORT}"
ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p "${LOCAL_PORT}" \
  -i "${KEY}" \
  "${USER}@127.0.0.1" \
  "source /etc/profile.d/mreg-validate.sh 2>/dev/null; ${REMOTE_CMD}"

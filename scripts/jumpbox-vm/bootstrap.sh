#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox-vm/bootstrap.sh — DJ-008 — idempotent tool install.
# =============================================================================
# Runs on first boot via cloud-init AND can be re-run by the operator if a
# package install step lost a race. Drops a marker at
# /var/lib/mreg-validate/bootstrap.done when finished.
#
# Tools installed:
#   - azure-cli (apt repo + pip-installable Azure SDKs via system python)
#   - python3-venv + dnsutils + jq + curl
#   - python virtualenv at /opt/mreg-validate/venv with
#       azure-ai-projects, azure-identity, openai, httpx
#
# Intended target: Ubuntu 22.04 LTS jammy on the demo jumpbox.
# =============================================================================

set -euo pipefail

MARKER_DIR=/var/lib/mreg-validate
MARKER=${MARKER_DIR}/bootstrap.done
APP_DIR=/opt/mreg-validate
VENV_DIR=${APP_DIR}/venv

# Run as root via cloud-init; if invoked manually, re-exec with sudo.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

mkdir -p "${MARKER_DIR}"
mkdir -p "${APP_DIR}"

if [[ -f "${MARKER}" ]]; then
  echo "bootstrap: marker present at ${MARKER} — re-running anyway for idempotency"
fi

export DEBIAN_FRONTEND=noninteractive

echo "bootstrap: apt update + install base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release \
  dnsutils jq \
  python3 python3-pip python3-venv

# --- Azure CLI (Microsoft apt repository) -----------------------------------
if ! command -v az >/dev/null 2>&1; then
  echo "bootstrap: installing azure-cli from Microsoft apt repo"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  AZ_REPO=$(lsb_release -cs)
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${AZ_REPO} main" \
    > /etc/apt/sources.list.d/azure-cli.list
  apt-get update -y
  apt-get install -y --no-install-recommends azure-cli
fi

az version 2>&1 | head -5

# --- Python venv with Azure AI SDKs -----------------------------------------
if [[ ! -d "${VENV_DIR}" ]]; then
  echo "bootstrap: creating virtualenv at ${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
fi

# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet \
  azure-ai-projects \
  azure-identity \
  openai \
  httpx
deactivate

# Make the venv discoverable to non-root users on the box.
chown -R root:root "${APP_DIR}"
chmod -R a+rX "${APP_DIR}"

# --- Marker -----------------------------------------------------------------
date -u +%Y-%m-%dT%H:%M:%SZ > "${MARKER}"
echo "bootstrap: complete — marker written to ${MARKER}"

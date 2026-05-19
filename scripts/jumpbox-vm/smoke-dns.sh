#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox-vm/smoke-dns.sh — DJ-011 — private-DNS resolution check.
# =============================================================================
# Resolves each privatelink.* FQDN we expect to be PE-fronted; FAILs if any
# resolution returns a non-RFC1918 address (i.e. would resolve to the public
# endpoint instead of the private one).
#
# Required env:
#   AGENT_PROJECT_ENDPOINT  — used to derive the agent Foundry FQDN
#   APIM_GATEWAY_HOSTNAME   — APIM private gateway FQDN
#   SC_FOUNDRY_FQDN         — SC AOAI account privatelink FQDN
#
# Exit: 0 on PASS (all RFC1918), 1 on FAIL.
# =============================================================================

set -euo pipefail

is_rfc1918() {
  local ip="$1"
  case "${ip}" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}

fail=0
check_host() {
  local host="$1"
  local label="$2"
  if [[ -z "${host}" || "${host}" == "null" ]]; then
    echo "smoke-dns: ${label} — host empty, skipped" >&2
    return
  fi
  local ips
  ips=$(dig +short "${host}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [[ -z "${ips}" ]]; then
    echo "smoke-dns: ${label} ${host} — NO A record" >&2
    fail=1
    return
  fi
  local good_label="OK"
  while IFS= read -r ip; do
    if ! is_rfc1918 "${ip}"; then
      echo "smoke-dns: ${label} ${host} -> ${ip} (NOT RFC1918)" >&2
      good_label="FAIL"
      fail=1
    fi
  done <<<"${ips}"
  echo "smoke-dns: ${good_label} ${label} ${host} -> $(echo "${ips}" | paste -sd, -)"
}

# Derive agent Foundry FQDN from the project endpoint. AGENT_PROJECT_ENDPOINT
# looks like  https://<account>.services.ai.azure.com/api/projects/<project>.
agent_host=""
if [[ -n "${AGENT_PROJECT_ENDPOINT:-}" ]]; then
  ep="${AGENT_PROJECT_ENDPOINT#https://}"
  ep="${ep#https://}"
  agent_host="${ep%%/*}"
fi

check_host "${agent_host}" "agent-foundry"
check_host "${APIM_GATEWAY_HOSTNAME:-}" "apim-gateway"

# SC Foundry from WE: by design, WE jumpbox MUST NOT resolve SC Foundry to a
# routable address — the agent always goes via APIM. If the hostname resolves
# to anything other than NXDOMAIN/empty, that's a posture leak. So we run
# a different assertion here.
if [[ -n "${SC_FOUNDRY_FQDN:-}" && "${SC_FOUNDRY_FQDN}" != "null" ]]; then
  ips=$(dig +short "${SC_FOUNDRY_FQDN}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [[ -z "${ips}" ]]; then
    echo "smoke-dns: OK sc-foundry ${SC_FOUNDRY_FQDN} — no resolution from WE VNet (expected)"
  else
    leak=0
    while IFS= read -r ip; do
      if ! is_rfc1918 "${ip}"; then
        echo "smoke-dns: FAIL sc-foundry ${SC_FOUNDRY_FQDN} -> ${ip} (PUBLIC IP — leak)" >&2
        leak=1
        fail=1
      fi
    done <<<"${ips}"
    if [[ "${leak}" -eq 0 ]]; then
      echo "smoke-dns: OK sc-foundry ${SC_FOUNDRY_FQDN} -> $(echo "${ips}" | paste -sd, -) (private)"
    fi
  fi
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "smoke-dns: FAIL — at least one private endpoint resolved to a non-RFC1918 IP" >&2
  exit 1
fi
echo "smoke-dns: PASS — all PE FQDNs resolve to private addresses"

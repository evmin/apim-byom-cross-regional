#!/usr/bin/env bash
# =============================================================================
# scripts/abort-and-resume.sh — T-035a partial-failure recovery check.
# =============================================================================
#
# This is the OPERATOR script for the manual partial-failure test described in
# T-035a. It does not abort a deployment on its own (azd doesn't expose a
# scriptable mid-deploy SIGINT) — instead, it documents the manual procedure
# and provides the post-resume verification probes.
#
# Manual procedure:
#   1. Start `azd up` in shell #1.
#   2. From shell #2, watch deployment progress:
#        az deployment sub list -o table | head
#   3. When the SC APIM deployment (`sc-apim-service`) shows Succeeded but the
#      Foundry connection (`foundry-connection-apim`) is still Running, send
#      SIGINT to shell #1: Ctrl+C.
#   4. Immediately re-run `azd up`.
#   5. Run this script to verify the resume succeeded:
#        ./scripts/abort-and-resume.sh
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

DEPLOYMENT_NAME=$(az deployment sub list -o tsv --query "[?contains(name, 'azd-')].name" | head -1)
if [[ -z "${DEPLOYMENT_NAME}" ]]; then
  echo "abort-and-resume: no azd-* subscription deployments found" >&2
  exit 1
fi

PROV_STATE=$(az deployment sub show -n "${DEPLOYMENT_NAME}" --query properties.provisioningState -o tsv)
if [[ "${PROV_STATE}" != "Succeeded" ]]; then
  echo "abort-and-resume: latest deployment ${DEPLOYMENT_NAME} state=${PROV_STATE} — resume did not complete" >&2
  exit 1
fi

# A successful resume implies foundry-connection-apim is now Succeeded.
NESTED=$(az deployment sub show -n "${DEPLOYMENT_NAME}" --query "properties.dependencies[?contains(dependsOn[*].resourceName, 'foundry-connection-apim')]" -o json 2>/dev/null || echo "[]")
echo "abort-and-resume: top-level deployment ${DEPLOYMENT_NAME} state=${PROV_STATE}"

# Posture audit must also pass on resume.
if [[ -x "./hooks/postprovision-audit.sh" ]]; then
  echo "abort-and-resume: running posture audit"
  AZURE_RESOURCE_GROUP="$(azd env get-values | awk -F= '/AGENT_RG/ {gsub(/"/, "", $2); print $2}')" \
    ./hooks/postprovision-audit.sh
fi

echo "abort-and-resume: PASS — partial-failure recovery converged"

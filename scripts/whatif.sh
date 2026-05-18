#!/usr/bin/env bash
# =============================================================================
# scripts/whatif.sh — T-034 what-if verification.
# =============================================================================
#
# Wraps `azd provision --preview` and (optionally) `az deployment sub what-if`
# so operators can inspect the resource churn before committing to `azd up`.
# Captures the what-if JSON for review under `.build/whatif-<env>.json`.
#
# Acceptance (per tasks.md T-034): output lists ~30–40 resource creates across
# the two RGs, zero deletes, zero "ignored"/"unsupported" resources.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p .build

ENV_NAME=$(azd env get-values | awk -F= '/AZURE_ENV_NAME/ {gsub(/"/, "", $2); print $2}')
if [[ -z "${ENV_NAME}" ]]; then
  echo "whatif: no azd environment selected; run 'azd env new <name>' first" >&2
  exit 1
fi

# Export every azd env var into the current shell so readEnvironmentVariable()
# inside infra/main.bicepparam resolves when we call `az deployment sub what-if`
# directly (azd does this internally for its own invocations).
set -a
# shellcheck disable=SC1090
source <(azd env get-values | sed 's/^/export /')
set +a

OUT_FILE=".build/whatif-${ENV_NAME}.json"

echo "whatif: azd provision --preview (env=${ENV_NAME})"
azd provision --preview --output json > "${OUT_FILE}.azd.json"
echo "whatif: wrote ${OUT_FILE}.azd.json"

# Also run a raw az what-if so we can grep on the resource churn breakdown.
LOCATION="${AZURE_LOCATION:-westeurope}"

echo "whatif: az deployment sub what-if (location=${LOCATION})"
az deployment sub what-if \
  --location "${LOCATION}" \
  --name "whatif-${ENV_NAME}" \
  --parameters infra/main.bicepparam \
  --result-format FullResourcePayloads \
  --no-pretty-print \
  > "${OUT_FILE}"

CREATE_COUNT=$(jq -r '[.changes[]? | select(.changeType == "Create")] | length' "${OUT_FILE}")
DELETE_COUNT=$(jq -r '[.changes[]? | select(.changeType == "Delete")] | length' "${OUT_FILE}")
MODIFY_COUNT=$(jq -r '[.changes[]? | select(.changeType == "Modify")] | length' "${OUT_FILE}")
IGNORE_COUNT=$(jq -r '[.changes[]? | select(.changeType == "Ignore" or .changeType == "Unsupported")] | length' "${OUT_FILE}")

echo "whatif: create=${CREATE_COUNT} modify=${MODIFY_COUNT} delete=${DELETE_COUNT} ignored=${IGNORE_COUNT}"

if [[ "${DELETE_COUNT}" -gt 0 ]]; then
  echo "whatif: FAIL — expected zero Deletes on a fresh provision" >&2
  jq -r '.changes[] | select(.changeType == "Delete") | .resourceId' "${OUT_FILE}" >&2
  exit 1
fi

if [[ "${IGNORE_COUNT}" -gt 0 ]]; then
  echo "whatif: WARN — ${IGNORE_COUNT} resource(s) ignored/unsupported" >&2
  jq -r '.changes[] | select(.changeType == "Ignore" or .changeType == "Unsupported") | "\(.changeType)\t\(.resourceId)"' "${OUT_FILE}" >&2
fi

if [[ "${CREATE_COUNT}" -lt 25 ]]; then
  echo "whatif: WARN — only ${CREATE_COUNT} resource creates (expected 30–40)" >&2
fi

echo "whatif: review ${OUT_FILE}"

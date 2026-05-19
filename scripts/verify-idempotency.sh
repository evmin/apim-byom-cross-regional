#!/usr/bin/env bash
# =============================================================================
# scripts/verify-idempotency.sh — idempotency check.
# =============================================================================
#
# Pre-condition: `azd up` already ran to completion. This script re-runs
# `azd provision --preview` and asserts that no resource shows a non-NoChange
# changeType (every resource must already be converged).
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p .build
OUT_FILE=".build/idempotency.json"

# Export azd env vars so readEnvironmentVariable() in main.bicepparam resolves.
set -a
# shellcheck disable=SC1090
source <(azd env get-values | sed 's/^/export /')
set +a

LOCATION="${AZURE_LOCATION:-westeurope}"

az deployment sub what-if \
  --location "${LOCATION}" \
  --name "idempotency-$(date +%s)" \
  --parameters infra/main.bicepparam \
  --result-format ResourceIdOnly \
  --no-pretty-print \
  > "${OUT_FILE}"

NON_NOCHANGE=$(jq -r '[.changes[]? | select(.changeType != "NoChange" and .changeType != "Ignore")] | length' "${OUT_FILE}")
if [[ "${NON_NOCHANGE}" -gt 0 ]]; then
  echo "verify-idempotency: FAIL — ${NON_NOCHANGE} resource(s) would change on re-run" >&2
  jq -r '.changes[] | select(.changeType != "NoChange" and .changeType != "Ignore") | "\(.changeType)\t\(.resourceId)"' "${OUT_FILE}" >&2
  exit 1
fi

echo "verify-idempotency: PASS — every resource reports NoChange"

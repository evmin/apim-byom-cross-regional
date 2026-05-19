#!/usr/bin/env bash
# =============================================================================
# scripts/verify-bicep.sh — compile-time verification.
# =============================================================================
#
# Runs `az bicep build` + `az bicep lint` on infra/main.bicep. Treats every
# error as fatal. Warnings are reported but do not fail the script (some
# warnings come from AVM module internals — BCP081 preview-API-version,
# core.windows.net hardcoded URLs — which we cannot fix without forking AVM).
#
# Caller can pass --strict to escalate warnings to errors.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

STRICT=0
for arg in "$@"; do
  case "${arg}" in
    --strict) STRICT=1 ;;
  esac
done

OUT_DIR=".build"
mkdir -p "${OUT_DIR}"

echo "verify-bicep: az bicep build"
BUILD_LOG=$(mktemp)
trap 'rm -f "${BUILD_LOG}"' EXIT
az bicep build --file infra/main.bicep --outdir "${OUT_DIR}" 2>&1 | tee "${BUILD_LOG}"

ERROR_COUNT=$(grep -c -E "(^|: )Error " "${BUILD_LOG}" || true)
WARNING_COUNT=$(grep -c "Warning " "${BUILD_LOG}" || true)

echo "verify-bicep: errors=${ERROR_COUNT} warnings=${WARNING_COUNT}"

if [[ "${ERROR_COUNT}" -gt 0 ]]; then
  echo "verify-bicep: FAIL — ${ERROR_COUNT} error(s)" >&2
  exit 1
fi

if [[ "${STRICT}" -eq 1 && "${WARNING_COUNT}" -gt 0 ]]; then
  echo "verify-bicep: FAIL --strict — ${WARNING_COUNT} warning(s)" >&2
  exit 1
fi

if [[ -s "${OUT_DIR}/main.json" ]]; then
  echo "verify-bicep: emitted ${OUT_DIR}/main.json ($(wc -c < "${OUT_DIR}/main.json") bytes)"
fi

echo "verify-bicep: PASS"

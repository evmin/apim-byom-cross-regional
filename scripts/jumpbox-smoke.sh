#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox-smoke.sh — runs the full validation suite on the
# jumpbox via Bastion-tunnel and prints a PASS/FAIL summary.
# =============================================================================
# Each sub-check is run remotely via scripts/jumpbox-run.sh, capturing exit
# code + tailing the last few lines of output for the summary. The script
# itself returns non-zero iff any *required* sub-check fails.
#
# Sub-checks (in order):
#   1. bootstrap-status        — confirms cloud-init bootstrap.sh ran.
#   2. smoke-dns               — every privatelink.* resolves to RFC1918.
#   3. smoke-reject            — APIM rejects a wrong-audience token (401/403).
#   4. smoke-bridge            — spec-aligned BYOM cross-region path:
#                                 jumpbox UAMI → APIM PE → SC AOAI → reply.
#                                 THIS IS THE PRIMARY DEMO PATH.
#   5. posture-from-vnet       — every solution data-plane has Disabled public access.
#
# Wall-time guard: 10 minutes total.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

RUN="${0%/*}/jumpbox-run.sh"
if [[ ! -x "${RUN}" ]]; then
  echo "jumpbox-smoke: scripts/jumpbox-run.sh missing or not executable" >&2
  exit 2
fi

declare -a NAMES=(
  bootstrap-status
  smoke-dns
  smoke-reject
  smoke-bridge
  posture-from-vnet
)
declare -a CMDS=(
  "test -f /var/lib/mreg-validate/bootstrap.done && cat /var/lib/mreg-validate/bootstrap.done"
  "/opt/mreg-validate/smoke-dns.sh"
  "/opt/mreg-validate/smoke-reject.sh"
  "/opt/mreg-validate/smoke-bridge.sh"
  "/opt/mreg-validate/posture-from-vnet.sh"
)
# Sub-checks that are tolerated (failures do NOT fail the overall suite,
# they show up as EXPECTED_FAIL in the summary). Empty by default — every
# check listed above is required.
declare -A TOLERATED=()

declare -a RESULTS=()
declare -a TAILS=()

OVERALL_RC=0
TMP=$(mktemp -d -t jumpbox-smoke.XXXXXX)
trap 'rm -rf "${TMP}"' EXIT

START=$(date +%s)
TIMEOUT=600  # 10 minutes total

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  cmd="${CMDS[$i]}"
  ELAPSED=$(( $(date +%s) - START ))
  REMAINING=$(( TIMEOUT - ELAPSED ))
  if [[ "${REMAINING}" -le 0 ]]; then
    echo "jumpbox-smoke: wall-time budget exhausted before ${name}" >&2
    RESULTS+=("TIMEOUT")
    TAILS+=("")
    if [[ -z "${TOLERATED[$name]:-}" ]]; then
      OVERALL_RC=1
    fi
    continue
  fi

  echo "---"
  echo "jumpbox-smoke: ${name} (budget ${REMAINING}s)"
  log="${TMP}/${name}.log"
  if timeout "${REMAINING}" "${RUN}" "${cmd}" >"${log}" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  if [[ "${rc}" -eq 0 ]]; then
    RESULTS+=("PASS")
  elif [[ "${rc}" -eq 7 ]]; then
    # Convention: exit 7 means SKIP. Treated as informational, not a failure.
    RESULTS+=("SKIP")
  elif [[ -n "${TOLERATED[$name]:-}" ]]; then
    RESULTS+=("EXPECTED_FAIL(${rc})")
  else
    RESULTS+=("FAIL(${rc})")
    OVERALL_RC=1
  fi
  tail -3 "${log}"
  TAILS+=("$(tail -1 "${log}")")
done

echo ""
echo "================ jumpbox-smoke summary ================"
printf "%-26s %s\n" "check" "result"
printf "%-26s %s\n" "--------------------------" "----------------"
for i in "${!NAMES[@]}"; do
  printf "%-26s %s\n" "${NAMES[$i]}" "${RESULTS[$i]}"
done
echo "======================================================="

if [[ "${OVERALL_RC}" -ne 0 ]]; then
  echo "jumpbox-smoke: FAIL — at least one required check failed (see ${TMP} for full logs)" >&2
  mkdir -p .build
  cp -R "${TMP}" .build/last-jumpbox-smoke || true
  exit 1
fi

echo "jumpbox-smoke: PASS — all required checks green"
echo "                (EXPECTED_FAIL and SKIP results are informational only)"

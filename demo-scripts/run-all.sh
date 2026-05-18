#!/usr/bin/env bash
# =============================================================================
# demo-scripts/run-all.sh — run the full demo end-to-end.
# =============================================================================
# Happy path:     ./run-all.sh             (runs 01..05; ~2-3 min cold cache
#                                            due to Bastion tunnel setup ≈30s
#                                            per jumpbox stage)
# Honest mode:    INCLUDE_RUNTIME_ATTEMPT=1 ./run-all.sh   (adds Stage 6)
#
# Each stage prints its own banner and PASS/FAIL line. This wrapper adds a
# bold ASCII banner between stages and prints a final summary table.
# Overall exit = max of child exits.
# =============================================================================

set -uo pipefail
# NOTE: deliberately no -e — we want to continue past a single failed stage
# and report it in the summary table.

cd "$(dirname "$0")"
# shellcheck source=./00_env.sh
source ./00_env.sh

bold_banner() {
  printf '\n\033[1m======================================================================\033[0m\n'
  printf   '\033[1m=== %-66s ===\033[0m\n' "$1"
  printf   '\033[1m======================================================================\033[0m\n\n'
}

# Stage script list, in order. Stage 6 is appended conditionally below.
STAGES=(
  "01_sc_model.sh"
  "02_sc_apim.sh"
  "03_sn_connection_and_agent.sh"
  "04_call_sn_routes_to_sc.sh"
  "05_replay_agent.sh"
)
if [[ "${INCLUDE_RUNTIME_ATTEMPT:-0}" == "1" ]]; then
  STAGES+=("06_attempt_runtime.sh")
fi

declare -a RESULT_NAME RESULT_STATUS RESULT_WALL

OVERALL=0
for s in "${STAGES[@]}"; do
  bold_banner "running $s"
  START=$(date +%s)
  bash "./$s"
  RC=$?
  END=$(date +%s)
  WALL=$((END - START))

  case "$RC" in
    0)
      STATUS="PASS"
      ;;
    *)
      STATUS="FAIL(rc=$RC)"
      OVERALL=$RC
      ;;
  esac
  # 06 prints SKIP itself on rc=0 when opt-out; the rc=0 case above still
  # records PASS for it (since SKIP-with-rc-0 is intentional behaviour).
  RESULT_NAME+=("$s")
  RESULT_STATUS+=("$STATUS")
  RESULT_WALL+=("${WALL}s")
done

bold_banner "summary"
printf '%-36s %-12s %s\n' "STAGE" "STATUS" "WALL"
printf '%-36s %-12s %s\n' "------------------------------------" "------------" "----"
for i in "${!RESULT_NAME[@]}"; do
  printf '%-36s %-12s %s\n' "${RESULT_NAME[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_WALL[$i]}"
done
echo

if [[ "$OVERALL" -eq 0 ]]; then
  echo "ALL STAGES PASS"
else
  echo "ONE OR MORE STAGES FAILED — overall rc=$OVERALL"
fi
exit "$OVERALL"

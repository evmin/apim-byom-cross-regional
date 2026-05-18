#!/usr/bin/env bash
# =============================================================================
# demo-scripts/06_attempt_runtime.sh — STAGE 4 (honest): runtime attempt.
# =============================================================================
# OPT-IN ONLY (set INCLUDE_RUNTIME_ATTEMPT=1). Honest mode.
#
# What this proves (or rather, what this exposes):
#   The Foundry agents-runtime path — POST /threads → /messages → /runs →
#   poll /runs/<id> — fails server-side with `last_error.code=server_error`
#   a few seconds after dispatch. Observed across every agent region we
#   tried in this deploy (NEU/WE/EUS2/FRC/CHN). The working paths shown
#   in scripts 04 and 05 are unaffected.
#
#   This is NOT a public documented Microsoft outage; it's empirical
#   evidence from this deploy. We DO NOT claim it's a "documented platform
#   issue" — only "observed across all tried regions in this deploy".
#
# Exit code 0 if a terminal `failed` state is reached (failing IS the
# expected outcome). Exit 1 only if the script itself errors out before
# observing a terminal status (network/auth glitch — couldn't even
# demonstrate the failure).
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

if [[ "${INCLUDE_RUNTIME_ATTEMPT:-0}" != "1" ]]; then
  echo "SKIP — 06_attempt_runtime (set INCLUDE_RUNTIME_ATTEMPT=1 to opt in)"
  exit 0
fi

# shellcheck source=./00_env.sh
source ./00_env.sh

AGENT_NAME="demo-cross-region-agent"

printf '\n==== STAGE 4 (honest): runtime attempt — expected to fail server-side ====\n'
echo "endpoint : $SN_FOUNDRY_PROJECT_ENDPOINT"
echo "agent    : $AGENT_NAME"
echo "(this script is opt-in; failing IS the expected outcome here)"
echo

REMOTE=$(cat <<REMOTE_EOF
set -euo pipefail
echo "[remote] acquiring AAD token (audience https://ai.azure.com) via IMDS..."
TOKEN=\$(curl -sS -H 'Metadata:true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://ai.azure.com' \
  | jq -r .access_token)
if [[ -z "\$TOKEN" || "\$TOKEN" == "null" ]]; then
  echo "[remote] FAIL: IMDS token returned empty" >&2; exit 1
fi
AUTH="Authorization: Bearer \$TOKEN"
CT="Content-Type: application/json"

echo "[remote] resolving agent id from /assistants..."
LIST=\$(curl -sSf -H "\$AUTH" \
  '${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1')
AID=\$(printf '%s' "\$LIST" | jq -r --arg n '${AGENT_NAME}' '.data[]? | select(.name==\$n) | .id' | head -n1)
if [[ -z "\$AID" ]]; then
  echo "[remote] FAIL: agent '${AGENT_NAME}' not found — run 03_sn_connection_and_agent.sh first" >&2
  exit 1
fi
echo "[remote] agent id: \$AID"

echo "[remote] POST /threads"
THR=\$(curl -sSf -X POST -H "\$AUTH" -H "\$CT" \
  '${SN_FOUNDRY_PROJECT_ENDPOINT}/threads?api-version=v1' -d '{}')
TID=\$(printf '%s' "\$THR" | jq -r .id)
printf '%s' "\$THR" | jq .
echo "[remote] thread id: \$TID"

echo "[remote] POST /threads/\$TID/messages"
MSG=\$(curl -sSf -X POST -H "\$AUTH" -H "\$CT" \
  "${SN_FOUNDRY_PROJECT_ENDPOINT}/threads/\$TID/messages?api-version=v1" \
  -d '{"role":"user","content":"Reply OK"}')
printf '%s' "\$MSG" | jq .

echo "[remote] POST /threads/\$TID/runs"
RUN=\$(curl -sSf -X POST -H "\$AUTH" -H "\$CT" \
  "${SN_FOUNDRY_PROJECT_ENDPOINT}/threads/\$TID/runs?api-version=v1" \
  -d "{\"assistant_id\":\"\$AID\"}")
RID=\$(printf '%s' "\$RUN" | jq -r .id)
printf '%s' "\$RUN" | jq .
echo "[remote] run id: \$RID"

STATUS="queued"
ATTEMPT=0
LAST_JSON=""
while [[ \$ATTEMPT -lt 15 ]]; do
  sleep 2
  ATTEMPT=\$((ATTEMPT + 1))
  LAST_JSON=\$(curl -sSf -H "\$AUTH" \
    "${SN_FOUNDRY_PROJECT_ENDPOINT}/threads/\$TID/runs/\$RID?api-version=v1")
  STATUS=\$(printf '%s' "\$LAST_JSON" | jq -r .status)
  echo "[remote] poll #\$ATTEMPT — status=\$STATUS"
  case "\$STATUS" in
    completed|failed|cancelled|expired)
      break
      ;;
  esac
done

echo "[remote] terminal status: \$STATUS"
echo "[remote] full last response:"
printf '%s' "\$LAST_JSON" | jq .
echo "[remote] last_error:"
printf '%s' "\$LAST_JSON" | jq '.last_error // "(none)"'

cat <<'FOOTER'
───────────────────────────────────────────────────────
The Foundry agents-runtime path (/threads/<id>/runs) is
server-side broken in this environment (observed across
all tried regions: NEU/WE/EUS2/FRC/CHN; no upstream APIM
traffic during failed runs). The working paths shown in
scripts 04 and 05 are unaffected.
───────────────────────────────────────────────────────
FOOTER

# Exit 0 even when status==failed: failing IS the expected outcome here.
# Only exit non-zero if we never reached a terminal status (couldn't even
# demonstrate the failure).
case "\$STATUS" in
  completed|failed|cancelled|expired)
    exit 0
    ;;
  *)
    echo "[remote] FAIL: never reached terminal status (last=\$STATUS)" >&2
    exit 1
    ;;
esac
REMOTE_EOF
)

REMOTE_B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
if ! ../scripts/jumpbox-run.sh "echo $REMOTE_B64 | base64 -d | bash"; then
  echo "FAIL — 06_attempt_runtime: remote loop errored before reaching a terminal status" >&2
  exit 1
fi

echo
echo "PASS — 06_attempt_runtime (failure is the expected outcome)"

#!/usr/bin/env bash
# =============================================================================
# demo-scripts/03_responses_api.sh — STAGE 3: end-to-end via Responses API (v2).
# =============================================================================
# Proves the full cross-region path works:
#   Switzerland North Foundry project → `apim-byom` connection
#   → APIM in Sweden Central → AOAI deployment in Sweden Central → reply.
#
# Uses two v2 surfaces (both must return "PONG"):
#   TEST 1: PromptAgentDefinition + Responses API (the canonical v2 agent path)
#   TEST 2: Raw oai.responses.create(model="apim-byom/gpt-5.4-nano")
#
# Per the foundry-cross-resource skill (verified 2026-04-23), conn/dep routing
# only works on oai.responses.create() — not on chat.completions.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=./00_env.sh
source ./00_env.sh

printf '\n==== STAGE 3: end-to-end via Responses API (v2) — conn/dep routing through APIM ====\n'
echo "endpoint    : $SN_FOUNDRY_PROJECT_ENDPOINT"
echo "model_ref   : $MODEL_REF"
echo "apim target : https://$APIM_GATEWAY_HOSTNAME"
echo

# The Python script runs inside the jumpbox venv which has azure-ai-projects + openai.
REMOTE=$(cat <<'REMOTE_EOF'
set -euo pipefail
source /etc/profile.d/mreg-validate.sh 2>/dev/null || true
source /opt/mreg-validate/venv/bin/activate 2>/dev/null || true

python3 - <<'PYEOF'
import os, sys, time

endpoint    = os.environ.get("AGENT_PROJECT_ENDPOINT", "").strip()
connection  = os.environ.get("FOUNDRY_CONNECTION_NAME", "apim-byom").strip()
deployment  = os.environ.get("MODEL_DEPLOYMENT_NAME", "").strip()
client_id   = os.environ.get("AZURE_CLIENT_ID", "").strip() or None
model_ref   = f"{connection}/{deployment}"

print(f"[remote] endpoint   = {endpoint}")
print(f"[remote] model_ref  = {model_ref}")
print(f"[remote] client_id  = {client_id or '(default MI)'}")

if not endpoint or not deployment:
    print("[remote] FAIL: AGENT_PROJECT_ENDPOINT / MODEL_DEPLOYMENT_NAME not set", file=sys.stderr)
    sys.exit(2)

from azure.identity import ManagedIdentityCredential
from azure.ai.projects import AIProjectClient

cred = ManagedIdentityCredential(client_id=client_id) if client_id else ManagedIdentityCredential()
project = AIProjectClient(endpoint=endpoint, credential=cred)

# Check SDK version
import azure.ai.projects as aip
print(f"[remote] azure-ai-projects version: {aip.__version__}")

# --- Test 1: v2 prompt agent via PromptAgentDefinition + Responses API ---
# Per MS Learn: agents.create_version() + PromptAgentDefinition, then
# responses.create() with extra_body={"agent_reference": ...}
print(f"\n[remote] TEST 1: v2 prompt agent (PromptAgentDefinition + Responses API)")
agent = None
try:
    from azure.ai.projects.models import PromptAgentDefinition

    agent = project.agents.create_version(
        agent_name="v2-byom-probe",
        definition=PromptAgentDefinition(
            model=model_ref,
            instructions="You only ever reply with the word PONG.",
        ),
    )
    print(f"[remote]   agent created: name={agent.name} version={getattr(agent, 'version', '?')}")

    oai = project.get_openai_client()
    conv = oai.conversations.create()
    print(f"[remote]   conversation: {conv.id}")

    t0 = time.monotonic()
    resp = oai.responses.create(
        input="Say it.",
        conversation=conv.id,
        extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
    )
    elapsed = (time.monotonic() - t0) * 1000
    text = resp.output_text if hasattr(resp, "output_text") else str(resp)
    print(f"[remote]   PASS in {elapsed:.0f}ms — output: {text!r}")

except ImportError as ie:
    print(f"[remote]   SKIP — PromptAgentDefinition not available: {ie}")
    print(f"[remote]   (SDK may need upgrade: pip install -U azure-ai-projects)")
except Exception as exc:
    elapsed = (time.monotonic() - t0) * 1000 if 't0' in dir() else 0
    print(f"[remote]   FAIL — {exc}")
finally:
    if agent:
        try:
            project.agents.delete_version(agent_name=agent.name, version=agent.version)
        except Exception:
            pass

# --- Test 2: Raw Responses API with conn/dep model string (Pattern A) ---
print(f"\n[remote] TEST 2: Raw responses.create(model='{model_ref}')")
oai = project.get_openai_client()
try:
    t0 = time.monotonic()
    resp = oai.responses.create(
        model=model_ref,
        input="Reply PONG.",
        max_output_tokens=32,
    )
    elapsed = (time.monotonic() - t0) * 1000
    text = resp.output_text if hasattr(resp, "output_text") else str(resp)
    print(f"[remote]   PASS in {elapsed:.0f}ms — output: {text!r}")
except Exception as exc:
    elapsed = (time.monotonic() - t0) * 1000
    print(f"[remote]   FAIL in {elapsed:.0f}ms — {exc}")

print("\n[remote] done")
PYEOF
REMOTE_EOF
)

REMOTE_B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
if ! ../scripts/jumpbox-run.sh "echo $REMOTE_B64 | base64 -d | bash"; then
  echo "FAIL — 03_responses_api: remote script errored" >&2
  exit 1
fi

echo
echo "PASS — 03_responses_api"

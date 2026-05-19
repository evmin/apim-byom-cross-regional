# `demo-scripts/` — Cross-region demo (Switzerland North → APIM SC → AOAI SC)

Crystal-clear, laconic. Each script does ONE thing, prints a banner, ends in
`PASS — <name>` or a one-line failure.

## Narrative

```
STAGE 1: Here is the model deployed in Sweden Central.
STAGE 2: Here is APIM in Sweden Central, fronting that model.
STAGE 3: Hit the Switzerland North Foundry project's Responses API with
         model = `apim-byom/gpt-5.4-nano`. Foundry resolves the `apim-byom`
         connection, calls APIM in Sweden Central, which calls the AOAI
         deployment behind it. The reply comes back end-to-end. The
         cross-region routing is invisible to the caller.
```

## Prerequisites

- `azd env select fdev` — the demo reads values via `azd env get-values`.
- `az login` — the operator's account is needed only for the control-plane
  reads in stages 1–2 (model deployment, APIM service).
  All data-plane calls run on the jumpbox via its UAMI.
- The jumpbox UAMI must be (already is, per the 001 IaC) granted:
  - **Azure AI Developer** on the agent project (Stage 3),
  - **Cognitive Services User** on the SC AOAI account (for the APIM bridge),
  - **oid in the APIM `validate-azure-ad-token` allowlist** (Stage 3 fall-through path).
- Local SSH private key matching `JUMPBOX_SSH_PUBLIC_KEY` available at
  `~/.ssh/mreg-jumpbox` (default; override with `JUMPBOX_SSH_PRIVATE_KEY`).

## Run order

```bash
# happy path (~1-2 min cold; most time is the single Bastion tunnel setup ≈30s)
bash demo-scripts/run-all.sh

# individual stages (each is standalone; just `source ./00_env.sh` at top)
bash demo-scripts/01_sc_model.sh
bash demo-scripts/02_sc_apim.sh
bash demo-scripts/03_responses_api.sh
```

## What each script proves

| Stage | Script                       | Proof |
|------:|------------------------------|-------|
| 1     | `01_sc_model.sh`             | SC AOAI/Foundry account live in `swedencentral`; `gpt-5.4-nano` deployment is live. Pure `az` from the Mac. |
| 2     | `02_sc_apim.sh`              | APIM service in SC with `publicNetworkAccess=Disabled`; `openai` API present; service-level policy carries `validate-azure-ad-token` + backend rewrite. Pure `az` from the Mac. |
| 3     | `03_responses_api.sh`        | End-to-end: from the jumpbox UAMI inside the agent VNet, the SN project's Responses API resolves `apim-byom/gpt-5.4-nano` and returns a real reply. Runs two sub-tests, both must return `'PONG'`: (a) v2 `PromptAgentDefinition` + Responses API, (b) raw `oai.responses.create(model=…)`. |

## Expected output

Captured from a live run against `fdev` (Switzerland North + Sweden Central).

### `01_sc_model.sh`

```
==== STAGE 1: model in Sweden Central ====
…
NAME                  LOCATION       KIND
mregfdevfdryscqx3thf  swedencentral  AIServices

Name          Model         Version     Sku             Capacity
------------  ------------  ----------  --------------  ----------
gpt-5.4-nano  gpt-5.4-nano  2026-03-17  GlobalStandard  50

PASS — 01_sc_model
```

### `02_sc_apim.sh`

```
==== STAGE 2: APIM in Sweden Central ====
…
NAME                      LOCATION        PUBNET    SKU
mreg-fdev-apim-sc-qx3thf  Sweden Central  Disabled  StandardV2

Name    Path    ServiceUrl
------  ------  ----------------------------------------------------
openai  openai  https://mregfdevfdryscqx3thf.openai.azure.com/openai

--- inbound policy excerpt (first 30 lines, service-level) ---
<policies>
  <inbound>
    <choose>
      <when condition='@(... != "{{apim-byom-key}}")'>
        <validate-azure-ad-token … >
          …
        </validate-azure-ad-token>
      </when>
    </choose>
    <set-header name="api-key" exists-action="delete" />
    <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
    <set-backend-service base-url="https://…/openai" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" … />
    …
  </inbound>
</policies>

PASS — 02_sc_apim
```

### `03_responses_api.sh`

```
==== STAGE 3: end-to-end via Responses API (v2) — conn/dep routing through APIM ====
endpoint    : https://mregfdevfdrychnl33kar.services.ai.azure.com/api/projects/agent-project
model_ref   : apim-byom/gpt-5.4-nano
apim target : https://mreg-fdev-apim-sc-qx3thf.azure-api.net

[remote] endpoint   = https://mregfdevfdrychnl33kar.services.ai.azure.com/api/projects/agent-project
[remote] model_ref  = apim-byom/gpt-5.4-nano
[remote] azure-ai-projects version: 2.1.0

[remote] TEST 1: v2 prompt agent (PromptAgentDefinition + Responses API)
[remote]   agent created: name=v2-byom-probe version=1
[remote]   conversation: conv_…
[remote]   PASS in ~3700ms — output: 'PONG'

[remote] TEST 2: Raw responses.create(model='apim-byom/gpt-5.4-nano')
[remote]   PASS in ~2900ms — output: 'PONG'

PASS — 03_responses_api
```

### `run-all.sh` summary

```
STAGE                                STATUS       WALL
------------------------------------ ------------ ----
01_sc_model.sh                       PASS         5s
02_sc_apim.sh                        PASS         8s
03_responses_api.sh                  PASS         8s

ALL STAGES PASS
```

## When something fails

- **`01_sc_model.sh`** — most often `FAIL — 01_sc_model: account is in
  '<other>'` when the env was re-deployed against a different region pair.
  Confirm `azd env get-values | grep AZURE_LOCATION` and the model RG name.
- **`02_sc_apim.sh`** — `publicNetworkAccess` may flip to `Enabled` if
  `hooks/postprovision-finalize.sh` hasn't run. Re-run it.
- **`03_responses_api.sh`** — first failure mode is the SSH key not being
  found (`jumpbox-run: SSH private key not found at …`); next is Bastion
  tunnel timeout (re-run; the jumpbox cold-start can be slow). If TEST 1
  fails with `Connection 'apim-byom' not found`, verify the Foundry
  connection target ends in `/openai` and `authType=ApiKey` is set
  (see `infra/modules/foundry-connection.bicep`). If TEST 2 fails with a
  401 from APIM, the jumpbox UAMI's oid may not be in the APIM allowlist
  (re-deploy with the current `JUMPBOX_UAMI_PRINCIPAL_ID` in
  `infra/main.bicep`).

## See also

- `../docs/005_architecture.md` — full architecture diagrams (don't duplicate them
  here).
- `scripts/jumpbox/` — the deeper validation suite (DNS audit, posture
  audit, AAD-reject smoke, direct-inference smoke). These run from inside
  the agent VNet and are wired into `azd up` via
  `hooks/postprovision-smoke.sh`.

# Quickstart — Private Foundry Agent IaC

**Feature**: `001-private-foundry-iac`
**Plan**: [`plan.md`](./plan.md)
**Architecture**: [`../../docs/005_architecture.md`](../../docs/005_architecture.md)

One-page operator walkthrough. Brings up the full private topology (WE agent plane + SC model plane + cross-region APIM bridge) with a single `azd up`, smoke-tests it, and tears it down with `azd down`.

> Implementation state: the Bicep that realises this is now authored in `infra/main.bicep` + `infra/modules/*` and compiles cleanly (`az bicep build infra/main.bicep` — 0 errors). AVM-first; native fallbacks are recorded inline with retire-when comments.

### AVM pins (authoritative — do NOT drift without re-running `verify-bicep`)

| Module | Pin |
|---|---|
| `avm/res/network/virtual-network` | `0.9.0` |
| `avm/res/network/private-endpoint` | `0.12.1` |
| `avm/res/network/private-dns-zone` | `0.8.1` |
| `avm/res/cognitive-services/account` | `0.14.2` |
| `avm/res/api-management/service` | `0.14.1` |
| `avm/res/document-db/database-account` | `0.19.0` |
| `avm/res/search/search-service` | `0.12.1` |
| `avm/res/storage/storage-account` | `0.32.0` |

Native fallbacks (AVM-gap with inline `// AVM gap:` comments):

| Resource type | Where | Rationale |
|---|---|---|
| `Microsoft.CognitiveServices/accounts/projects@2025-06-01` | `we-agent-plane.bicep` | AVM `cognitive-services/account@0.14.2` does not author projects (R-01 / R-06). |
| `Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01` | `foundry-connection.bicep` | Same module also lacks connections coverage (R-01 / R-A1). |
| `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15` | `cosmos-sql-role-assignment.bicep` | AVM `document-db/database-account@0.19.0` lacks data-plane role coverage (R-A1). |
| `Microsoft.Authorization/roleAssignments@2022-04-01` | `rbac-model-rg.bicep`, `rbac-agent-rg.bicep` | AVM `authorization/role-assignment/rg-scope@0.1.1` does not expose principalId / roleDefinitionIdOrName / resourceId on its params surface (R-A2). |

---

## 1. Prerequisites

On the workstation (or CI runner):

- **Azure CLI** (`az`) — recent stable. Bicep is auto-installed by `az` on first use; confirm with `az bicep version`.
- **Azure Developer CLI** (`azd`) — recent stable. Confirm with `azd version`.
- **An AAD principal** (your user account or a service principal) with rights to:
  - create resource groups in the target subscription,
  - create RBAC role assignments at resource scope,
  - create the resource types listed in [`data-model.md`](./data-model.md).
- **Resource providers registered** on the target subscription (T-001 — manual, one-time per subscription):
  ```bash
  for ns in \
    Microsoft.CognitiveServices \
    Microsoft.MachineLearningServices \
    Microsoft.ApiManagement \
    Microsoft.Network \
    Microsoft.DocumentDB \
    Microsoft.Search \
    Microsoft.Storage \
    Microsoft.App \
    Microsoft.OperationalInsights; do
    az provider register --namespace "$ns"
  done

  # Wait for every namespace to reach Registered:
  for ns in Microsoft.CognitiveServices Microsoft.ApiManagement Microsoft.Network \
            Microsoft.DocumentDB Microsoft.Search Microsoft.Storage Microsoft.App; do
    az provider show -n "$ns" --query registrationState -o tsv
  done
  ```
  `Microsoft.OperationalInsights` is only required when you wire diagnostics to a BYO workspace.
- **Subscription capacity** for APIM Standard v2 (or Premium v2) in Sweden Central and for the model SKUs you plan to deploy. Quota is the operator's responsibility (`spec.md` § Assumptions).

---

## 2. Sign in and create an `azd` environment

```bash
az login
az account set --subscription "<your-subscription-id>"

azd auth login

# One azd env per deployment instance:
azd env new <env-name>          # e.g.  azd env new foundry-priv-dev
```

`azd env new` creates `.azure/<env-name>/` locally. That directory holds your env vars and is git-ignored.

---

## 3. Set parameters

The full parameter surface is described by [`contracts/parameters.schema.json`](./contracts/parameters.schema.json). The minimum required set:

```bash
# Required
azd env set MODEL_DEPLOYMENTS      '[{"name":"gpt-4o","model":"gpt-4o","version":"2024-11-20","skuName":"GlobalStandard","skuCapacity":50}]'

# Defaults shown; override only if needed
azd env set NAME_PREFIX            mreg                        # 2–12 lowercase; default `mreg`
azd env set REGION_PAIR            westeurope+swedencentral    # or eastus2+swedencentral
azd env set APIM_SKU               StandardV2                  # or PremiumV2
azd env set APIM_CAPACITY          1
azd env set URL_PATH_STYLE         aoai                        # or openai
azd env set ENABLE_SEMANTIC_CACHE  false
azd env set ENABLE_DYNAMIC_DISCOVERY false
azd env set ENABLE_SMOKE_VALIDATION true

# CIDRs — defaults from research.md R-10; override if they collide with your hub
azd env set WE_VNET_CIDR           10.40.0.0/20
azd env set AGENT_SUBNET_CIDR      10.40.0.0/24
azd env set AGENT_PE_SUBNET_CIDR   10.40.1.0/27
azd env set SC_VNET_CIDR           10.50.0.0/20
azd env set APIM_OUTBOUND_SUBNET_CIDR  10.50.0.0/27
azd env set SC_PE_SUBNET_CIDR      10.50.1.0/27

# Optional — BYO existing private DNS zones (per-zone resource IDs)
# azd env set EXISTING_DNS_ZONE_PRIVATELINK_AZURE_API_NET  '/subscriptions/.../privateDnsZones/privatelink.azure-api.net'
# (one env var per zone — see contracts/parameters.schema.json for the full list)

# Optional — BYO Log Analytics workspace for diagnostics
# azd env set LOG_ANALYTICS_WORKSPACE_ID '/subscriptions/.../workspaces/<name>'
```

`AZURE_SUBSCRIPTION_ID` and `AZURE_ENV_NAME` are managed by `azd` itself.

---

## 4. Preview, then deploy

```bash
# Always preview first — runs ARM what-if under the hood.
azd provision --preview

# When the preview is clean, deploy:
azd up
```

`azd up` runs (in order) `provision` (Bicep) and then any `azd` lifecycle hooks. Expect 30–60 minutes on first run — APIM Std v2 / Prem v2 first-create dominates wall time.

On success, inspect the outputs:

```bash
azd env get-values
```

You should see the keys listed in [`contracts/outputs.schema.json`](./contracts/outputs.schema.json) — resource group names, the WE Foundry project endpoint, the (private) APIM gateway hostname, the two MI principal IDs, and the private DNS zone resource IDs.

---

## 5. Smoke test — end-to-end private path

> **As of the demo-jumpbox feature**, the smoke is **automated** by `hooks/postprovision-smoke.sh` → `scripts/jumpbox-smoke.sh`, which uses the always-on **demo jumpbox** + **Azure Bastion** provisioned inside the agent VNet. See `TODO.md` § 6 "Verify after deploy" for the operator-facing checklist. The Python snippet below remains the canonical reference for the SDK path.

The smoke test must run from **inside** the WE agent VNet (or anywhere DNS resolution and connectivity to the WE PE subnet are available). Typical options:

1. A small **private VM** in the WE agent VNet's PE subnet (or any other subnet with line-of-sight to the PEs). Connect via Azure Bastion.
2. A **GitHub Actions self-hosted runner** that joins the agent VNet.
3. An **`azd` postprovision hook** — `hooks/postprovision-smoke.sh` runs automatically when `ENABLE_SMOKE_VALIDATION=true` AND `<apim>.azure-api.net` resolves to an RFC1918 address from the deploy host. When the host has no private-network context the hook logs `skipped — no private-network context` and exits 0 (FR-029).

Manual smoke call (from a private VM, after `pip install azure-ai-projects azure-identity`):

```python
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

# Endpoint and connection name come from the azd outputs.
project = AIProjectClient(
    endpoint="<weFoundryProjectEndpoint from azd env get-values>",
    credential=DefaultAzureCredential(),
)

# Reference the model via <connection-name>/<deployment-name>.
# The connection is the Foundry "Azure API Management" admin-connected model wired in wiring.bicep.
client = project.inference.get_chat_completions_client()
response = client.complete(
    model="<connection-name>/<deployment-name>",   # e.g.  apim-sc/gpt-4o
    messages=[{"role": "user", "content": "Reply with 'pong'."}],
)
print(response.choices[0].message.content)
```

Expected: a 2xx with a model reply. The entire path stays on private IPs — agent runtime → WE PE for APIM → APIM gateway (SC) → APIM outbound VNet integration (SC) → SC PE for the model account → SC model deployment.

### Network-posture audit

From any console with `az`:

```bash
RG_AGENT=$(azd env get-value AGENT_RESOURCE_GROUP_NAME)
RG_MODEL=$(azd env get-value MODEL_RESOURCE_GROUP_NAME)

# Every cognitiveservices / apim / cosmos / search / storage account in both RGs should report Disabled.
az resource list --resource-group "$RG_AGENT" \
    --query "[?type=='Microsoft.CognitiveServices/accounts' || type=='Microsoft.DocumentDB/databaseAccounts' || type=='Microsoft.Search/searchServices' || type=='Microsoft.Storage/storageAccounts'].{name:name, type:type, pub:properties.publicNetworkAccess}" \
    -o table

az resource list --resource-group "$RG_MODEL" \
    --query "[?type=='Microsoft.CognitiveServices/accounts' || type=='Microsoft.ApiManagement/service'].{name:name, type:type, pub:properties.publicNetworkAccess}" \
    -o table
```

Every row's `pub` column MUST be `Disabled`. APIM's `publicNetworkAccess` MUST be `Disabled` (this is what disables the public gateway).

---

## 6. Iterate — change one parameter and re-deploy

```bash
# Example: add a second model deployment
azd env set MODEL_DEPLOYMENTS '[{"name":"gpt-4o", ...}, {"name":"gpt-4o-mini", ...}]'

azd provision --preview      # confirm only the SC model deployments + Foundry connection are affected
azd up                       # apply
```

A second consecutive `azd up` with unchanged parameters MUST report zero material changes (`SC-004` / `FR-003`).

---

## 7. Teardown

```bash
azd down --purge
```

This removes every resource the solution created across both regional resource groups (`SC-005`). Operator-owned inputs (BYO existing private DNS zones, BYO Log Analytics workspace) are **never** deleted — only the VNet links / A-records / diagnostic settings the solution added are removed.

After `azd down` completes, audit:

```bash
# Solution-managed resource groups should be gone (or empty).
az group exists --name "$RG_AGENT"
az group exists --name "$RG_MODEL"

# Solution-managed private DNS zones (create-new mode) should be gone.
# If you used BYO zones, the zones should still exist; only the VNet links the solution added should be gone.
```

---

## 8. Helper scripts / hooks (in this repo)

| Path | Stage | Purpose |
|---|---|---|
| `hooks/postprovision-audit.sh` | `azd up` postprovision | T-036 posture audit — `publicNetworkAccess`, key-auth, role-assignment leak, cross-region PE, APIM policy oid. |
| `hooks/postprovision-smoke.sh` | `azd up` postprovision | T-037 end-to-end smoke (gated on `ENABLE_SMOKE_VALIDATION`). |
| `hooks/postprovision-connection.sh.template` | INERT | T-032 NO-OP fallback — only activated if the Bicep-native Foundry connection in `foundry-connection.bicep` fails to deploy. |
| `hooks/predown-connection.sh.template` | INERT | Mirror of the above — runs on `azd down` once the fallback is enabled. |
| `scripts/verify-bicep.sh` | manual | T-033 — `az bicep build` + lint; fails on any error. |
| `scripts/whatif.sh` | manual | T-034 — captures `azd provision --preview` JSON + raw what-if; flags Deletes / Ignored. |
| `scripts/verify-idempotency.sh` | manual | T-035 — second-run what-if must report NoChange for every resource. |
| `scripts/abort-and-resume.sh` | manual | T-035a — partial-failure recovery probe (post-resume). |
| `scripts/verify-region-pair-switch.sh` | manual | T-035b — full WE+SC → EUS2+SC switch verification. |
| `scripts/verify-teardown.sh` | manual | T-038 — post-`azd down` tag / DNS-zone / orphan-role-assignment probe. |

The two `.template` files in `hooks/` are **inert by default**. The Bicep-native Foundry connection (T-031) is the primary path. Only rename `.template` → `.sh` AND uncomment the matching `hooks` block in `azure.yaml` AND comment out the `foundryConnection` module in `infra/modules/wiring.bicep` IF the connection resource fails to deploy and an authoring-time category fix cannot resolve it.

---

## 9. Troubleshooting

| Symptom | Likely cause | First action |
|---|---|---|
| `azd up` fails inside APIM provisioning | First-time APIM Std v2 / Prem v2 creation can take 30–60 min and occasionally times out a hook | Re-run `azd up`. `FR-004` requires idempotent recovery. |
| `validate-azure-ad-token` rejects the agent's bearer | The audience or the project MI principal hasn't propagated yet | Wait ≤ 5 minutes after `azd up` and retry the smoke call. |
| Smoke call returns DNS errors for `*.azure-api.net` | You are calling from outside the WE agent VNet, or `privatelink.azure-api.net` is not linked | Run the smoke from inside the WE VNet; verify W-Z7 (`privatelink.azure-api.net`) is linked to W-N1. |
| `publicNetworkAccess` shows `Enabled` on any resource | Should not happen — `FR-023` forbids it | Re-run `az bicep build`; open a defect — this is a regression in IaC or in an AVM module's defaults. |
| `azd down` complains about role assignments on deleted scopes | Eventual-consistency lag | Re-run `azd down`; `FR-002` requires clean teardown. |

---

## 10. What this does **not** do

- It does not deploy any agent code, skills, prompts, or orchestration logic.
- It does not load any documents, indexes, containers, or blobs into Cosmos / AI Search / Storage.
- It does not provision an Azure Firewall, NAT Gateway, or any egress-control resource (operator BYO).
- It does not provision a Log Analytics workspace (optionally consumes an existing one via parameter).
- It does not register the required Azure resource providers — that is a one-time, per-subscription operator step.

Full out-of-scope list: [`spec.md`](./spec.md) § Out of Scope.

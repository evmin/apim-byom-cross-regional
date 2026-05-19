# Quickstart — deploy, verify, tear down

This is the working operator's view of the stack. Architecture lives in [`001_architecture.md`](./001_architecture.md). Decision rationale lives in [`madr/`](./madr/). For the curated AVM + design reference see [`004_research.md`](./004_research.md). This page is the short version: deploy, verify, tear down.

## What you need

On the workstation:

- **Azure CLI** (`az`) — recent stable. Bicep is auto-installed by `az` on first use; confirm with `az bicep version`.
- **Azure Developer CLI** (`azd`) — recent stable.
- **An AAD principal** with rights to create resource groups, RBAC role assignments at resource scope, and the resource types listed in [`001_architecture.md`](./001_architecture.md) § Topology.
- **Subscription capacity** for APIM Standard v2 (or Premium v2) in Sweden Central and for your chosen model SKU. Quota is the operator's responsibility.

On the subscription (one time, ever):

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
```

Wait for every namespace to reach `Registered`:

```bash
for ns in Microsoft.CognitiveServices Microsoft.ApiManagement Microsoft.Network \
          Microsoft.DocumentDB Microsoft.Search Microsoft.Storage Microsoft.App; do
  az provider show -n "$ns" --query registrationState -o tsv
done
```

`Microsoft.OperationalInsights` is only required when you wire diagnostics to a BYO workspace.

## AVM pins

The stack uses [Azure Verified Modules](https://aka.ms/avm) as the first preference. Native Bicep is used only where AVM does not yet cover a resource type. Module pins are authoritative — do not drift without running `scripts/verify-bicep.sh`.

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
| `avm/res/authorization/role-assignment/rg-scope` | `0.1.1` |

Native fallbacks (each carries an inline `// AVM gap:` comment):

| Resource type | Where | Why |
|---|---|---|
| `Microsoft.CognitiveServices/accounts/projects@2025-06-01` | `infra/modules/we-agent-plane.bicep` | AVM `cognitive-services/account@0.14.2` does not author projects. |
| `Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01` | `infra/modules/foundry-connection.bicep` | Same module also lacks connections coverage. |
| `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15` | `infra/modules/cosmos-sql-role-assignment.bicep` | AVM `document-db/database-account@0.19.0` lacks data-plane role coverage. |
| `Microsoft.Authorization/roleAssignments@2022-04-01` | `infra/modules/rbac-{agent,model}-rg.bicep` | AVM `authorization/role-assignment/rg-scope@0.1.1` does not expose `principalId` / `roleDefinitionIdOrName` / `resourceId` on its params surface. |

See [`004_research.md`](./004_research.md) for the full design analysis behind these choices.

## First-time deploy

```bash
# 1. Sign in.
az login
az account set --subscription "<your-subscription-id>"
azd auth login

# 2. Create an azd environment (one per deployment instance).
azd env new <env-name>          # e.g.  azd env new fdev
```

`azd env new` creates `.azure/<env-name>/` locally. That directory holds your env vars and is git-ignored.

```bash
# 3. Set parameters. Required first; defaults sane otherwise.
azd env set MODEL_DEPLOYMENTS \
  '[{"name":"gpt-5.4-nano","model":"gpt-5.4-nano","version":"2026-03-17","skuName":"GlobalStandard","skuCapacity":50}]'

# Optional overrides (shown with defaults)
azd env set NAME_PREFIX             mreg                        # 2-12 lowercase
azd env set REGION_PAIR             westeurope+swedencentral    # or eastus2+swedencentral
azd env set APIM_SKU                StandardV2                  # or PremiumV2
azd env set APIM_CAPACITY           1
azd env set URL_PATH_STYLE          aoai                        # or openai
azd env set ENABLE_SEMANTIC_CACHE   false
azd env set ENABLE_DYNAMIC_DISCOVERY false
azd env set ENABLE_SMOKE_VALIDATION  true

# CIDR overrides (defaults shown — non-overlapping RFC1918, well clear of typical hubs)
azd env set WE_VNET_CIDR                10.40.0.0/20
azd env set AGENT_SUBNET_CIDR           10.40.0.0/24
azd env set AGENT_PE_SUBNET_CIDR        10.40.1.0/27
azd env set SC_VNET_CIDR                10.50.0.0/20
azd env set APIM_OUTBOUND_SUBNET_CIDR   10.50.0.0/27
azd env set SC_PE_SUBNET_CIDR           10.50.1.0/27

# Optional — BYO private DNS zones (one env var per zone)
# azd env set EXISTING_DNS_ZONE_PRIVATELINK_AZURE_API_NET '/subscriptions/.../privateDnsZones/privatelink.azure-api.net'

# Optional — BYO Log Analytics workspace
# azd env set LOG_ANALYTICS_WORKSPACE_ID '/subscriptions/.../workspaces/<name>'
```

Full parameter surface: [`../infra/contracts/parameters.schema.json`](../infra/contracts/parameters.schema.json).

```bash
# 4. Preview, then deploy.
./scripts/verify-bicep.sh        # compile check + lint
./scripts/whatif.sh              # ARM what-if
azd up                           # full provision; ~30-60 min on first run (APIM dominates)
./scripts/verify-idempotency.sh  # re-runs azd provision; should be a no-op
```

After `azd up` succeeds, capture the outputs:

```bash
azd env get-values | sort
```

You should see the agent + model resource-group names, the agent project endpoint, the (private) APIM gateway hostname, the two MI principal IDs, and the private DNS zone resource IDs. Output contract: [`../infra/contracts/outputs.schema.json`](../infra/contracts/outputs.schema.json).

## Verify the stack

The deployment ships with two verification suites. Run them from the workstation:

```bash
# Three-stage demo — proves the cross-region BYOM path works end-to-end.
bash scripts/demo/run-all.sh

# Five-check smoke suite — runs from inside the agent VNet via Bastion.
# Also wired into `azd up` as a postprovision hook when ENABLE_SMOKE_VALIDATION=true.
bash scripts/jumpbox-smoke.sh
```

`scripts/demo/run-all.sh` runs three scripts and prints `ALL STAGES PASS` on success:

| Stage | Script | What it proves |
|---|---|---|
| 1 | `01_sc_model.sh` | The SC model account and the model deployment are live. |
| 2 | `02_sc_apim.sh` | APIM in SC has `publicNetworkAccess=Disabled` and the inbound policy is installed. |
| 3 | `03_responses_api.sh` | The agent project's Responses API resolves `apim-byom/<deployment>` end-to-end. Two sub-tests must return `'PONG'`: (a) v2 PromptAgent + Responses API, (b) raw `responses.create`. |

`scripts/jumpbox-smoke.sh` runs five checks from inside the agent VNet:

| Check | What it proves |
|---|---|
| `bootstrap-status` | The jumpbox cloud-init finished successfully. |
| `smoke-dns` | Every `privatelink.*` zone resolves to RFC1918 from inside the VNet. |
| `smoke-reject` | APIM rejects a wrong-audience token with 401/403. |
| `smoke-bridge` | The jumpbox UAMI calls APIM → SC AOAI → reply, end-to-end. |
| `posture-from-vnet` | Every data-plane resource reports `publicNetworkAccess=Disabled`. |

Then audit network posture from any console with `az`:

```bash
RG_AGENT=$(azd env get-value agentResourceGroupName)
RG_MODEL=$(azd env get-value modelResourceGroupName)

az resource list --resource-group "$RG_AGENT" \
  --query "[?type=='Microsoft.CognitiveServices/accounts' || type=='Microsoft.DocumentDB/databaseAccounts' || type=='Microsoft.Search/searchServices' || type=='Microsoft.Storage/storageAccounts'].{name:name, type:type, pub:properties.publicNetworkAccess}" \
  -o table

az resource list --resource-group "$RG_MODEL" \
  --query "[?type=='Microsoft.CognitiveServices/accounts' || type=='Microsoft.ApiManagement/service'].{name:name, type:type, pub:properties.publicNetworkAccess}" \
  -o table
```

Every `pub` column must read `Disabled`. APIM's `publicNetworkAccess` reading `Disabled` is what closes the public gateway.

### Manual SDK smoke

When you need to drive the path from your own code rather than the suite scripts, point an `AIProjectClient` at the agent project endpoint and call the v2 Responses API. The canonical reference is the bash + Python heredoc in [`scripts/demo/03_responses_api.sh`](../scripts/demo/03_responses_api.sh) — run it through the jumpbox via Bastion (or copy the snippet into your own private-network host):

```bash
# From the workstation: runs Python on the jumpbox via Bastion.
bash scripts/demo/03_responses_api.sh
```

The script issues two calls. Both must return `'PONG'`:

1. A `PromptAgentDefinition` invocation that resolves `apim-byom/<deployment>` through the BYOM connection.
2. A raw `oai.responses.create(model='apim-byom/<deployment>')` call against the project's Responses endpoint.

Read the script for the full Python; it is the shortest authoritative example of the SDK path the agent runtime takes.

## Re-deploy after changes

`azd up` is idempotent. For routine changes:

```bash
# Bicep change.
./scripts/verify-bicep.sh
azd provision --preview
azd provision

# Parameter change.
azd env set <KEY> <value>
azd provision --preview
azd provision
```

A second consecutive `azd up` with unchanged parameters reports zero material changes.

To switch region pairs in-place:

```bash
azd env set REGION_PAIR <new-pair>
azd provision
```

## Tear down

```bash
azd down --force --purge
./scripts/verify-teardown.sh
```

`--purge` deletes soft-deleted Cognitive Services and Key Vault resources. Without it, name collisions block the next `azd up` until the soft-delete window expires.

Operator-owned inputs (BYO private DNS zones, BYO Log Analytics workspace) are never deleted — only the VNet links, A-records, and diagnostic settings the solution added are removed.

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| `azd up` fails inside APIM provisioning | First-time APIM Std v2 / Prem v2 creation can take 30-60 min and occasionally times out a hook. Re-run `azd up`; the deploy is idempotent. |
| `azd up` fails on Cognitive Services with `account exists` | Soft-deleted account from a prior tear-down. Run `azd down --purge` first, or `az cognitiveservices account purge`. |
| `validate-azure-ad-token` rejects the agent's bearer right after deploy | The audience or the project MI principal hasn't propagated yet. Wait up to five minutes and retry. |
| `03_responses_api.sh` test 1 returns `Connection 'apim-byom' not found` | The Foundry connection target is missing the `/openai` suffix or `authType` is not `ApiKey`. Check `infra/modules/foundry-connection.bicep`. |
| `03_responses_api.sh` test 2 returns `401` from APIM | The jumpbox UAMI's oid is not in the APIM allow-list. Inspect `azd env get-value jumpboxUamiPrincipalId` and re-deploy. |
| `jumpbox-smoke.sh` step `smoke-dns` returns a public IP | The agent VNet is not linked to one of the `privatelink.*` zones. Re-deploy. |
| Network-posture audit shows a resource with `publicNetworkAccess=Enabled` | A postprovision hook didn't run. Re-run `azd provision`. |
| `azd down` complains about role assignments on deleted scopes | Eventual-consistency lag. Re-run `azd down`. |

## Reference scripts

| Script | Purpose |
|---|---|
| `scripts/verify-bicep.sh` | Compile-check every Bicep file (`az bicep build`). |
| `scripts/whatif.sh` | ARM what-if on the current `azd` env. |
| `scripts/verify-idempotency.sh` | Re-runs `azd provision`; asserts no-op. |
| `scripts/verify-teardown.sh` | Asserts no resource left behind after `azd down`. |
| `scripts/jumpbox-smoke.sh` | Five-check validation suite via Bastion. |
| `scripts/jumpbox-connect.sh` | Open an interactive SSH-over-Bastion shell on the jumpbox. |
| `scripts/jumpbox-run.sh` | One-shot remote command on the jumpbox via Bastion. |
| `scripts/demo/run-all.sh` | Three-stage end-to-end demo. |

## What this does *not* do

- Deploy any agent code, skills, prompts, or orchestration logic.
- Load any documents, indexes, or blobs into Cosmos / AI Search / Storage.
- Provision an Azure Firewall, NAT Gateway, or any egress-control resource (operator BYO).
- Provision a Log Analytics workspace (optionally consumes an existing one).
- Register Azure resource providers — that is a one-time, per-subscription operator step.

## See also

- [`001_architecture.md`](./001_architecture.md) — full technical narrative.
- [`003_portal_tunnel.md`](./003_portal_tunnel.md) — browse the Foundry portal through the jumpbox while public access is off.
- [`004_research.md`](./004_research.md) — AVM coverage analysis and design decisions.
- [`madr/`](./madr/) — Architecture Decision Records.

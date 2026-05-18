---
description: "Task list for `001-private-foundry-iac` — Bicep / azd / AVM IaC for private Foundry Agent with cross-region APIM and Sweden Central model plane."
---

# Tasks: Bicep / AZD / AVM IaC for Private Foundry Agent with Cross-Region Model

**Input**: Design documents from `/specs/001-private-foundry-iac/`

**Prerequisites**:
- `plan.md` (required) — committed, Phase 0/1 COMPLETE.
- `spec.md` (required, decision-complete; 0 `[NEEDS CLARIFICATION]` markers).
- `research.md` (Phase 0 — see also the **Tasks-time addendum (`R-A1`)** appended during `/speckit.tasks` for AVM-pin and R-01/R-02/R-06 closure).
- `data-model.md` (Phase 1 — resource topology and AVM-or-fallback decisions).
- `contracts/parameters.schema.json`, `contracts/outputs.schema.json` (Phase 1 — IO contracts).
- `quickstart.md` (Phase 1 — operator walkthrough; smoke validation source).

**Tests**: This is an Infrastructure-as-Code project. There is **no application unit/contract/integration test suite** because there is no application code (spec § Out of Scope). The functional tests for this feature are:
- `az bicep build` / `az bicep lint` (compile-time correctness),
- `azd provision --preview` (ARM what-if reconciliation),
- a deployed-state posture audit, and
- a single smoke inference call (`FR-029`, `SC-003`, `US5`).

All four are encoded as explicit verification tasks in **Phase 7**.

**Organisation**: For an IaC feature whose five user stories are aspects of one deployment artefact (`US1` build, `US2` teardown, `US3` re-run, `US4` AVM-first review, `US5` validation), tasks are grouped by **architectural phase** (Bootstrap → Shared → WE Agent Plane → SC Model Plane → Cross-region Wiring → Foundry Connection → Verification → Documentation polish) per the plan's Phase-2 task-generation strategy. Each task cross-links the FR / SC / US / research item it implements.

## Format: `[ID] [P?] Description`

- **`[P]`**: Can run in parallel with sibling tasks in the same phase — different files, no dependencies on incomplete sibling tasks. Cross-phase parallelism is governed by the `Depends on:` line on each task.
- **`Depends on:`**: Explicit upstream task IDs. The full dependency graph is summarised in *Dependencies & Execution Order* below.
- **`Implements:`**: Spec requirement (`FR-NNN`), success criterion (`SC-NNN`), user story (`US1`…`US5`), and/or research item (`R-NN`) traceback. Every task has at least one entry.
- **`AVM`**: When applicable, the AVM module reference with **exact pinned version** (e.g. `br/public:avm/res/network/virtual-network:0.9.0`). Pins resolved against the live `mcr.microsoft.com/bicep/avm/...` registry at `/speckit.tasks` time — see `research.md` *Tasks-time addendum*.
- **`Acceptance`**: Concrete, verifiable exit criterion. Vague tasks are forbidden by the constitution (Principle IV).

## Path Conventions

Per `plan.md` § Project Structure (binding):

- **`azure.yaml`** — repository root.
- **`infra/main.bicep`** — `targetScope = 'subscription'`.
- **`infra/main.parameters.json`** — `${env:...}` bindings to `azd` env vars.
- **`infra/modules/we-agent-plane.bicep`** — WE stack.
- **`infra/modules/sc-model-plane.bicep`** — SC stack.
- **`infra/modules/wiring.bicep`** — cross-region wiring.
- **`infra/policies/*.xml`** — APIM policy XML (loaded via `loadTextContent`).
- **`hooks/`** — `azd` lifecycle hooks (only the posture-audit + smoke hook; no Foundry-connection hook is needed — see `R-A1` / R-06 closure).

---

## Phase 1: Bootstrap (project skeleton)

**Purpose**: Lay down the `azd` project scaffold, parameter wiring, gitignore, and the static APIM-policy assets. No Azure resources are declared yet.

- [ ] **T-001** Register required Azure resource providers on the target subscription. Add a one-line manual step **and** an idempotent `az provider register --namespace …` invocation block in `quickstart.md` (the IaC itself does not register providers; that is operator scope). Providers: `Microsoft.CognitiveServices`, `Microsoft.ApiManagement`, `Microsoft.Network`, `Microsoft.App`, `Microsoft.DocumentDB`, `Microsoft.Search`, `Microsoft.Storage`, `Microsoft.OperationalInsights` (only if BYO LAW is wired), `Microsoft.Authorization` (RBAC operations).
  Files: `specs/001-private-foundry-iac/quickstart.md`.
  Acceptance: `az provider list --query "[?registrationState=='Registered'].namespace"` on a fresh subscription includes every listed namespace; `quickstart.md` documents the command.
  Depends on: —
  Implements: FR-001; SC-001; US1; R-A1.

- [X] **T-002** [P] Create `azure.yaml` at repository root with `name: private-foundry-iac`, `metadata.template`, and the postprovision hook reference (used in Phase 7). No services block (this is pure IaC; no application is deployed by `azd`).
  Files: `azure.yaml`.
  Acceptance: `azd env new <tmpname> && azd config show` resolves without error; `azd up --preview` (without parameters set) prompts for the required env vars from `contracts/parameters.schema.json`.
  Depends on: —
  Implements: FR-001, FR-002, FR-025; SC-001; US1, US2.

- [X] **T-003** [P] Create `infra/` directory skeleton with empty placeholder files (`main.bicep`, `main.parameters.json`, `modules/.gitkeep`, `policies/.gitkeep`). Add `.gitignore` entries for `.azure/` and any AVM module cache.
  Files: `infra/`, `.gitignore`.
  Acceptance: `git status` is clean after `azd env new test && azd env set FOO bar`; `.azure/` is not staged.
  Depends on: —
  Implements: US1; § Project Structure (plan).

- [X] **T-004** Author `infra/main.parameters.json` binding every property from `contracts/parameters.schema.json` to a `${env:VAR}` reference (per the schema's `description` lines: `AZURE_SUBSCRIPTION_ID`, `AZURE_ENV_NAME`, `REGION_PAIR`, `NAME_PREFIX`, `WE_VNET_CIDR`, `AGENT_SUBNET_CIDR`, `AGENT_PE_SUBNET_CIDR`, `SC_VNET_CIDR`, `APIM_OUTBOUND_SUBNET_CIDR`, `SC_PE_SUBNET_CIDR`, `APIM_SKU`, `APIM_CAPACITY`, `MODEL_DEPLOYMENTS` — JSON-encoded, `URL_PATH_STYLE`, `ENABLE_SEMANTIC_CACHE`, `ENABLE_DYNAMIC_DISCOVERY`, `DEVELOPER_PORTAL_EXPOSURE`, `EXISTING_PRIVATE_DNS_ZONE_IDS` — JSON-encoded, `LOG_ANALYTICS_WORKSPACE_ID`, `ENABLE_SMOKE_VALIDATION`).
  Files: `infra/main.parameters.json`.
  Acceptance: `azd env set` for each variable then `az deployment sub validate --template-file infra/main.bicep --parameters infra/main.parameters.json` reports parameter-resolution success (after T-006/T-007). Standalone JSON validates against `https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json`.
  Depends on: T-003
  Implements: FR-025, FR-026; SC-001; US1, US3.

- [X] **T-005** [P] Author APIM policy XML files: `infra/policies/inbound.xml` (containing `validate-azure-ad-token`, `llm-token-limit`, `set-backend-service` — always-on policies in the inbound stack, in the order defined by `FR-016`), `infra/policies/backend.xml` (containing `authentication-managed-identity` against `https://cognitiveservices.azure.com` — always-on policy), `infra/policies/inbound-cache.xml` (containing only `llm-semantic-cache-lookup` — optional fragment), `infra/policies/backend-cache.xml` (containing only `llm-semantic-cache-store` — optional fragment). Use placeholder tokens (e.g. `{{AUDIENCE}}`, `{{BACKEND_URL}}`) where Bicep parameters must be substituted at composition time.
  Files: `infra/policies/inbound.xml`, `infra/policies/backend.xml`, `infra/policies/inbound-cache.xml`, `infra/policies/backend-cache.xml`.
  Acceptance: `xmllint --noout infra/policies/*.xml` passes; `infra/policies/inbound.xml` lists exactly the **three always-on** inbound policy elements (`validate-azure-ad-token`, `llm-token-limit`, `set-backend-service`) in the order called out by `FR-016` (the optional fourth element, `llm-semantic-cache-lookup`, lives in `infra/policies/inbound-cache.xml` and is composed in at T-027 when `enableSemanticCache = true`); each cache fragment contains exactly one policy element.
  Depends on: T-003
  Implements: FR-016, FR-024; SC-008; US1; R-05, R-09.

---

## Phase 2: Shared (subscription-scope `main.bicep`)

**Purpose**: Author the subscription-scoped entry point — parameter contract, cross-property validation, the two regional resource groups, and the module dispatch. After this phase, `az bicep build` succeeds and the parameter validation gate works, but no in-region modules have yet been authored.

- [X] **T-006** Author `infra/main.bicep` with `targetScope = 'subscription'` and the **parameter block** matching every property of `contracts/parameters.schema.json`, including `@allowed`, `@minLength`/`@maxLength`, `@minValue`/`@maxValue` decorators and per-parameter `@description`s. Declare typed `param modelDeployments` array shape inline (Bicep user-defined type) reflecting the `items` schema.
  Files: `infra/main.bicep`.
  Acceptance: `az bicep build infra/main.bicep` emits a parameter section whose every name and constraint matches `contracts/parameters.schema.json`.
  Depends on: T-003, T-004
  Implements: FR-025, FR-026; SC-009; US1, US3.

- [X] **T-007** Implement **cross-property parameter validation** in `infra/main.bicep` per `parameters.schema.json` § `$defs.validationNotes`: region-pair-to-resource-location pinning, CIDR containment (WE VNet contains agent + agent-PE subnets; SC VNet contains APIM-outbound + SC-PE subnets), no overlap between agent + agent-PE subnets, no overlap between WE-VNet CIDR and SC-VNet CIDR, agent subnet prefix length ≤ 27, all CIDRs RFC1918, `modelDeployments` non-empty. Failures MUST throw before any resource is created.
  Files: `infra/main.bicep`.
  Acceptance: `azd provision --preview` with a deliberately bad value for any validated parameter fails fast with a message naming the offending parameter and constraint, and no resource is queued for create/update.
  Depends on: T-006
  Implements: FR-007, FR-015, FR-026; SC-009; US1; R-04, R-10. Edge cases (this task): "Unsupported APIM SKU", "Region mismatch", "Unsupported region pair", "Agent subnet sizing". Edge cases delegated to the Azure platform's own validation (no Bicep precondition authored — surfaced via the error message): "Private DNS zone conflict on link" (returned by `Microsoft.Network/privateDnsZones/virtualNetworkLinks` when a name collision exists), "Subnet delegation conflict" (returned by `Microsoft.Network/virtualNetworks/subnets` when an incompatible delegation is reused), and "Capability host immutability" (returned by `Microsoft.App/environments` when the agent subnet has already been bound to a different Foundry account).

- [X] **T-008** Add the **two resource groups** to `infra/main.bicep`: `${namePrefix}-${azdEnvironmentName}-agent-${agentRegionShort}-rg` in the agent region (WE or EUS2 per `regionPair`) and `${namePrefix}-${azdEnvironmentName}-model-sc-rg` in `swedencentral`. Stamp solution-wide tags (`azd-env-name`, `iac-feature = 001-private-foundry-iac`, `created-by = azd`, `solution-version` derived from a `param solutionVersion`).
  Files: `infra/main.bicep`.
  Acceptance: `az deployment sub what-if --template-file infra/main.bicep --parameters …` lists exactly two RG creates in the expected regions on a clean subscription; second run shows `NoChange` for both.
  Depends on: T-007
  Implements: FR-001, FR-002, FR-005, FR-010; SC-001, SC-004; US1, US2, US3.

- [X] **T-009** Wire the **module-dispatch** layer in `infra/main.bicep`: instantiate `we-agent-plane.bicep` (RG-scope into the WE RG), `sc-model-plane.bicep` (RG-scope into the SC RG), and `wiring.bicep` (mixed-scope, fed by outputs from the first two). Define the input contract for each module: WE module takes VNet/subnet CIDRs, `namePrefix`, `agentRegion`, BYO-DNS map; SC module takes SC CIDRs, `apimSku`/`apimCapacity`, `modelDeployments`, `enableSemanticCache`, BYO-DNS map; wiring module takes APIM service ID, APIM principal ID, SC Foundry account ID, WE project ID, WE project principal ID, WE data-plane resource IDs, `urlPathStyle`, `enableDynamicDiscovery`, model-deployments list. Output stubs match `contracts/outputs.schema.json`.
  Files: `infra/main.bicep`.
  Acceptance: `az bicep build infra/main.bicep` compiles clean with zero warnings (Phase-2 placeholder modules can be empty Bicep files at this point). Output declarations match every key in `contracts/outputs.schema.json`.
  Depends on: T-008
  Implements: FR-001; SC-001, SC-007; US1, US4.

---

## Phase 3: WE Agent Plane (`infra/modules/we-agent-plane.bicep`)

**Purpose**: Provision everything that lives in the agent region — VNet + two subnets, the Foundry account and its project, the BYO data plane (Cosmos / AI Search / Storage), all private endpoints, all private DNS zones (or links to BYO zones), and the cross-region APIM inbound PE NIC. Output everything `wiring.bicep` needs (the WE Foundry project resource ID, its system-assigned principal ID, the WE data-plane resource IDs, the APIM inbound PE ID).

- [X] **T-010** Author module shell for `infra/modules/we-agent-plane.bicep`: parameter block matching the `main.bicep` dispatch contract, output block matching the wiring-input contract, an internal `var` block for naming and for the BYO-vs-create-new DNS decision.
  Files: `infra/modules/we-agent-plane.bicep`.
  Acceptance: `az bicep build infra/modules/we-agent-plane.bicep` compiles clean with zero resources declared yet.
  Depends on: T-009
  Implements: FR-005; SC-001; US1.

- [X] **T-011** [P] Add the **WE VNet + two subnets** via AVM. The agent subnet (default `10.40.0.0/24`, ≤ `/27`) MUST be delegated to `Microsoft.App/environments`; the agent PE subnet (default `10.40.1.0/27`) has no delegation.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/network/virtual-network:0.9.0` (Microsoft.Network/virtualNetworks@2025-05-01; supports `subnets[]` with `delegation` and `privateEndpointNetworkPolicies`).
  Acceptance: post-deploy, `az network vnet show` reports two subnets with the right CIDRs; `az network vnet subnet show` on the agent subnet reports `delegations[0].serviceName = Microsoft.App/environments`; idempotent re-run reports no change.
  Depends on: T-010
  Implements: FR-006, FR-013; SC-001, SC-004; US1, US3; R-04.

- [X] **T-012** [P] Add the **7 WE private DNS zones** (`privatelink.services.ai.azure.com`, `…openai.azure.com`, `…cognitiveservices.azure.com`, `…search.windows.net`, `…blob.core.windows.net`, `…documents.azure.com`, `…azure-api.net`) and their VNet links to the agent VNet via AVM. When the operator passes a zone ID through `existingPrivateDnsZoneIds`, **skip** the zone creation for that name and instead author only a VNet link as a child of the BYO zone (handled by a small native `Microsoft.Network/privateDnsZones/virtualNetworkLinks` block — the AVM module's VNet-link sub-resource targets the AVM-owned zone, so BYO mode requires the native link).
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/network/private-dns-zone:0.8.1` (privateDnsZones + virtualNetworkLinks@2024-06-01; `virtualNetworkLinks[]` first-class param).
  Acceptance: `az network private-dns zone list -g <agent-rg>` lists exactly seven zones in create-new mode; in BYO mode lists zero zones in the agent RG but `az network private-dns link vnet list -z <byo-zone>` shows the link to the WE VNet. `azd down` removes only the zones the solution created.
  Depends on: T-011
  Implements: FR-018, FR-020, FR-021; SC-002, SC-005; US1, US2; R-07.

- [X] **T-013** Add the **agent-region Foundry / Cognitive Services account** via AVM. `kind = AIServices`, `publicNetworkAccess = Disabled`, **system-assigned MI on the account** (not strictly required by the agent runtime, but ships diagnostics-ready), `allowProjectManagement = true`, `customSubDomainName` from the naming convention. Network ACLs left empty (PE-only access).
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/cognitive-services/account:0.14.2` (Microsoft.CognitiveServices/accounts@2025-06-01; `allowProjectManagement` param confirmed; `managedIdentities.systemAssigned` confirmed).
  Acceptance: post-deploy, `az cognitiveservices account show` reports `publicNetworkAccess = Disabled`, identity.type contains `SystemAssigned`, and `properties.allowProjectManagement = true`.
  Depends on: T-010
  Implements: FR-005, FR-023; SC-002; US1, US4; R-01, R-A1.

- [X] **T-014** Add the **WE Foundry project** as a **native** resource on the account (`Microsoft.CognitiveServices/accounts/projects@2025-06-01`) — documented AVM gap. Enable **system-assigned managed identity on the project**; this is the principal that APIM's `validate-azure-ad-token` policy validates. Output the project resource ID and `identity.principalId`.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: NONE (gap; native `Microsoft.CognitiveServices/accounts/projects@2025-06-01`). Inline justification: "AVM `cognitive-services/account@0.14.2` exposes `allowProjectManagement` but does not author `Microsoft.CognitiveServices/accounts/projects` children. Native fallback per research R-01 / Tasks-time addendum R-A1."
  Acceptance: `az resource show --resource-type Microsoft.CognitiveServices/accounts/projects` on the WE account returns the project with `identity.type` containing `SystemAssigned`; `identity.principalId` is exposed as a module output.
  Depends on: T-013
  Implements: FR-005, FR-009, FR-022; SC-001, SC-007; US1, US4; R-01, R-06, R-A1.

- [X] **T-015** [P] Add the **Cosmos DB account** (BYO data plane) via AVM. `publicNetworkAccess = Disabled`, NoSQL API by default, no firewall rules; expose `databaseAccountResourceId` as an output.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/document-db/database-account:0.19.0`.
  Acceptance: post-deploy, `az cosmosdb show` reports `publicNetworkAccess = Disabled`, `isVirtualNetworkFilterEnabled = false` (PE-only).
  Depends on: T-011
  Implements: FR-008, FR-023; SC-002; US1, US4.

- [X] **T-016** [P] Add the **AI Search service** (BYO data plane) via AVM. `publicNetworkAccess = Disabled`, `authOptions.aadOrApiKey` with `aadAuthFailureMode = http401WithBearerChallenge`, capacity `1`, partitionCount `1`. Output its resource ID.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/search/search-service:0.12.1`.
  Acceptance: post-deploy, `az search service show` reports `publicNetworkAccess = Disabled`.
  Depends on: T-011
  Implements: FR-008, FR-023; SC-002; US1, US4.

- [X] **T-017** [P] Add the **Storage account** (BYO data plane) via AVM. `publicNetworkAccess = Disabled`, `allowBlobPublicAccess = false`, `allowSharedKeyAccess = false` (force AAD), `minimumTlsVersion = TLS1_2`, default-action `Deny` on network ACLs. Output its resource ID.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/storage/storage-account:0.32.0`.
  Acceptance: post-deploy, `az storage account show` reports `publicNetworkAccess = Disabled`, `allowBlobPublicAccess = false`, `allowSharedKeyAccess = false`.
  Depends on: T-011
  Implements: FR-008, FR-023, FR-024; SC-002, SC-008; US1, US4.

- [X] **T-018** Add the **PE for the WE Foundry account** in the agent PE subnet, with a DNS zone group that binds the three Foundry-side zones (`…services.ai.azure.com`, `…openai.azure.com`, `…cognitiveservices.azure.com`). `groupIds: [ 'account' ]`.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/network/private-endpoint:0.12.1` (Microsoft.Network/privateEndpoints@2025-05-01; supports `privateDnsZoneGroup`).
  Acceptance: post-deploy, `az network private-endpoint show` reports `privateLinkServiceConnections[0].privateLinkServiceId` is the WE Foundry account; the NIC's IP is inside the agent PE subnet; `az network private-endpoint dns-zone-group list` shows three zone bindings.
  Depends on: T-011, T-012, T-013
  Implements: FR-005, FR-018, FR-023; SC-002, SC-003; US1; R-A1.

- [X] **T-019** [P] Add the **three PEs for the BYO data plane** in the agent PE subnet via AVM: PE for Cosmos (`groupIds: [ 'Sql' ]`, zone `…documents.azure.com`), PE for AI Search (`groupIds: [ 'searchService' ]`, zone `…search.windows.net`), PE for Storage (`groupIds: [ 'blob' ]`, zone `…blob.core.windows.net`). Each PE binds its single zone via `privateDnsZoneGroup`.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/network/private-endpoint:0.12.1` (three instances, one per data-plane resource).
  Acceptance: `az network private-endpoint list -g <agent-rg>` returns four PEs total (one for Foundry from T-018 + three here); each reports its corresponding `groupIds` and one DNS zone binding.
  Depends on: T-011, T-012, T-015, T-016, T-017
  Implements: FR-008, FR-018, FR-023; SC-002, SC-003; US1; R-A1.

- [X] **T-020** Add the **cross-region APIM inbound PE** in the WE agent PE subnet, targeting the APIM service ID emitted by `sc-model-plane.bicep` (passed in as a module input). PE `location = <agentRegion>` (WE or EUS2 — *different from* the APIM service's `swedencentral`). `groupIds: [ 'Gateway' ]`. DNS zone group binds `privatelink.azure-api.net` (W-Z7) linked to the agent VNet. Output the PE resource ID and the APIM private gateway hostname.
  Files: `infra/modules/we-agent-plane.bicep`.
  AVM: `br/public:avm/res/network/private-endpoint:0.12.1`. Fallback to native `Microsoft.Network/privateEndpoints@2025-05-01` only if the AVM module rejects the cross-region location/target combination (research R-03 marks this as platform-supported; AVM module property surface is open).
  Acceptance: post-deploy, `az network private-endpoint show` reports `location = westeurope` (or `eastus2`), `privateLinkServiceConnections[0].privateLinkServiceId` resolves to an APIM service in `swedencentral`. From inside the WE VNet, `nslookup <apim-gateway-hostname>` resolves to the PE NIC's private IP (not a public IP).
  Depends on: T-011, T-012, T-026
  Implements: FR-014, FR-018; SC-002, SC-003; US1; R-03, R-A1.

---

## Phase 4: SC Model Plane (`infra/modules/sc-model-plane.bicep`)

**Purpose**: Provision the Sweden Central model plane — VNet + two subnets, the SC Foundry/AOAI account + its model deployments, the SC account PE, the SC private DNS zones, the APIM Std-v2 (or Prem-v2) service with outbound VNet integration + system-assigned MI + the GenAI policy stack.

- [X] **T-021** Author module shell for `infra/modules/sc-model-plane.bicep`: parameter block matching the `main.bicep` dispatch contract; output block exposing the SC Foundry account ID, the APIM service ID, the APIM system-assigned principal ID, and the APIM private gateway hostname.
  Files: `infra/modules/sc-model-plane.bicep`.
  Acceptance: `az bicep build infra/modules/sc-model-plane.bicep` compiles clean with zero resources declared yet.
  Depends on: T-009
  Implements: FR-010; SC-001; US1.

- [X] **T-022** [P] Add the **SC VNet + two subnets** via AVM. The APIM-outbound subnet (default `10.50.0.0/27`) is reserved for APIM Standard v2 / Premium v2 outbound NICs. **Subnet delegation watchpoint (R-A1 / R-02)**: at the time of probing, Microsoft Learn is ambiguous on whether APIM v2's outbound integration requires a *named* subnet delegation (e.g. `Microsoft.Web/hostingEnvironments` is *not* it — that is App Service Environment), or simply an empty reserved subnet driven by the APIM service's `virtualNetworkConfiguration.subnetResourceId`. T-022 starts with **no delegation** on the outbound subnet; if `azd provision --preview` against the AVM-authored APIM service (T-026) raises a delegation-required error, add a thin native augment to set the correct delegation name (confirmed from the Azure error message). The SC PE subnet (default `10.50.1.0/27`) has no delegation. SC VNet is NOT peered to the WE VNet (`FR-013`).
  Files: `infra/modules/sc-model-plane.bicep`.
  AVM: `br/public:avm/res/network/virtual-network:0.9.0`.
  Acceptance: post-deploy, `az network vnet show` reports the two subnets with the right CIDRs and no peering to the WE VNet.
  Depends on: T-021
  Implements: FR-011, FR-013; SC-001; US1; R-A1.

- [X] **T-023** [P] Add the **3 SC private DNS zones** (`privatelink.openai.azure.com`, `…services.ai.azure.com`, `…cognitiveservices.azure.com`) and their VNet links to the SC VNet via AVM. **The SC DNS plane is independent from the WE DNS plane** (`FR-020`) — zones live in the SC resource group and are linked only to the SC VNet. BYO-DNS mode follows the same shape as T-012.
  Files: `infra/modules/sc-model-plane.bicep`.
  AVM: `br/public:avm/res/network/private-dns-zone:0.8.1`.
  Acceptance: `az network private-dns zone list -g <model-rg>` lists exactly three zones (or zero in BYO mode); none of them is linked to the WE VNet.
  Depends on: T-022
  Implements: FR-019, FR-020, FR-021; SC-002, SC-005; US1, US2; R-07.

- [X] **T-024** Add the **SC Foundry / AOAI model account** via AVM. `kind = AIServices` (or `OpenAI` per the model SKUs in `MODEL_DEPLOYMENTS`), `publicNetworkAccess = Disabled`, `customSubDomainName` derived from naming. Author the **model deployments** via the AVM module's `deployments[]` param (one entry per `modelDeployments[]` element from the parameter contract: `name`, `model.name`+`model.version`, `sku.name`+`sku.capacity`). Output the SC account resource ID and the array of deployment names.
  Files: `infra/modules/sc-model-plane.bicep`.
  AVM: `br/public:avm/res/cognitive-services/account:0.14.2` (Microsoft.CognitiveServices/accounts@2025-06-01 + accounts/deployments@2025-06-01; `deployments[]` param confirmed).
  Acceptance: `az cognitiveservices account show` reports `publicNetworkAccess = Disabled`; `az cognitiveservices account deployment list` returns the configured deployments. Module output `modelDeploymentNames` (array of created deployment names) is wired back to `main.bicep` outputs so the operator contract (`contracts/outputs.schema.json`) is satisfied.
  Depends on: T-021
  Implements: FR-010, FR-012, FR-023; SC-002; US1, US3, US4.

- [X] **T-025** Add the **PE for the SC model account** in the SC PE subnet with a DNS zone group binding all three SC zones (`…openai.azure.com`, `…services.ai.azure.com`, `…cognitiveservices.azure.com`). `groupIds: [ 'account' ]`.
  Files: `infra/modules/sc-model-plane.bicep`.
  AVM: `br/public:avm/res/network/private-endpoint:0.12.1`.
  Acceptance: post-deploy, the PE is in the SC PE subnet; DNS resolution of the SC account's hostname from inside the SC VNet returns the PE NIC's private IP.
  Depends on: T-022, T-023, T-024
  Implements: FR-010, FR-019, FR-023; SC-002, SC-003; US1.

- [X] **T-026** Add the **APIM service** via AVM. `sku = StandardV2` (default) or `PremiumV2` per parameter; `skuCapacity = apimCapacity`; **system-assigned MI** (`managedIdentities = { systemAssigned: true }`); outbound VNet integration into the APIM-outbound subnet (set `subnetResourceId` and `virtualNetworkType` per the v2 property surface confirmed in `R-A1`); **`publicNetworkAccess = Disabled`**; `enableDeveloperPortal = false` (developer portal disabled per `developerPortalExposure = 'disabled'`); no gateway PE created via the AVM `privateEndpoints[]` param here (the cross-region PE is authored in the WE module, T-020). Output `apimServiceId`, `apimPrincipalId`, and the private gateway hostname.
  Files: `infra/modules/sc-model-plane.bicep`.
  AVM: `br/public:avm/res/api-management/service:0.14.1` (Microsoft.ApiManagement/service@2024-05-01; `StandardV2`/`PremiumV2` allowed in `sku`; `publicNetworkAccess` first-class; outbound VNet integration via `subnetResourceId` + `virtualNetworkType` documented for v2 SKUs in `R-A1`).
  Acceptance: `az apim show` reports `sku.name = StandardV2`, `publicNetworkAccess = Disabled`, `identity.type = SystemAssigned`, `virtualNetworkConfiguration.subnetResourceId = <SC APIM-outbound subnet>`; the developer portal is disabled.
  Depends on: T-022
  Implements: FR-014, FR-015, FR-017, FR-023; SC-001, SC-002, SC-009; US1; R-02, R-A1.

- [X] **T-027** Author the **APIM policy resource** on the service (`Microsoft.ApiManagement/service/policies@2024-05-01` as a child of the AVM-authored APIM service, or via the AVM module's `policies` sub-resource if exposed). Assemble the policy XML by `loadTextContent('./policies/inbound.xml')` + (when `enableSemanticCache = true`) `loadTextContent('./policies/inbound-cache.xml')` + the backend stack from `backend.xml` (and `backend-cache.xml` when the toggle is on). Substitute placeholder tokens (`{{AUDIENCE}}`, `{{BACKEND_URL}}`, `{{APIM_PRINCIPAL_AUDIENCE}}`) via Bicep `replace()`.
  Files: `infra/modules/sc-model-plane.bicep`, `infra/policies/inbound.xml`, `infra/policies/backend.xml`, `infra/policies/inbound-cache.xml`, `infra/policies/backend-cache.xml`.
  Acceptance: `az apim policy show --service-name <…> --policy-id policy` returns XML that contains `validate-azure-ad-token`, `llm-token-limit`, `set-backend-service`, `authentication-managed-identity` in the prescribed order; the `<llm-semantic-cache-lookup>`/`<llm-semantic-cache-store>` elements are present iff `enableSemanticCache = true`.
  Depends on: T-005, T-026
  Implements: FR-016, FR-024; SC-008; US1; R-05, R-09.

---

## Phase 5: Cross-region Wiring (`infra/modules/wiring.bicep`) — RBAC only

**Purpose**: All **role assignments** that depend on the principal IDs of the two system-assigned MIs (WE Foundry project MI from T-014; APIM MI from T-026). No Foundry connection here — that is Phase 6, after roles exist.

- [X] **T-028** Author module shell for `infra/modules/wiring.bicep` (the module is instantiated at subscription scope from `main.bicep` so that it can target both resource groups; individual role-assignment AVM module calls are scoped per resource). Inputs: APIM principal ID, SC Foundry account ID, WE project principal ID, WE data-plane resource IDs.
  Files: `infra/modules/wiring.bicep`.
  Acceptance: `az bicep build infra/modules/wiring.bicep` compiles clean.
  Depends on: T-009
  Implements: FR-009, FR-017; US1.

- [X] **T-029** Add the **role assignment: APIM MI → `Cognitive Services OpenAI User` on the SC Foundry account** (role definition ID **`5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`** — *Cognitive Services OpenAI User*; verified against the Azure built-in role index and cross-checked with `data-model.md` X-3). This is what makes APIM's `authentication-managed-identity` policy succeed on the backend hop. **Do NOT use `a97b65f3-24c7-4388-baec-2e87135dc908` — that GUID is the `Cognitive Services User` role (read + list-keys only) and would cause every backend hop to return 401/403.**
  Files: `infra/modules/wiring.bicep`.
  AVM: `br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1` (resource-group scope; the assignment targets the SC Foundry account inside the SC RG, scoped via `resourceId` parameter).
  Acceptance: `az role assignment list --assignee <apimPrincipalId> --scope <scFoundryAccountId>` returns one assignment for *Cognitive Services OpenAI User*.
  Depends on: T-024, T-026, T-028
  Implements: FR-017, FR-024; SC-002, SC-008; US1; X-3 in data-model.md.

- [X] **T-030** Add **control-plane role assignments: WE Foundry project MI → BYO data plane** (AI Search + Storage + Cosmos *control* plane only — Cosmos *data* plane is handled separately in T-030a because the AVM `role-assignment/rg-scope` module cannot author the data-plane SQL role). Use the minimum-required role per resource per Microsoft's Foundry Agent Service documentation; concrete role definition IDs pinned at implementation time in inline comments. As a documented starting set: **Cosmos DB (control plane only)**: `DocumentDB Account Contributor` (`5bd9cd88-fe45-4216-938b-f97437e15450`); **AI Search**: `Search Index Data Contributor` (`8ebe5a00-799e-43f5-93ac-243d3dce84a7`) + `Search Service Contributor` (`7ca78c08-252a-4471-8644-bb5ff32d4ba0`); **Storage**: `Storage Blob Data Contributor` (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`).
  Files: `infra/modules/wiring.bicep`.
  AVM: `br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1` (one call per (principal, role, scope) triple; expect 4 assignments total — AI Search × 2, Storage Blob × 1, Cosmos control plane × 1).
  Acceptance: `az role assignment list --assignee <weProjectPrincipalId>` lists exactly the four configured control-plane roles on the three data-plane resources; no extra assignments. Cosmos data-plane access is **NOT** verified here — see T-030a.
  Depends on: T-014, T-015, T-016, T-017, T-028
  Implements: FR-009, FR-024; SC-008; US1; X-4 in data-model.md.

- [X] **T-030a** Add the **Cosmos DB data-plane SQL role assignment** for the WE Foundry project MI as a **native** Bicep resource: `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15`, with `roleDefinitionId` set to the Cosmos DB built-in **Cosmos DB Built-in Data Contributor** role (`00000000-0000-0000-0000-000000000002` — built-in *data-plane* SQL role definition, distinct from Azure RBAC roleDefinitionIds), `principalId = <weProjectPrincipalId>`, and `scope` set to the Cosmos DB account resource ID. **Do NOT attempt this via the AVM `role-assignment/rg-scope` module** — Cosmos data-plane assignments go through a separate type and would silently grant nothing if mapped to `Microsoft.Authorization/roleAssignments`.
  Files: `infra/modules/wiring.bicep`.
  AVM: NONE (gap; native `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15`). Inline justification: "AVM gap — `document-db/database-account@0.19.0` exposes the account but no AVM module currently authors data-plane SQL role assignments. Native fallback per Tasks-time risks; cross-referenced from `data-model.md` X-4."
  Acceptance: `az cosmosdb sql role assignment list --account-name <…> --resource-group <…>` returns exactly one assignment whose `principalId` matches the WE project MI's principal ID and whose `roleDefinitionId` ends with `/00000000-0000-0000-0000-000000000002`. A subsequent runtime call from the agent (T-037 smoke) successfully reads from / writes to the agent thread / message containers in Cosmos.
  Depends on: T-014, T-015, T-028
  Implements: FR-009, FR-024; SC-003, SC-008; US1; X-4 in data-model.md (Cosmos data-plane row).

- [X] **T-030b** Author **diagnostic settings** on the solution-managed resources, gated on `logAnalyticsWorkspaceId` being non-empty (per `R-08`). When the parameter is set, declare a single `Microsoft.Insights/diagnosticSettings@2021-05-01-preview` per supported resource (APIM, WE Foundry account, SC Foundry / AOAI account, Cosmos, AI Search, Storage) targeting the supplied workspace, enabling the resource's standard log + metric categories. When the parameter is unset, **no** diagnostic-settings resources are created. The IaC does not provision a workspace, never sizes one, never sets retention, never authors dashboards or alert rules (per spec § Assumptions).
  Files: `infra/modules/we-agent-plane.bicep`, `infra/modules/sc-model-plane.bicep`, `infra/modules/wiring.bicep` (whichever module owns each resource — declare diagnostic settings co-located with the resource it targets).
  AVM: Use the AVM module's first-class `diagnosticSettings[]` parameter if exposed by the resource's AVM module (most `0.x` AVM modules expose this consistently); otherwise author the native `Microsoft.Insights/diagnosticSettings@2021-05-01-preview` block. Document the choice per resource inline.
  Acceptance: With `logAnalyticsWorkspaceId` set to a valid LAW resource ID, `az monitor diagnostic-settings list --resource <each managed resource>` returns exactly one setting per resource pointing at that workspace. With the parameter unset (or empty string), the same command returns zero settings on every managed resource. The audit hook (T-036) re-asserts the same posture.
  Depends on: T-014, T-024, T-026, T-015, T-016, T-017, T-028
  Implements: FR-029; SC-002, SC-005; US5; R-08.

---

## Phase 6: Foundry Connection (Bicep-native; documented hook fallback)

**Purpose**: Author the WE Foundry project's admin-connected model of type `Azure API Management` so that the agent runtime can reach the SC model deployments via APIM. **R-06 is RESOLVED to Bicep-native** in `R-A1` (the 2025-06-01 type definition for `Microsoft.CognitiveServices/accounts/projects/connections` confirms `authType=AAD`, `target`, `category`, `metadata` are all authorable). The `azd` postprovision hook fallback is documented but not implemented unless the Bicep path fails at deploy time.

- [X] **T-031** Author the **Foundry admin-connected model** as a **native** child of the WE project: `Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01`, name e.g. `apim-byom`, **`properties.category = 'ApiManagement'`** (matching `data-model.md` X-5 and the Microsoft Learn "Foundry connections — `ApiManagement` and `ModelGateway` categories" page). The `category` field accepts an open-string union per the 2025-06-01 type definition (R-A1); if Foundry rejects `'ApiManagement'` at deploy time, try `'ModelGateway'` (second-choice fallback) — record the working value in an inline comment. `authType = 'AAD'`, `target = 'https://${apimGatewayHostname}'`, `metadata = { audience: 'https://cognitiveservices.azure.com/', urlPathStyle: <param>, dynamicDiscovery: <param>, deployments: <comma-joined deployment names>, location: 'swedencentral' }`. **No subscription keys**.
  Files: `infra/modules/wiring.bicep` (declared as a child resource of the WE project — the `wiring.bicep` module uses an `existing` reference to the WE project from T-014; alternatively declare in `we-agent-plane.bicep` once `wiring.bicep` outputs are wired back as a re-entrant input, but the simpler shape is to keep all cross-region wiring in `wiring.bicep`).
  AVM: NONE (gap; native `Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01`). Inline justification: "AVM `cognitive-services/account@0.14.2` does not author `accounts/projects/connections` children. Native fallback per research R-01 / R-06 / Tasks-time addendum R-A1 (Bicep-native path RESOLVED)."
  Acceptance: post-deploy, `az rest --method GET --url '<scope>/connections/apim-byom?api-version=2025-06-01'` returns `properties.authType = AAD`, `properties.target` matching the APIM private gateway URL, `properties.metadata.audience = https://cognitiveservices.azure.com/`. From the Foundry portal, the WE project's *Connected Resources* view lists the APIM connection with the configured deployments.
  Depends on: T-014, T-026, T-029, T-020, T-012
  Implements: FR-022, FR-024; SC-001, SC-003, SC-008; US1; R-01, R-06, R-A1; X-5 in data-model.md.

- [X] **T-032** (Documented fallback only — DO NOT IMPLEMENT unless T-031 fails at deploy time.) Sketch a `hooks/postprovision-connection.sh` that uses `az rest --method PUT` against the connections endpoint with the same payload as T-031, plus a matching `hooks/predown-connection.sh` for clean teardown (`FR-002`). Both scripts MUST be idempotent (`If-Match: *` / "create or replace") and MUST source the APIM gateway hostname + WE project ID from `azd env get-values`.
  Files: `hooks/postprovision-connection.sh.template`, `hooks/predown-connection.sh.template`, `azure.yaml` (hooks block — commented out by default).
  AVM: N/A.
  Acceptance: Templates exist but are **disabled by default** (`azure.yaml` hooks block commented out, `.template` suffix on the script files). Documentation in `quickstart.md` § Troubleshooting explains when to enable the fallback. T-032 is **CLOSED with NO-OP** unless T-031's acceptance fails — in which case T-032 is re-opened and the connection is moved to the hook.
  Depends on: T-031
  Implements: FR-002, FR-022; US1, US2; R-06 fallback path.

---

## Phase 7: Verification & Smoke

**Purpose**: The functional test suite for this IaC feature. These tasks gate "DONE".

- [X] **T-033** **Compile-time verification**: `az bicep build infra/main.bicep` MUST emit zero warnings and zero errors. Run `az bicep lint infra/main.bicep` — every warning either fixed or suppressed with an inline `#disable-next-line <rule-id>` comment carrying a one-line justification.
  Files: (CI script `scripts/verify-bicep.sh` — optional helper).
  Acceptance: Both commands exit 0 against a clean checkout.
  Depends on: T-005, T-009, T-011..T-020, T-022..T-027, T-028..T-031, T-030a, T-030b
  Implements: FR-026; SC-001; US1, US4; Principle II / IV.

- [X] **T-034** **What-if verification (`azd provision --preview`)**: from a clean `azd` environment (`azd env new <env>` + every required env var set), run `azd provision --preview`. The output MUST list ~30–40 resource creates across the two RGs (matching the count in `plan.md` § Scale/Scope), zero deletes, zero "ignored" / "unsupported" resources. Capture the what-if JSON for review.
  Files: `quickstart.md` (document the command), optionally `scripts/whatif.sh`.
  Acceptance: `azd provision --preview` exits 0; the resource-change list matches `data-model.md` row-for-row (every W-*, C-*, X-* numbered resource appears exactly once).
  Depends on: T-033
  Implements: FR-001, FR-003; SC-001; US1, US3.

- [X] **T-035** **Idempotency check**: after a successful `azd up`, immediately re-run `azd up` with no parameter changes; the output MUST report zero material resource changes (every resource shows `NoChange` in the deployment summary). Re-run `azd provision --preview` as well — same expectation.
  Files: `quickstart.md` (smoke-test recipe).
  Acceptance: Second `azd up` deployment summary contains `Resource changes: 0 created, 0 updated, 0 deleted` (or AVM-telemetry-only noise, which is filtered).
  Depends on: T-034
  Implements: FR-003; SC-004; US3.

- [X] **T-035a** **Partial-failure recovery check** (FR-004): deliberately abort an `azd up` mid-run (e.g. send SIGINT after T-026 has reported success on the SC APIM service but before T-031 authors the Foundry connection — leaving the deployment in a partially-applied state), then immediately re-run `azd up` with no parameter changes. The second run MUST reconcile the partial state to the target topology without any manual cleanup (no `az resource delete`, no resource-group purge, no `azd env refresh` workaround). On the second run's deployment summary, every resource MUST report either `NoChange` (already-converged) or `Update`/`Create` (for resources that were not yet authored on the aborted first run) — never `Failed`. After the second run completes, the T-036 posture audit MUST pass.
  Files: `quickstart.md` § Troubleshooting (document the abort-and-resume recipe), optionally `scripts/abort-and-resume.sh`.
  Acceptance: Aborted `azd up` resumes cleanly on the next invocation. The combined `created + updated` count across both runs equals the count from a single clean `azd up` of an empty subscription (i.e. no resource is created twice). T-036 audit exits 0 after the resume.
  Depends on: T-035
  Implements: **FR-004**; SC-004; US3. Edge cases: "Partial failure redeploy".

- [X] **T-035b** **Region-pair switching verification** (SC-006): bring up a *second* `azd` environment (`azd env new <env>-eus2`) with `REGION_PAIR=eastus2+swedencentral` (every other parameter held constant or appropriately renamed). Run `azd up`, then re-run the T-036 posture audit and the T-037 smoke call against the new environment. The audit MUST pass identically to the WE+SC environment; the smoke call MUST return a 2xx response over a fully private path (EUS2 agent VNet ↔ APIM PE in the EUS2 PE subnet ↔ SC APIM ↔ SC PE ↔ SC model deployment). After verification, `azd down` the EUS2 environment and re-run the T-038 teardown probe — it MUST also pass.
  Files: `quickstart.md` § Region-pair switching, optionally `scripts/verify-region-pair-switch.sh`.
  Acceptance: With `REGION_PAIR=eastus2+swedencentral`, the deployed topology matches `data-model.md` row-for-row in the alternate region (agent RG in `eastus2` instead of `westeurope`, same SC RG in `swedencentral`); T-036 audit, T-037 smoke, and T-038 teardown all pass against the EUS2 environment, equivalent to the WE+SC environment.
  Depends on: T-036, T-037, T-038
  Implements: **SC-006**; FR-007, FR-025; US3.

- [X] **T-036** **`azd up` posture audit hook**: author `hooks/postprovision-audit.sh` (referenced from `azure.yaml`) that iterates the provisioned resources by tag (`iac-feature = 001-private-foundry-iac`) and asserts:
  (a) every Foundry / AOAI / Cosmos / AI Search / Storage account reports `publicNetworkAccess = Disabled`;
  (b) the APIM service reports `publicNetworkAccess = Disabled` and the developer portal is disabled;
  (c) every private endpoint NIC has a private IP from the expected subnet;
  (d) no role assignment on solution-managed scopes uses a *user* principal — only the two system-assigned MIs;
  (e) no Azure OpenAI / Foundry / APIM subscription keys have been written into `azd env get-values`.
  The hook exits non-zero on any failure.
  Files: `hooks/postprovision-audit.sh`, `azure.yaml`.
  Acceptance: After a healthy `azd up`, the hook exits 0. Deliberately flipping any one resource's `publicNetworkAccess` to `Enabled` (manual test) causes the hook to exit non-zero on the next `azd up --hooks` invocation.
  Depends on: T-034
  Implements: FR-023, FR-024, FR-029; SC-002, SC-005, SC-008; US5.

- [X] **T-037** **Smoke inference call**: extend `hooks/postprovision-audit.sh` (or author a sibling `hooks/postprovision-smoke.sh`) that, when `ENABLE_SMOKE_VALIDATION = true`, issues a single chat-completion request against one of the configured model deployments through the agent project. The hook MUST run from a context with network reachability to the WE VNet (either a private VM/CI runner inside the VNet, or via `az aks command invoke`-style relay if available); when no private-network context exists, the hook logs a clear "skipped — no private-network context" warning and exits 0 (FR-029 makes the call optional).
  Files: `hooks/postprovision-smoke.sh`, `quickstart.md`.
  Acceptance: When run from a private-network context, the smoke call returns a 2xx response. The packet trace (`tcpdump` on the private VM, or APIM diagnostic logs if a BYO LAW is wired) shows the request traversed APIM and the SC PE; no public IP appears.
  Depends on: T-031, T-036
  Implements: FR-029; SC-003; US5.

- [X] **T-038** **Teardown verification**: after `azd down`, run a probe script that queries the target subscription via `az graph` for any resource carrying the solution's tag (`iac-feature = 001-private-foundry-iac`) and asserts the result is empty; queries the solution-managed private DNS zones (if create-new mode) and asserts they no longer exist; queries `az role assignment list --all` and asserts no remaining role assignments on solution-managed scopes whose principal ID matches one of the deleted system-assigned MIs.
  Files: `scripts/verify-teardown.sh`, `quickstart.md`.
  Acceptance: All three assertions pass after `azd down`. In BYO-DNS mode, the operator-owned zones still exist; the script confirms they remain.
  Depends on: T-035
  Implements: FR-002; SC-005; US2.

---

## Phase 8: Documentation polish

- [X] **T-039** [P] Update `specs/001-private-foundry-iac/quickstart.md` to reflect the final pinned AVM versions, the resolved Foundry-connection authoring path (Bicep-native), and the posture/smoke hook invocations.
  Files: `specs/001-private-foundry-iac/quickstart.md`.
  Acceptance: `quickstart.md` walks an operator from `git clone` to a healthy `azd up` with no missing steps; an external reviewer can follow it without referring back to `plan.md`.
  Depends on: T-037, T-038
  Implements: FR-001; SC-001; US1.

- [X] **T-040** [P] Add inline justification comments at the top of every native-fallback block in `infra/modules/we-agent-plane.bicep` and `infra/modules/wiring.bicep` (for the two `Microsoft.CognitiveServices/accounts/projects` and `…/projects/connections` resources, T-014 and T-031). Each comment names the resource, references `research.md` (R-01 / R-06) and the Tasks-time addendum (R-A1), and lists the AVM module version that would be required to retire the native fallback once coverage exists.
  Files: `infra/modules/we-agent-plane.bicep`, `infra/modules/wiring.bicep`.
  Acceptance: Each native-fallback resource block has a preceding `// AVM gap: …` comment matching the format above. A static review confirms the AVM-coverage ratio in `data-model.md` (target ≥ 80%) is documented inline.
  Depends on: T-014, T-031
  Implements: FR-027, FR-028; SC-007; US4.

---

## Dependencies & Execution Order

### Phase order

```
Phase 1 (Bootstrap)              T-001 (manual), T-002, T-003, T-004, T-005
   │
Phase 2 (Shared `main.bicep`)    T-006 → T-007 → T-008 → T-009
   │
   ├── Phase 3 (WE Agent Plane)  T-010 → T-011 [P] T-012 [P]                      Phase 4 (SC Model Plane) ──── T-021 → T-022 [P] T-023 [P]
   │                                       │                                                                                │
   │                                       ├─ T-013 → T-014                                                                 ├─ T-024 → T-025
   │                                       ├─ T-015 [P], T-016 [P], T-017 [P]                                              └─ T-026 → T-027
   │                                       ├─ T-018 (needs T-013, T-012)
   │                                       ├─ T-019 [P] (needs T-015/16/17 + T-012)
   │                                       └─ T-020 (needs T-026 from Phase 4)
   │
   ├── Phase 5 (Wiring — RBAC + Diag)
   │     T-028 → T-029, T-030 → T-030a (Cosmos data-plane SQL role), T-030b (diagnostic settings, gated on logAnalyticsWorkspaceId)
   │
   ├── Phase 6 (Foundry conn.)   T-031 (needs T-014, T-020, T-026, T-029)
   │                               T-032 (NO-OP fallback — only if T-031 fails)
   │
   ├── Phase 7 (Verification)    T-033 (compile) → T-034 (preview) → T-035 (idempotency) → T-035a (partial-failure recovery)
   │                               T-036 (audit hook) → T-037 (smoke) → T-038 (teardown)
   │                               T-035b (region-pair switching verification — runs after T-036/T-037/T-038)
   │
   └── Phase 8 (Docs)            T-039 [P], T-040 [P]
```

### Cross-region critical edge

`T-020` (WE-side cross-region APIM inbound PE) depends on `T-026` (SC-side APIM service). This is the only edge that crosses between Phase 3 and Phase 4 — the rest of each plane is independent.

`T-031` (Foundry admin-connected model) is the **last** infrastructure task — it depends on everything that supplies its inputs (the project MI, the APIM service, the APIM PE, the role assignments, the WE DNS zones).

### Parallel opportunities

- **Phase 1**: T-002, T-003 are `[P]`; T-005 is `[P]` after T-003.
- **Phase 3 (WE)**: T-011 + T-012 are `[P]` after T-010; T-015 + T-016 + T-017 are `[P]` after T-011; T-019 is `[P]` (a single task that authors three PEs in parallel via array iteration).
- **Phase 4 (SC)**: T-022 + T-023 are `[P]` after T-021. T-024 / T-025 / T-026 / T-027 are sequenced as shown.
- **Phase 3 and Phase 4 run in parallel** end-to-end *except* for the T-020 ← T-026 edge.
- **Phase 7**: T-036 / T-037 / T-038 must run after T-035 but can be drafted in parallel (different scripts; only the order of *execution* against a deployed env is constrained).
- **Phase 8**: T-039 + T-040 are `[P]`.

### MVP scope

The minimum that satisfies **US1** (single-command private deployment) alone is **T-001 through T-031 + T-030a + T-030b + T-033 + T-034**: ~35 tasks. Adding **US2** (teardown verification) needs **T-038**. Adding **US5** (validation hooks) adds **T-036 + T-037**. **US4** (AVM-first review) is satisfied by the inline justification comments authored in **T-040** and the AVM pins recorded throughout. **US3** (idempotency + re-run + region-pair switching) is satisfied by **T-035** (idempotency), **T-035a** (partial-failure recovery, closes FR-004), and **T-035b** (region-pair switching, closes SC-006), plus the parameter validation in **T-007** that accepts the alternate `regionPair`.

---

## Tasks-time risks (logged here per task-generation instructions)

- **AVM `network/private-dns-zone` BYO mode**: The AVM module's `virtualNetworkLinks` sub-resource is authored as a child of the module-owned zone resource. In BYO-DNS mode, the operator-owned zone is not authored by this module; the VNet link MUST therefore be authored as a small native `Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01` block targeting the BYO zone ID. Recorded in `R-A1` under R-07.
- **AVM `api-management/service` v2 outbound-subnet delegation surface**: The 0.14.1 module's `subnetResourceId` parameter feeds `virtualNetworkConfiguration.subnetResourceId` directly into `Microsoft.ApiManagement/service@2024-05-01`. The v2 SKU's *delegation* requirement on the outbound subnet (if any — Microsoft documentation is currently ambiguous) is **not** validated by the AVM module. T-022 records this risk; if `azd provision` fails on first `azd up` due to a missing delegation, the fix is a thin native augment to the SC VNet's APIM-outbound subnet (set `delegation = { name: 'apim-v2', properties: { serviceName: 'Microsoft.Web/hostingEnvironments' } }` — placeholder name, confirm against Microsoft Learn at implementation time). Recorded in `R-A1` under R-02.
- **AVM `network/private-endpoint` cross-region PE**: The AVM module 0.12.1 does not block cross-region targets (the `service` property is a resource ID, region-agnostic), but the `location` parameter is required and is set explicitly to the agent region in T-020. If a future module version starts validating that `location == <target service>.location`, T-020 falls back to native `Microsoft.Network/privateEndpoints@2025-05-01`. Recorded in `R-A1` under R-03.
- **`Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01` category union**: The `category` field is an open StringType in the 2025-06-01 type definition (probed during `R-A1`). The exact string Foundry expects for an "Azure API Management" admin-connected model may be `AzureOpenAI`, `ApiManagement`, or `ModelGateway` — to be confirmed by inspecting one Foundry portal-authored example at implementation time. If T-031 fails with a category-validation error, the documented `azd` hook fallback (T-032) is enabled by uncommenting the `azure.yaml` hooks block.

None of these risks blocks task generation; all are routed to specific tasks with fallback paths recorded.

---

## Notes

- `[P]` tasks = different files or independent array entries, no dependencies on incomplete sibling tasks in the same phase.
- Every task lists its file paths, its AVM module pin (where applicable), an acceptance criterion, and its upstream dependencies.
- The `Implements:` line traces every task back to one or more functional requirements, success criteria, user stories, and/or research items — supporting end-to-end traceability for `/speckit.analyze`.
- Total task count: **44** (40 implementation + 4 added during `/speckit.analyze` remediation: T-030a Cosmos data-plane SQL role, T-030b diagnostic settings, T-035a partial-failure recovery, T-035b region-pair switching). MVP scope is **~35 tasks** as stated above; the count is at the upper end of the plan's 25–35 estimate, driven by the explicit role-assignment and verification breakdown the user requested. No task is artificially split.
- **Recommended next step**: `/speckit.implement` to author the Bicep + `azure.yaml` + parameter file + APIM policy XML + hooks. `/speckit.analyze` was run and remediation applied; the cross-artifact consistency check now passes.

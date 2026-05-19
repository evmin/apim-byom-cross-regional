# Topology / Resource Model — Private Foundry Agent IaC

**Feature**: `001-private-foundry-iac`
**Plan**: [`plan.md`](./plan.md)
**Architecture source**: [`../../docs/005_architecture.md`](../../docs/005_architecture.md) (rows 1–7 of the topology table)
**Research**: [`research.md`](./research.md)

> Note: for an infrastructure feature, this file plays the role the speckit template calls "data-model.md" — it enumerates the Azure resources the solution provisions, the AVM module choice (or documented fallback), parent/child relationships, and the cross-region links. There are no application-level entities.

This document is normative for the `/speckit.tasks` step. Every resource listed here gets one or more tasks; every cross-region link listed here gets an explicit dependency edge.

---

## Conventions

- **AVM** column: `br/public:avm/res/<group>/<module>` if AVM is used. Module patch versions are **deliberately not pinned in this plan** — `/speckit.tasks` pins them against the live registry. **Native** means hand-rolled `Microsoft.<provider>/<type>@<api-version>`; reason is given in the **Notes** column.
- **Scope** column: subscription / WE-RG / SC-RG / WE-VNet-child / SC-VNet-child / cross-region. The cross-region rows are the bridge.
- **MI** = managed identity. Both MIs are **system-assigned** (per resolved clarification).
- **PE** = private endpoint NIC. **DNS zone** = `privatelink.*` private DNS zone.

---

## Subscription scope

| # | Resource | Type | AVM | Notes |
|---|----------|------|-----|-------|
| S1 | Agent regional resource group | `Microsoft.Resources/resourceGroups` | **Native** (RG creation is intrinsic to `targetScope = 'subscription'`) | Name from `${NAME_PREFIX}-agent-${regionShort}-rg`. Region = WE or EUS2 per `regionPair`. |
| S2 | Model regional resource group | `Microsoft.Resources/resourceGroups` | **Native** | Name from `${NAME_PREFIX}-model-sc-rg`. Region = `swedencentral`. |

`main.bicep` is `targetScope = 'subscription'`. It creates S1 and S2 and then instantiates the three composition modules.

---

## WE agent plane — resource-group scope `S1`

Map of subnets, PEs, and DNS zones below the table makes the relationships explicit.

### Network

| # | Resource | Type | AVM | Parent | Notes |
|---|----------|------|-----|--------|-------|
| W-N1 | Agent VNet | `Microsoft.Network/virtualNetworks` | `br/public:avm/res/network/virtual-network` | `S1` | `WE_VNET_CIDR` default `10.40.0.0/20`. Carries the two subnets below. |
| W-N2 | Agent subnet | `…/virtualNetworks/subnets` | (declared inline as a child of W-N1 via the AVM VNet module's `subnets` parameter) | W-N1 | **Delegated** to `Microsoft.App/environments`. Default `10.40.0.0/24` (recommended), min `/27`. RFC1918. |
| W-N3 | Agent PE subnet | `…/virtualNetworks/subnets` | (declared inline as a child of W-N1) | W-N1 | Default `10.40.1.0/27`. Hosts all WE PE NICs *and* the cross-region APIM inbound PE NIC. |

### Identity (host MI is system-assigned; principal records its principalId)

| # | Resource | Type | AVM | Parent | Notes |
|---|----------|------|-----|--------|-------|
| W-I1 | Agent Foundry account | `Microsoft.CognitiveServices/accounts` (kind = `AIServices` / `OpenAI` family per Foundry agent-host conventions) | `br/public:avm/res/cognitive-services/account` | `S1` | `publicNetworkAccess = Disabled`. Region = WE or EUS2. System-assigned MI **on the account**. |
| W-I2 | Agent Foundry project | `Microsoft.CognitiveServices/accounts/projects` | **Native** — AVM gap (see R-01). | W-I1 | System-assigned MI on the **project**. The project's MI is the one APIM's `validate-azure-ad-token` policy validates (audience `https://cognitiveservices.azure.com/`). |

### Data plane (BYO)

| # | Resource | Type | AVM | Parent | Notes |
|---|----------|------|-----|--------|-------|
| W-D1 | Cosmos DB account | `Microsoft.DocumentDB/databaseAccounts` | `br/public:avm/res/document-db/database-account` | `S1` | `publicNetworkAccess = Disabled`. PE in W-N3. |
| W-D2 | AI Search service | `Microsoft.Search/searchServices` | `br/public:avm/res/search/search-service` | `S1` | `publicNetworkAccess = Disabled`. PE in W-N3. |
| W-D3 | Storage account | `Microsoft.Storage/storageAccounts` | `br/public:avm/res/storage/storage-account` | `S1` | `publicNetworkAccess = Disabled`, `allowBlobPublicAccess = false`. PE in W-N3 (blob sub-resource). |

### Private endpoints (all in W-N3)

| # | Resource | Type | AVM | Targets | Notes |
|---|----------|------|-----|---------|-------|
| W-P1 | PE for agent Foundry account (W-I1) | `Microsoft.Network/privateEndpoints` | `br/public:avm/res/network/private-endpoint` | W-I1 (`accounts/account`) | DNS zone group binds W-Z1, W-Z2, W-Z3 (Cognitive Services / OpenAI / Foundry zones). |
| W-P2 | PE for Cosmos DB (W-D1) | `Microsoft.Network/privateEndpoints` | `br/public:avm/res/network/private-endpoint` | W-D1 (Sql group) | DNS zone group binds W-Z6. |
| W-P3 | PE for AI Search (W-D2) | `Microsoft.Network/privateEndpoints` | `br/public:avm/res/network/private-endpoint` | W-D2 | DNS zone group binds W-Z4. |
| W-P4 | PE for Storage (W-D3) | `Microsoft.Network/privateEndpoints` | `br/public:avm/res/network/private-endpoint` | W-D3 (blob group) | DNS zone group binds W-Z5. |
| W-P5 | **APIM inbound PE — CROSS-REGION** | `Microsoft.Network/privateEndpoints` | `br/public:avm/res/network/private-endpoint` (or native fallback per R-03) | **`X-1` — APIM service in SC** | `location = westeurope` (or `eastus2`), `privateLinkServiceId = X-1`. DNS zone group binds W-Z7. **This is the cross-region bridge from the WE agent VNet to the SC APIM gateway.** |

### Private DNS zones — linked to the agent VNet (W-N1) only

| # | Zone name | AVM | Notes |
|---|-----------|-----|-------|
| W-Z1 | `privatelink.services.ai.azure.com` | `br/public:avm/res/network/private-dns-zone` + VNet link | Foundry-services hostname resolution. |
| W-Z2 | `privatelink.openai.azure.com` | same | AOAI hostname resolution. |
| W-Z3 | `privatelink.cognitiveservices.azure.com` | same | Cognitive Services hostname resolution. |
| W-Z4 | `privatelink.search.windows.net` | same | AI Search hostname resolution. |
| W-Z5 | `privatelink.blob.core.windows.net` | same | Storage blob hostname resolution. |
| W-Z6 | `privatelink.documents.azure.com` | same | Cosmos DB hostname resolution. |
| W-Z7 | `privatelink.azure-api.net` | same | **Cross-region**: resolves the SC APIM gateway hostname to W-P5's WE-VNet private IP. |

In **BYO-DNS** mode, W-Z1…W-Z7 are not created; the operator-provided zone IDs are used and only the VNet link + A-records (via PE zone groups) are authored.

---

## SC model plane — resource-group scope `S2`

### Network

| # | Resource | Type | AVM | Parent | Notes |
|---|----------|------|-----|--------|-------|
| C-N1 | SC VNet | `Microsoft.Network/virtualNetworks` | `br/public:avm/res/network/virtual-network` | `S2` | `SC_VNET_CIDR` default `10.50.0.0/20`. **Not peered** to W-N1. |
| C-N2 | APIM-outbound subnet | `…/virtualNetworks/subnets` | inline child of C-N1 | C-N1 | **Delegated** as required for APIM Std v2 / Prem v2 outbound VNet integration. Default `10.50.0.0/27`. |
| C-N3 | SC PE subnet | `…/virtualNetworks/subnets` | inline child of C-N1 | C-N1 | Default `10.50.1.0/27`. Hosts C-P1. |

### Identity & model

| # | Resource | Type | AVM | Parent | Notes |
|---|----------|------|-----|--------|-------|
| C-I1 | SC Foundry / AOAI model account | `Microsoft.CognitiveServices/accounts` (kind = `OpenAI` / `AIServices`) | `br/public:avm/res/cognitive-services/account` | `S2` | `publicNetworkAccess = Disabled`. Region = `swedencentral`. No MI required on the account itself for the runtime path; access is granted *to* APIM's MI via role assignment (X-3). |
| C-I2 | Model deployments (one per entry of `MODEL_DEPLOYMENTS`) | `Microsoft.CognitiveServices/accounts/deployments` | AVM module's `deployments` parameter (preferred) or native child resources | C-I1 | `model.name` + `model.version` from parameters; `sku.name` + `sku.capacity` from parameters. |

### APIM bridge

| # | Resource | Type | AVM | Parent | Notes |
|---|----------|------|-----|--------|-------|
| X-1 | APIM service (Std v2 default; Prem v2 selectable) | `Microsoft.ApiManagement/service` | `br/public:avm/res/api-management/service` (with fallback per R-02 if a v2 property is missing) | `S2` | Region = `swedencentral`. `publicNetworkAccess = Disabled` (public gateway disabled). Developer portal disabled. System-assigned MI. Outbound VNet integration into C-N2. |
| X-2 | APIM service policy (inbound + backend stacks) | `Microsoft.ApiManagement/service/policies` | (declared on the AVM APIM service module or as a native child of X-1) | X-1 | XML loaded from `infra/policies/inbound.xml` + `infra/policies/backend.xml`; semantic-cache fragments composed in only when `enableSemanticCache = true` (R-09). |

### Private endpoints

| # | Resource | Type | AVM | Targets | Notes |
|---|----------|------|-----|---------|-------|
| C-P1 | PE for SC model account (C-I1) | `Microsoft.Network/privateEndpoints` | `br/public:avm/res/network/private-endpoint` | C-I1 (`accounts/account` sub-resource) | DNS zone group binds C-Z1, C-Z2, C-Z3. |

### Private DNS zones — linked to the SC VNet (C-N1) only

| # | Zone name | AVM | Notes |
|---|-----------|-----|-------|
| C-Z1 | `privatelink.openai.azure.com` | `br/public:avm/res/network/private-dns-zone` + VNet link | Resolves the SC account's AOAI hostname to C-P1's SC-VNet private IP — this is what APIM's outbound VNet integration uses. |
| C-Z2 | `privatelink.services.ai.azure.com` | same | Same for the Foundry-services hostname. |
| C-Z3 | `privatelink.cognitiveservices.azure.com` | same | Same for the Cognitive Services hostname. |

The SC DNS plane is independent from the WE DNS plane (`FR-018` / `FR-019` / `FR-020`); zones are **not shared**, links are **not shared**.

---

## Cross-region wiring — `wiring.bicep`

| # | Resource | Type | AVM | From → To | Notes |
|---|----------|------|-----|-----------|-------|
| X-3 | Role assignment: APIM MI → SC Foundry account | `Microsoft.Authorization/roleAssignments` | `br/public:avm/res/authorization/role-assignment` (or inline assignment from the APIM AVM module if that is the canonical AVM idiom) | X-1 (principal) → C-I1 (scope) | Role: `Cognitive Services OpenAI User` (`5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`). Used by APIM's `authentication-managed-identity` policy on the backend hop. |
| X-4 | Role assignments: WE agent project MI → BYO data plane | `Microsoft.Authorization/roleAssignments` (control plane) + `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments` (Cosmos data plane) | `br/public:avm/res/authorization/role-assignment` for control-plane assignments; **native** for Cosmos data-plane SQL role (AVM gap — see tasks T-030 and T-030a) | W-I2 (principal) → W-D1, W-D2, W-D3 (scope) | Control-plane roles per resource: Cosmos `DocumentDB Account Contributor` (`5bd9cd88-fe45-4216-938b-f97437e15450`), AI Search `Search Index Data Contributor` (`8ebe5a00-799e-43f5-93ac-243d3dce84a7`) + `Search Service Contributor` (`7ca78c08-252a-4471-8644-bb5ff32d4ba0`), Storage `Storage Blob Data Contributor` (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`). Data-plane role on Cosmos: `Cosmos DB Built-in Data Contributor` (`00000000-0000-0000-0000-000000000002`) — assigned via native `sqlRoleAssignments@2024-11-15`, not the regular RBAC type. |
| X-5 | **Foundry admin-connected model** (type: `Azure API Management`) on the WE project | `Microsoft.CognitiveServices/accounts/projects/connections` (category = `ApiManagement`) | **Native** — AVM gap (R-01). Fallback to `azd` postprovision hook if the chosen API version does not expose the property shape (R-06). | W-I2 (parent) → X-1 (target, via the cross-region private hostname resolved through W-P5 + W-Z7) | `authType = AAD`, `audience = https://cognitiveservices.azure.com/`, `urlPathStyle` from parameter (default AOAI), deployments derived from `MODEL_DEPLOYMENTS`, optional static headers + API version. **No subscription keys** (`FR-024`). |

---

## Dependency graph (high level)

This is what `/speckit.tasks` MUST encode as task dependencies.

```
S1, S2 (subscription scope)
   │
   ├── W-N1 ── W-N2, W-N3
   │            │
   │            └── W-P1..W-P4  (depend on W-I1 / W-D1 / W-D2 / W-D3 *and* W-Z1..W-Z6 link to W-N1)
   │
   ├── W-I1 ── W-I2
   │
   ├── W-D1, W-D2, W-D3
   │
   ├── W-Z1..W-Z7  (DNS zones)  ── linked to W-N1
   │
   ├── C-N1 ── C-N2, C-N3
   │
   ├── C-I1 ── C-I2 (model deployments)
   │
   ├── C-Z1..C-Z3  (DNS zones)  ── linked to C-N1
   │
   ├── X-1 (APIM)
   │     ├── outbound VNet integration into C-N2
   │     └── X-2 (policies)
   │
   ├── C-P1  (depends on C-I1 *and* C-Z1..C-Z3 link to C-N1)
   │
   ├── W-P5  (cross-region PE: depends on X-1 *and* W-N3 *and* W-Z7 link to W-N1)
   │
   └── wiring.bicep:
         ├── X-3  (depends on X-1.identity and C-I1)
         ├── X-4  (depends on W-I2.identity and W-D1/W-D2/W-D3)
         └── X-5  (depends on W-I2, X-1, X-2, W-P5, W-Z7; logically the "last" step before validation)
```

---

## AVM coverage ratio (target ≥ 80% per `SC-007`)

Counting *resource types* the solution provisions (not instances):

| Provisioning style | Resource types |
|---|---|
| **AVM** | Virtual network, subnet (via VNet module's `subnets`), private endpoint, private DNS zone, private DNS zone VNet link, Cognitive Services account, API Management service, Cosmos DB account, AI Search service, Storage account, role assignment. **~11 types.** |
| **Native (documented gap)** | `Microsoft.CognitiveServices/accounts/projects` (R-01), `Microsoft.CognitiveServices/accounts/projects/connections` (R-01 + R-06). **2 types.** |
| **Intrinsic** | `Microsoft.Resources/resourceGroups` (created by `targetScope = 'subscription'`; not subject to AVM choice). |

**Ratio**: 11 / 13 ≈ **85% AVM-backed resource types** — comfortably above the `SC-007` target. Both native fallbacks are documented in `research.md` (R-01, R-06) and will be repeated inline in `we-agent-plane.bicep` / `wiring.bicep` at implementation time.

---

## Cross-region links — explicit list

These are the *only* links between the WE plane and the SC plane:

1. **W-P5** — the APIM inbound private endpoint, NIC in WE agent VNet (W-N3), `privateLinkServiceId` → APIM service (X-1) in SC. Resolved from inside W-N1 via DNS zone W-Z7 (`privatelink.azure-api.net`).
2. **X-3** — role assignment whose *principal* is APIM's system-assigned MI (in SC) and whose *scope* is the SC Foundry account (C-I1) — a cross-resource (not cross-region) link, but it is what makes the APIM-to-model backend hop work.
3. **X-5** — the Foundry admin-connected model on the WE project, whose `target` is the SC APIM service's private gateway URL. Authored on the WE project (W-I2); references X-1's resource ID / private hostname.

There is **no VNet peering**, **no public IP**, **no service-tag bypass**, and **no shared DNS zone** between the two planes. Every other interaction goes through one of (1), (2), (3).

# Phase 0 Research — Private Foundry Agent IaC

**Feature**: `001-private-foundry-iac`
**Plan**: [`plan.md`](./plan.md)
**Spec**: [`spec.md`](./spec.md)
**Architecture source**: [`005_architecture.md`](../../005_architecture.md)

This file resolves every IaC-level unknown surfaced by the plan before module boundaries are committed in Phase 1. Each item carries a **Decision**, **Rationale**, and **Alternatives Considered**. Items whose final answer depends on the *live* AVM public registry at task-generation time are flagged as **PROVISIONAL — re-confirm in `/speckit.tasks`** so the registry probe happens close to implementation.

---

## R-01 · AVM coverage for Foundry account `projects` and `projects/connections`

**Question**: Does `avm/res/cognitive-services/account` (or any other AVM module on `br/public:avm/...`) model `Microsoft.CognitiveServices/accounts/projects` and `Microsoft.CognitiveServices/accounts/projects/connections` as first-class child types, including the admin-connected `Azure API Management` connection used for BYOM?

**Decision**: **Fall back to native Bicep for Foundry projects and project connections; use AVM for the Foundry/Cognitive Services *account* itself.** Concretely:

- Provision `Microsoft.CognitiveServices/accounts` via `avm/res/cognitive-services/account` for both the WE agent-side account and the SC model-side account.
- Provision `Microsoft.CognitiveServices/accounts/projects` and `Microsoft.CognitiveServices/accounts/projects/connections` as **native** Bicep resources, declared with an explicit, recent API version (resolved at `/speckit.tasks` time against `az provider show -n Microsoft.CognitiveServices`).
- Document the gap inline in `we-agent-plane.bicep` and in this file, and add a "revisit when AVM ships `projects` coverage" TODO.

**Rationale**: At the time of writing, Foundry projects are a recent surface on `Microsoft.CognitiveServices/accounts/*`. AVM's `cognitive-services/account` module typically lags on new child resource types, and the `projects/connections` admin-connected-model type (`Azure API Management`) is even newer. The pragmatic posture — and the one allowed explicitly by `FR-027` / `FR-028` and Principle II — is to use AVM where it covers, and fall back to a thin native block for the gap. The gap is *small*: two resource types, a handful of properties.

**Alternatives Considered**:

- *Use AVM patterns module (`avm/ptn/...`) for Foundry Agent Service end-to-end.* Rejected for now — the pattern modules that exist (e.g., a "private agent" pattern) tend to be opinionated bundles that do not cleanly support the cross-region APIM BYOM topology. Re-evaluate at `/speckit.tasks` time.
- *Wait for AVM coverage and ship later.* Rejected — the spec is decision-complete and the architecture is stable; a documented native fallback is preferable to blocking on upstream.
- *Author the entire Cognitive Services account as native too.* Rejected — wastes AVM coverage that is already present and proven.

**Verification**: At `/speckit.tasks` time, `az bicep build` against the planned modules must succeed; the native `projects` / `projects/connections` blocks must compile against the chosen API version.

**Status**: **CLOSED** by the Tasks-time addendum (see **R-A1** below — native fallback retained at `Microsoft.CognitiveServices/accounts/projects@2025-06-01` and `…/projects/connections@2025-06-01`; AVM `cognitive-services/account` pinned at `0.14.2` for the account itself). The original "PROVISIONAL — re-confirm in `/speckit.tasks`" status is preserved here for audit-trail purposes only.

---

## R-02 · AVM coverage for APIM v2 SKUs (Std v2 / Prem v2) with outbound VNet integration + inbound PE

**Question**: Does `avm/res/api-management/service` expose Standard v2 and Premium v2 with (a) outbound VNet integration into a delegated subnet and (b) an inbound private endpoint on the gateway, as first-class properties? If not, what is the minimal fallback?

**Decision**: **Use AVM for the APIM service resource; declare the inbound private endpoint via the AVM `private-endpoint` module (or a native PE if a gap blocks it); use the APIM AVM module's outbound VNet integration property if exposed for v2 SKUs, otherwise extend the APIM service with a small native property addition or a `Microsoft.ApiManagement/service@<api-version>` native block as a temporary fallback.**

Concretely planned:

- Provision the APIM service via `avm/res/api-management/service` with `sku.name ∈ {StandardV2, PremiumV2}`.
- Configure outbound VNet integration into the SC VNet's APIM-outbound delegated subnet via the module's property (subject to AVM property-surface verification at `/speckit.tasks` time).
- Disable the public gateway and the developer portal exposure via module parameters (`publicNetworkAccess = Disabled`, developer-portal toggle off).
- Provision the inbound private endpoint on the APIM gateway sub-resource as a separate resource (cross-region: the PE lives in the WE agent VNet, the target is the SC APIM service). Prefer `avm/res/network/private-endpoint`; if a property gap blocks, fall back to native `Microsoft.Network/privateEndpoints@<latest>`.

**Rationale**: APIM v2 SKUs are first-class in the official Azure platform and documented to support inbound private endpoints (cross-region) and outbound VNet integration. AVM coverage typically tracks the supported property surface; minor gaps (e.g., a newly-added property) are bridgeable with a thin native addition without re-authoring the whole APIM resource.

**Alternatives Considered**:

- *Author the APIM service entirely as native Bicep.* Rejected — wastes existing AVM coverage and contradicts `FR-027`.
- *Use Premium v2 by default to avoid SKU-feature-surface ambiguity.* Rejected — overprovisioning. `spec.md` § Assumptions makes Standard v2 the default; Premium v2 is on-request.
- *Use classic Premium with the older inbound-PE feature.* Rejected by spec (`FR-015`): only Std v2 / Prem v2 are allowed.

**Verification**: `az bicep build` clean; `azd provision --preview` shows the APIM resource with `sku.name = StandardV2`, `publicNetworkAccess = Disabled`, and an outbound `virtualNetworkConfiguration` pointing at the SC delegated subnet; the inbound PE resource has `privateLinkServiceId` pointing at the APIM service and `subnet` pointing at the WE PE subnet.

**Status**: **CLOSED** by the Tasks-time addendum (see **R-A1** below — AVM `api-management/service` pinned at `0.14.1` with `StandardV2`/`PremiumV2` allowed and outbound-VNet integration via `subnetResourceId` confirmed; outbound-subnet delegation watchpoint queued under T-022). The original "PROVISIONAL — re-confirm in `/speckit.tasks`" status is preserved here for audit-trail purposes only.

---

## R-03 · Cross-region private endpoint authoring (PE in WE VNet, target APIM in SC)

**Question**: Does AVM `avm/res/network/private-endpoint` (or its native equivalent) support a private endpoint whose `location` differs from the target resource's `location`?

**Decision**: **Yes; author the APIM inbound PE in the WE agent VNet (`location = westeurope`) targeting the APIM service in `swedencentral`.** Use the AVM PE module. If the module's parameter shape blocks cross-region authoring (it should not, since this is a platform-supported scenario per Azure documentation), fall back to native `Microsoft.Network/privateEndpoints@<latest>` with the same property shape.

**Rationale**: The Azure platform documents that the APIM inbound PE NIC may be created in a region different from the APIM instance — that is precisely the cross-region bridge `005_architecture.md` relies on. The PE resource's `location` is the NIC's location (where the IP is bound), and the `privateLinkServiceId` points at the target by resource ID, region-agnostic. There is no platform-level blocker; the only risk is an AVM module quirk that *requires* matching regions, which would be a module bug. Confirmed against Microsoft documentation (APIM inbound PE — cross-region PE; link in `005_architecture.md` § References).

**Alternatives Considered**:

- *Put the APIM instance in West Europe to avoid the cross-region PE.* Rejected — would defeat the architecture: APIM must be in SC to reach the SC model account over its own SC VNet integration.
- *Use a Standard Load Balancer with PrivateLink Service.* Rejected — APIM Std v2 / Prem v2 provides the inbound PE first-class; introducing a PLS is unnecessary plumbing.

**Verification**: After deployment, `az network private-endpoint show` confirms `location = westeurope`, `privateLinkServiceConnections[0].privateLinkServiceId` points at an APIM service in `swedencentral`, and the NIC's IP belongs to the WE agent VNet's PE subnet.

**Status**: **CLOSED** at plan time (platform-supported); AVM specifics also **CLOSED** by the Tasks-time addendum (see **R-A1** below — AVM `network/private-endpoint` pinned at `0.12.1`; no location-equality validation, native fallback queued only if a future module version regresses).

---

## R-04 · Agent-subnet sizing for `Microsoft.App/environments` delegation

**Question**: What are the binding rules for the agent subnet that backs the Foundry Agent Service capability host (Container-Apps-backed)?

**Decision** (sourced from `005_architecture.md` and Microsoft docs):

- Subnet MUST be **delegated to `Microsoft.App/environments`** — no other delegation, no shared use.
- Subnet MUST be **RFC1918**.
- Prefix length: **`/24` recommended, `/27` minimum**. The IaC validates `agentSubnetPrefixLength ≤ 27` at parameter validation time and rejects smaller subnets (i.e., `/28` and below) with a clear error.
- Subnet MUST be **dedicated to a single Foundry account** — no multi-tenant sharing.
- Subnet MUST live in the **same region** as the Foundry account that backs the capability host (Microsoft API-level rule; see `005_architecture.md` § Context).

**Rationale**: These are non-negotiable platform constraints, called out explicitly in `spec.md` § Edge Cases and `005_architecture.md`. The IaC's job is to enforce them at parameter-validation time before any resource is created — failing inside Azure mid-deploy is a worse operator experience.

**Alternatives Considered**:

- *Allow `/28` for "small dev" deployments.* Rejected — Microsoft does not qualify it and the resulting capability-host scale-out failures would be silent and late.
- *Allow non-RFC1918 ranges.* Rejected — same reason; Microsoft documents the requirement.

**Verification**: Parameter validation in `main.bicep` rejects `apiVersion`-style param decompositions like `agentSubnetPrefix = 10.0.0.0/28`; `az bicep build` does not surface the validation, but `azd provision --preview` against a bad value MUST fail fast.

**Status**: **CLOSED**.

---

## R-05 · APIM policy authoring style in Bicep — inline XML vs `loadTextContent`

**Question**: How should the APIM policy stack (inbound + backend) be authored in Bicep — as inline XML inside `Microsoft.ApiManagement/service/policies@…` child resources, or via `loadTextContent('./policies/<name>.xml')` referencing standalone XML files under `infra/policies/`?

**Decision**: **Use `loadTextContent('./policies/inbound.xml')` (and equivalents) with standalone XML files under `infra/policies/`.**

**Rationale**:

- **Readability**: Policy XML is verbose; inline string literals balloon the Bicep file and obscure module boundaries. Standalone XML files let an operator open, diff, and review policies in their native editor.
- **Diffability**: A change to the inbound policy stack shows up in a single, small XML diff rather than a noisy multi-line Bicep change.
- **Reuse**: The same XML can be parameterised (Bicep parameters injected via `replace()` or via APIM policy expressions) and reused if a second product surface ever needs the same policy stack — but Principle II says we don't generalise speculatively, so this is just an *option*, not a current driver.
- **Lint surface**: Inline XML inside Bicep strings escapes oddly and confuses some editor tooling. Standalone `.xml` lints cleanly with XML tools.

**Alternatives Considered**:

- *Inline XML in Bicep string literals.* Rejected for the reasons above.
- *External policy fragments + APIM `set-variable` / `include-fragment`.* Rejected — speculative, adds APIM policy fragments as an additional concept for no current gain.

**Verification**: `az bicep build` resolves `loadTextContent` paths cleanly; deployed APIM policy matches the source `.xml` byte-for-byte (modulo Bicep parameter substitution).

**Status**: **CLOSED**.

---

## R-06 · Foundry admin-connected model of type `Azure API Management` — Bicep vs `azd` hook

**Question**: Can the Foundry `Azure API Management` admin-connected model on the WE project be authored natively in Bicep via `Microsoft.CognitiveServices/accounts/projects/connections@<latest>`, or is a post-provision step (`azd` postprovision hook running `az ai-foundry connection create` or an `az rest` PUT) required?

**Decision**: **Plan for Bicep-native authoring via `Microsoft.CognitiveServices/accounts/projects/connections@<latest>` as the primary path; retain a documented `azd` postprovision hook as a *fallback* if the property shape needed (auth type `AAD`, audience, deployment list, URL-path style, optional headers / API version) is not fully expressible at the chosen API version.** Final selection is made at `/speckit.tasks` time after a fresh API-version probe.

**Rationale**:

- Spec `FR-022` and the architecture both call out the `Azure API Management` connection as a first-class Foundry concept. Microsoft has been progressively exposing it through ARM; the most recent `accounts/projects/connections` API versions surface `category = ApiManagement` (or `ModelGateway`) with the auth + audience + deployments shape needed.
- A Bicep-native path is preferred (Principle III — surgical changes; one tool, one lifecycle, one teardown). An `azd` hook is acceptable but adds an out-of-Bicep lifecycle step, and on `azd down` we would have to wire a `predown` hook to remove the connection cleanly to satisfy `FR-002`.

**Alternatives Considered**:

- *Always use a postprovision hook.* Rejected as primary — duplicates Bicep state into a script and complicates idempotency and teardown.
- *Configure the connection by hand in the Foundry portal.* Rejected — defeats the "single `azd up`" requirement (`SC-001`).

**Verification**: After `azd up`, the WE Foundry project lists exactly one admin-connected model of category `Azure API Management`, with `authType = AAD`, `target = <SC APIM private gateway URL>`, `audience = https://cognitiveservices.azure.com/`, and the deployments configured by parameter. After `azd down`, the connection is gone (Bicep handles this natively; the hook fallback, if used, would handle it via `predown`).

**Status**: **CLOSED → Bicep-native** by the Tasks-time addendum (see **R-A1** below — `Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01` confirmed authorable with `authType=AAD`; T-031 implements; T-032 retained as documented inert `.template` hook fallback only). The original "PROVISIONAL — re-confirm in `/speckit.tasks`" status is preserved here for audit-trail purposes only.

---

## R-07 · DNS zone ownership — create-new vs BYO

**Question**: Should the solution always create the required private DNS zones, or also support reusing operator-owned zones?

**Decision**: **Default — create the zones, per region, as part of the WE and SC stacks. BYO-DNS — supported via optional parameter `existingPrivateDnsZoneIds` (map of zone-name → resource ID).** In BYO mode the solution creates only VNet links (and A-records via PE DNS-zone-group bindings) into the existing zones; on `azd down` it removes only the links it created, never the zones themselves (`FR-021`).

For *this feature* (demo / single-environment posture), the documented happy path is the **create-new** mode. The BYO-DNS path is exposed but not exercised by the smoke test in `quickstart.md`.

**Rationale**: A hub-and-spoke shop typically owns the `privatelink.*` zones in a hub subscription. Refusing to reuse them would force the solution into the hub's RBAC scope or require zone duplication, both of which are bad. Supporting BYO via a single parameter is cheap and aligns with `FR-021`.

**Alternatives Considered**:

- *Always create zones (no BYO).* Rejected — incompatible with typical enterprise hub-and-spoke deployments and explicitly forbidden by `FR-021`.
- *Always require BYO.* Rejected — bad demo / lab experience; `FR-021` says the solution MUST support both modes.

**Verification**: With `existingPrivateDnsZoneIds = {}`, the WE and SC stacks create the zones listed in `FR-018` / `FR-019` and link them to their respective VNets. With `existingPrivateDnsZoneIds` populated, only VNet links are created; `azd down` of that environment leaves the operator-owned zones in place.

**Status**: **CLOSED**.

---

## R-08 · Diagnostic settings target — optional BYO Log Analytics workspace

**Question**: Does the IaC own a Log Analytics workspace, or does the operator bring their own?

**Decision**: **BYO only.** The IaC accepts an optional `logAnalyticsWorkspaceId` parameter. When set, the solution wires diagnostic settings on the APIM service, the two Foundry / AOAI accounts, and the BYO data-plane resources to that workspace. When unset, no diagnostic settings are created. The IaC does not provision a workspace, never sizes one, never sets retention, never authors dashboards or alert rules. This matches `spec.md` § Assumptions and § Out of Scope.

**Rationale**: Observability stack design is explicitly out of scope (`spec.md` § Out of Scope). Owning a workspace inside this feature would bleed scope and conflict with the "single source of architectural truth" constraint (the workspace would be a hidden architectural component).

**Alternatives Considered**:

- *Auto-provision a workspace per environment.* Rejected — out of scope.
- *Require a workspace.* Rejected — over-prescriptive for a demo / lab.

**Verification**: With `logAnalyticsWorkspaceId` unset, `az monitor diagnostic-settings list` returns empty for every provisioned resource. With it set, every supported resource has exactly one diagnostic setting pointing at that workspace.

**Status**: **CLOSED**.

---

## R-09 · APIM policy parameterisation for the optional semantic-cache toggle

**Question** *(implied by FR-016 + FR-025)*: The semantic-cache policies (`llm-semantic-cache-lookup` / `llm-semantic-cache-store`) are optional. How do we keep them out of the deployed policy stack when the toggle is off?

**Decision**: **Generate the policy XML via Bicep string interpolation around `loadTextContent` fragments.** Each policy stack file (`policies/inbound.xml`, `policies/backend.xml`) contains the *always-on* policies; the two cache fragments live in separate small files (`policies/inbound-cache.xml`, `policies/backend-cache.xml`). The Bicep module concatenates the cache fragments into the assembled policy string only when `enableSemanticCache = true`. The assembled string is then assigned to the `Microsoft.ApiManagement/service/policies` resource.

**Rationale**: Keeps the always-on policies in clean, reviewable XML files; treats the optional fragments as composable units; avoids smuggling Bicep parameter expressions into APIM policy XML (which is fragile).

**Alternatives Considered**:

- *Always include the cache policies, gated by an APIM policy `<choose>` block.* Rejected — adds dead policy execution paths and complicates auditability of "is the cache actually active in this environment?".
- *Two parallel `service/policies` resources, one with cache and one without, with a conditional deployment.* Rejected — duplicate policy bodies and brittle conditionals.

**Verification**: With `enableSemanticCache = false`, the deployed APIM policy XML does not contain `<llm-semantic-cache-lookup>` or `<llm-semantic-cache-store>` elements. With `enableSemanticCache = true`, both are present in the correct positions (inbound: after `llm-token-limit`, before `set-backend-service`; backend: after `authentication-managed-identity`).

**Status**: **CLOSED**.

---

## R-10 · Default CIDR allocation

**Question** *(implied by FR-006 / FR-025)*: What default CIDRs should ship for the two VNets and four subnets?

**Decision**: Use non-overlapping RFC1918 defaults that satisfy the agent-subnet `/24`-recommended rule and leave headroom in each VNet for incremental subnet additions. Concrete defaults (overridable via parameters):

- **Agent VNet** (`WE_VNET_CIDR`): `10.40.0.0/20`
  - Agent subnet (`Microsoft.App/environments` delegated): `10.40.0.0/24`
  - Agent PE subnet: `10.40.1.0/27`
- **SC VNet** (`SC_VNET_CIDR`): `10.50.0.0/20`
  - APIM-outbound delegated subnet: `10.50.0.0/27`  *(size verified per APIM v2 outbound-VNet-integration docs at `/speckit.tasks` time)*
  - SC PE subnet: `10.50.1.0/27`

**Rationale**: Non-overlapping, comfortably inside RFC1918, far from common hub ranges (`10.0.0.0/16`), agent subnet at the recommended `/24`. Both VNets at `/20` leave room for at least a dozen extra subnets per region without re-IP.

**Alternatives Considered**:

- *Default to `192.168.x.x` ranges.* Rejected — frequently used for on-prem / small office; collision risk with operator hubs.
- *Use a single `/16` with sub-allocations.* Rejected — overkill for two regional VNets each of which gets a `/20`.
- *Use `/22` per VNet.* Rejected — tight for the recommended `/24` agent subnet plus future subnets.

**Verification**: `az bicep build` clean; `azd provision --preview` shows the four subnets carved correctly inside their VNets; no overlap warnings.

**Status**: **CLOSED**.

---

## Aggregate status

| ID | Title | Status |
|----|----|----|
| R-01 | AVM coverage for Foundry projects + connections | PROVISIONAL — re-confirm in `/speckit.tasks` |
| R-02 | AVM coverage for APIM v2 SKUs | PROVISIONAL — re-confirm in `/speckit.tasks` |
| R-03 | Cross-region private endpoint | CLOSED (platform-supported); AVM specifics PROVISIONAL |
| R-04 | Agent-subnet sizing | CLOSED |
| R-05 | APIM policy authoring style | CLOSED |
| R-06 | Foundry connection — Bicep vs hook | PROVISIONAL — re-confirm in `/speckit.tasks` |
| R-07 | DNS zone ownership | CLOSED |
| R-08 | Diagnostic settings target | CLOSED |
| R-09 | Semantic-cache policy composition | CLOSED |
| R-10 | Default CIDR allocation | CLOSED |

**Net open work for `/speckit.tasks`**: probe the live `br/public:avm/...` registry to (a) pin exact AVM module versions, (b) confirm Foundry projects/connections AVM coverage status (R-01), (c) confirm APIM v2 property surface (R-02 / R-03), and (d) decide Bicep-native vs `azd` hook for the Foundry `Azure API Management` connection (R-06). Everything else is locked in.

---

## R-A1 · Tasks-time addendum — AVM pins and PROVISIONAL closures

**Author**: `/speckit.tasks` (auto-appended; do not hand-edit).
**Probe target**: `mcr.microsoft.com/v2/bicep/avm/...` (live OCI registry) and `https://raw.githubusercontent.com/Azure/bicep-types-az/main/generated/cognitiveservices/microsoft.cognitiveservices/2025-06-01/types.json` (live Bicep type index).
**Selection rule**: highest stable SemVer (no `-alpha`, `-beta`, `-rc.*`).

### Pinned AVM module versions

| AVM module | Pinned version | Bicep `Microsoft.*` API version used internally | Used in tasks |
|------------|----------------|-------------------------------------------------|---------------|
| `br/public:avm/res/network/virtual-network` | **0.9.0** | `Microsoft.Network/virtualNetworks@2025-05-01` (subnets via `subnets[]` param with delegation) | T-011, T-022 |
| `br/public:avm/res/network/private-endpoint` | **0.12.1** | `Microsoft.Network/privateEndpoints@2025-05-01` (`privateDnsZoneGroup` first-class) | T-018, T-019, T-020, T-025 |
| `br/public:avm/res/network/private-dns-zone` | **0.8.1** | `Microsoft.Network/privateDnsZones + virtualNetworkLinks@2024-06-01` (links via `virtualNetworkLinks[]` param) | T-012, T-023 |
| `br/public:avm/res/cognitive-services/account` | **0.14.2** | `Microsoft.CognitiveServices/accounts + …/deployments@2025-06-01`; exposes `allowProjectManagement`, `deployments[]`, system-assigned MI | T-013, T-024 |
| `br/public:avm/res/api-management/service` | **0.14.1** | `Microsoft.ApiManagement/service@2024-05-01`; `sku ∈ {…, StandardV2, PremiumV2}` allowed; `publicNetworkAccess` first-class; outbound VNet integration via `subnetResourceId` → `properties.virtualNetworkConfiguration.subnetResourceId`; inbound PE via `privateEndpoints[]` (not used here — PE is cross-region, authored separately in T-020) | T-026 |
| `br/public:avm/res/document-db/database-account` | **0.19.0** | `Microsoft.DocumentDB/databaseAccounts@2024-11-15` | T-015 |
| `br/public:avm/res/search/search-service` | **0.12.1** | `Microsoft.Search/searchServices@2025-05-01` | T-016 |
| `br/public:avm/res/storage/storage-account` | **0.32.0** | `Microsoft.Storage/storageAccounts@2025-01-01` | T-017 |
| `br/public:avm/res/authorization/role-assignment/rg-scope` | **0.1.1** | `Microsoft.Authorization/roleAssignments@2022-04-01` (resource-group-scoped variant) | T-029, T-030 |

All ten modules return stable SemVer tags only (no pre-release suffixes); the pre-1.0 versions `0.1.1` for the role-assignment sub-modules are still stable per the AVM publishing rule (SemVer `0.y.z` releases are stable; `-alpha`/`-beta`/`-rc.*` are not).

### R-01 — RESOLVED: native fallback retained for `accounts/projects` and `…/projects/connections`

Probe of `avm/res/cognitive-services/account@0.14.2` source (`main.bicep`):

- Authors `Microsoft.CognitiveServices/accounts@2025-06-01` directly.
- Authors child `…/accounts/deployments@2025-06-01` via the `deployments[]` param (used in T-024).
- Authors child `…/accounts/commitmentPlans@2025-06-01` via `commitmentPlanProperties` param.
- Exposes `allowProjectManagement bool?` (line 139, fed into `properties.allowProjectManagement` line 337).
- **Does NOT author** `Microsoft.CognitiveServices/accounts/projects` or `Microsoft.CognitiveServices/accounts/projects/connections` as child resources.

**Decision (final)**: same as the original R-01 ruling — provision the **account** via AVM, fall back to **native** Bicep for `…/accounts/projects@2025-06-01` (T-014) and `…/accounts/projects/connections@2025-06-01` (T-031). Both API versions confirmed present in the 2025-06-01 type index.

### R-02 — RESOLVED: AVM is sufficient for APIM v2 with one watchpoint

Probe of `avm/res/api-management/service@0.14.1` source (`main.bicep`):

- `sku` `@allowed` list includes `StandardV2` and `PremiumV2` (lines 69–78).
- `subnetResourceId` and `virtualNetworkType` params present (lines 84, 90); these feed `properties.virtualNetworkConfiguration.subnetResourceId` (line 283) — the **same shape** the v2 SKUs use for outbound VNet integration.
- `publicNetworkAccess` exposed as first-class param (line 170); auto-derived to `Disabled` when `privateEndpoints` is set (lines 264–266).
- `privateEndpoints[]` array exposed (line 116) — used to author the gateway PE inline via the AVM PE 0.12.0 sub-module; **not used here** since the T-020 PE is cross-region and authored in the WE module.
- `enableDeveloperPortal` param drives `properties.developerPortalStatus = 'Disabled'` (line 297).

**Decision (final)**: use AVM `api-management/service:0.14.1` as primary. **Watchpoint** captured under "Tasks-time risks" in `tasks.md`: the v2 SKUs' optional outbound-subnet *delegation* requirement (Microsoft Learn ambiguous as of probe time) may need a thin native augment to the SC VNet's APIM-outbound subnet (T-022). If the first `azd provision --preview` flags a delegation error, the fix is a native subnet `delegations[]` block — no module replacement required.

**R-03** unchanged from the original ruling (platform-supported cross-region PE; AVM 0.12.1 module surface is open and does not validate location equality).

### R-06 — RESOLVED to Bicep-native

Probe of the 2025-06-01 Bicep type index (`generated/cognitiveservices/microsoft.cognitiveservices/2025-06-01/types.json`):

- `Microsoft.CognitiveServices/accounts/projects@2025-06-01` is a first-class `ResourceType`.
- `Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01` is a first-class `ResourceType`.
- `ConnectionPropertiesV2` is a `DiscriminatedObjectType` keyed on `authType` with concrete variants for `AAD`, `AccessKey`, `AccountKey`, `ApiKey`, `CustomKeys`, `ManagedIdentity`, `None`, `OAuth2`, `PAT`, `SAS`, `ServicePrincipal`, `UsernamePassword`. `AADAuthTypeConnectionProperties` exists and is the variant used here.
- Base properties include `category` (open `UnionType` admitting known literals + open `StringType`), `target` (open string — the APIM gateway URL), `metadata` (open-ended `Map<string, string>` for `audience`, `urlPathStyle`, `dynamicDiscovery`, `deployments`, etc.), `peRequirement`, `peStatus`, etc.
- Known `category` literal values in 2025-06-01 include `AzureOpenAI`, `AIServices`, `CognitiveService`, `CognitiveSearch`, `OpenAI`, `Serverless`, `ManagedOnlineEndpoint`, and **the union accepts open strings** — so `category = 'ApiManagement'` (or `'ModelGateway'`, whichever Foundry stamps on portal-authored examples) is also valid.

**Decision (final)**: **Bicep-native, primary path**. T-031 authors the connection as `Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01` with `authType = 'AAD'`, `target = 'https://${apimGatewayHostname}'`, `metadata.audience = 'https://cognitiveservices.azure.com/'`, and the deployments + URL-path style + dynamic-discovery flags encoded in `metadata`. The `azd` hook fallback (T-032) is **kept on disk as a `.template` file** but is **inert by default** — it is enabled only if T-031's deploy-time acceptance fails on the chosen `category` string.

### Aggregate status — updated

| ID | Title | Status after R-A1 |
|----|-------|-------------------|
| R-01 | AVM coverage for Foundry projects + connections | **CLOSED** (native fallback retained at `accounts/projects` and `…/projects/connections`; pinned API version 2025-06-01; AVM account module pinned at 0.14.2) |
| R-02 | AVM coverage for APIM v2 SKUs | **CLOSED** (AVM 0.14.1 sufficient; outbound-subnet delegation watchpoint logged in tasks.md "Tasks-time risks") |
| R-03 | Cross-region private endpoint | **CLOSED** (AVM PE 0.12.1 module does not constrain location ≠ target.location; native fallback queued only if a future module version regresses) |
| R-04 | Agent-subnet sizing | CLOSED |
| R-05 | APIM policy authoring style | CLOSED |
| R-06 | Foundry connection — Bicep vs hook | **CLOSED → Bicep-native** (T-031); hook (T-032) retained as inert documented fallback |
| R-07 | DNS zone ownership | CLOSED (BYO-mode VNet-link authored natively under AVM-owned or BYO zones — risk logged) |
| R-08 | Diagnostic settings target | CLOSED |
| R-09 | Semantic-cache policy composition | CLOSED |
| R-10 | Default CIDR allocation | CLOSED |

All ten items are now CLOSED; zero PROVISIONAL items remain.

# Implementation Plan: Bicep / AZD / AVM IaC for Private Foundry Agent with Cross-Region Model

**Branch**: `001-private-foundry-iac` | **Date**: 2026-05-15 | **Spec**: [`spec.md`](./spec.md)

**Input**: Feature specification from `specs/001-private-foundry-iac/spec.md`

**Architecture source of truth**: [`005_architecture.md`](../../005_architecture.md) at the repository root.

**Note**: This file is the `/speckit.plan` output. It does not enumerate executable tasks — that is `/speckit.tasks`. It does not author Bicep source — that is `/speckit.implement`.

## Summary

Encode the private Foundry Agent Service + cross-region APIM + Sweden Central model topology described in `005_architecture.md` as an Azure Developer CLI (`azd`) project that uses Bicep with Azure Verified Modules (AVM) as the strict first preference. The operator drives the lifecycle with `azd up` / `azd down` / `azd provision --preview`. Every Foundry, Azure OpenAI, APIM, Cosmos DB, AI Search, and Storage resource is provisioned with public network access disabled; the only network-reachable surfaces are private endpoints in customer VNets in West Europe (or East US 2) for the agent plane and Sweden Central for the model plane. Identity on the runtime path is exclusively AAD via system-assigned managed identities — one on the agent project, one on the APIM instance.

The plan commits to:

- **Language**: Bicep (latest stable Azure CLI Bicep), `targetScope = 'subscription'` at the entry point.
- **Tool**: Azure Developer CLI (`azd`) driving `azd up` / `azd down` / `azd provision` / `azd env`.
- **Module strategy**: AVM first; documented native-Bicep fallback only where AVM coverage is missing or insufficient.
- **Default region pair**: `westeurope` + `swedencentral`; `eastus2` + `swedencentral` selectable via parameter.

Everything below is the *plan* for the implementation; no Bicep is authored in this phase.

## Technical Context

**Language/Version**: Bicep (Azure CLI Bicep, latest stable at task-generation time). ARM JSON exists only as the transpilation product of `az bicep build`; no hand-authored ARM JSON.

**Primary Dependencies**:

- Azure Developer CLI (`azd`) — recent stable.
- Azure CLI (`az`) with the `bicep` extension auto-managed; Bicep CLI ≥ a version that supports `br/public:avm/...` module references and target API versions ≥ 2024-… for Foundry / Cognitive Services / APIM / Networking.
- Azure Verified Modules — Bicep public registry (`br/public:avm/res/...`, `br/public:avm/ptn/...`). Exact module versions to be pinned at `/speckit.tasks` time (the registry moves; speculative patch pinning is forbidden).
- Native `Microsoft.*` Bicep resource declarations as documented fallback for any AVM gap (expected at minimum for Foundry `projects` / `projects/connections` sub-resources; see `research.md`).

**Storage** (state of the IaC itself):

- Provisioning state lives in the target Azure subscription's deployment history (`Microsoft.Resources/deployments`) and in `azd`'s per-environment state under `.azure/<env>/`. There is no separate IaC state store (no Terraform-style backend). The `.azure/` directory is git-ignored and operator-local.

**Testing / Validation**:

- `az bicep build infra/main.bicep` — MUST compile clean with zero warnings.
- `az bicep lint infra/main.bicep` — clean (warnings investigated, suppressed only with a recorded reason).
- `azd provision --preview` — runs the underlying ARM what-if; deltas reviewed before any apply.
- `azd up` smoke test from a private VM in the WE agent VNet (or via the Foundry Agent SDK from a private compute) — issues one chat-completion call against a configured model deployment and confirms a 2xx response.
- Network-posture check (`az resource list` / `az graph` query) — confirms every provisioned Foundry / AOAI / APIM / Cosmos / AI Search / Storage reports `publicNetworkAccess = Disabled` and APIM's public gateway is disabled.
- Idempotency check — second consecutive `azd up` reports zero material changes (deployment shows only `NoChange` results).

**Target Platform**:

- Azure subscription with the relevant resource providers registered: `Microsoft.CognitiveServices`, `Microsoft.MachineLearningServices` (where Foundry sub-resources require it), `Microsoft.ApiManagement`, `Microsoft.Network`, `Microsoft.DocumentDB`, `Microsoft.Search`, `Microsoft.Storage`, `Microsoft.App`, `Microsoft.OperationalInsights` (for diagnostics, if a workspace is wired in).
- Approved region pairs only: `westeurope` + `swedencentral` (default) or `eastus2` + `swedencentral` (alternate). The solution MUST reject any other pair at parameter validation.
- Operator workstation or CI runner with `az`, `azd`, and `bicep` on PATH and an AAD principal that can RBAC-bind the two system-assigned MIs at deploy time.

**Project Type**: Infrastructure-as-Code project (`azd` template). No application code, no client libraries, no agent business logic.

**Performance Goals**:

- `azd up` from a clean subscription to converged state SHOULD complete within one APIM provisioning window — APIM Std v2 / Prem v2 first-create dominates wall time (typically 30–60 min).
- Re-`azd up` (idempotent no-op) SHOULD complete in well under five minutes once APIM is created.
- Runtime path performance is a *product* of the topology (PE-to-PE hops) and is not a Bicep-level concern; latency targets sit with the consuming feature, not this IaC.

**Constraints** (binding; flow from `005_architecture.md`, the spec, and the constitution):

- Public network access disabled on every Foundry / AOAI / APIM / Cosmos / AI Search / Storage at all times. No "create public, then disable" pattern.
- Foundry account region MUST equal the agent VNet region (Microsoft API-level rule, no override). The IaC validates this before any resource is created.
- Two regional VNets stay isolated — no VNet peering between WE/EUS2 and SC. The cross-region link is APIM's outbound VNet integration in SC plus the APIM inbound PE in WE.
- AAD / managed-identity only on the agent-to-model runtime path. No subscription keys, no account keys, no connection strings.
- AVM-first: every resource type with fit-for-purpose AVM coverage MUST be provisioned via AVM. Every fallback MUST be justified in `research.md` or inline.
- Two **system-assigned** managed identities, one on the agent project, one on the APIM instance. No user-assigned MIs in this feature.
- Default URL-path style on the Foundry `Azure API Management` admin-connected model is AOAI-style `/deployments/{name}/chat/completions`; OpenAI-style is selectable via parameter.
- Azure Firewall / egress control is out of scope (operator BYO).

**Scale/Scope**:

- One `azd` environment per deployed instance; many instances supported via independent `azd env new` invocations.
- Two regional resource groups per environment, ~25–35 Azure resources total (two VNets, four subnets, ~7 PEs across two regions, ~10 private DNS zones + links across two regions, one APIM instance, two Foundry / AOAI accounts, one Foundry project, one capability host wiring, three BYO data-plane resources, two MIs, ~6–10 role assignments).
- The same code MUST deploy to both `westeurope`+`swedencentral` and `eastus2`+`swedencentral` with parameters only (no code edits).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-evaluated after Phase 1 design.*

The active constitution (`/.specify/memory/constitution.md`, v1.0.0, ratified 2026-05-15) defines four Core Principles, an Additional Constraints section, Development Workflow & Quality Gates, and Governance. Each is evaluated against this plan.

### Principle I — Think Before Coding

**Status**: PASS.

- Assumptions are stated explicitly in `spec.md` (§ Assumptions) and the four open questions from the spec's clarification round are recorded under § Clarifications, all resolved before this plan was authored.
- Architecture-level decisions (region pair, identity flavour, egress scope, URL-path style) are captured in `005_architecture.md` (the source of WHAT) and the spec's Clarifications block (the resolved decisions). This plan does not re-decide them.
- Remaining unknowns (AVM coverage for Foundry sub-resources, APIM v2 SKU AVM property surface, cross-region PE module support, agent-subnet sizing for `Microsoft.App/environments`, APIM policy authoring style, Foundry connection authoring path, DNS zone ownership) are enumerated in `research.md` rather than silently chosen. The plan resolves each before moving to module-boundary design.

### Principle II — Simplicity First

**Status**: PASS.

- No speculative configurability beyond the parameter surface required by `FR-025`. Every parameter traces to a functional requirement, an edge case, or a clarification answer.
- No abstractions for single-use code. The Bicep layout (1 entry point + 3 modules + 1 wiring module) is the minimum that cleanly separates the WE agent plane, the SC model plane, and the cross-region wiring. There is no fourth "common" module of speculative helpers.
- No error handling for impossible scenarios — parameter validation is bounded to the failure modes named in `spec.md` § Edge Cases (unsupported APIM SKU, region mismatch, unsupported region pair, undersized agent subnet, partial-failure redeploy).
- Bicep is authored at the latest target API versions only — no compatibility shims for older API versions are introduced.

### Principle III — Surgical Changes

**Status**: PASS.

- The plan touches only `specs/001-private-foundry-iac/` and a tightly bounded update to `.github/copilot-instructions.md` between the existing `<!-- SPECKIT START -->` / `<!-- SPECKIT END -->` markers, as the template instructs.
- The plan does not propose edits to `005_architecture.md`, the constitution, or any other speckit feature directory.
- Future Bicep authoring (under `/speckit.implement`) will be confined to a new top-level `infra/` directory plus an `azure.yaml` at the repo root (or under the feature directory if speckit convention requires it; see Project Structure § Decision). No edits to unrelated files.

### Principle IV — Goal-Driven Execution

**Status**: PASS.

- Every success criterion in `spec.md` § Success Criteria (`SC-001`…`SC-009`) is a verifiable check, mapped here to a concrete validation in § Technical Context → Testing / Validation.
- Phases below state explicit deliverables and verification:
  - Phase 0 → verify: every Phase-0 research item lists a Decision and a Verification step or open-question follow-up.
  - Phase 1 → verify: `data-model.md` enumerates every resource with an AVM-or-fallback decision; `contracts/*.schema.json` validate as legal JSON Schema; `quickstart.md` is end-to-end executable on a clean subscription.
  - Phase 2 (planning only, not execution) → verify: the task-generation strategy below names the categories of tasks that `/speckit.tasks` MUST produce.
- "Make it work" does not appear as a success criterion anywhere in this plan or the spec.

### Additional Constraints — Private-by-default networking

**Status**: PASS.

- The plan inherits `FR-023` and `SC-002` from the spec: every Foundry / AOAI / APIM / Cosmos / AI Search / Storage resource is provisioned with `publicNetworkAccess = Disabled` and APIM's public gateway disabled. The "deploy public, then disable" pattern is explicitly forbidden by spec and is not used.
- The two regional VNets are isolated; no VNet peering. The only cross-region link is APIM's outbound VNet integration in SC plus the APIM inbound PE in WE (cross-region private endpoint).

### Additional Constraints — Approved regions only

**Status**: PASS.

- The solution accepts only `westeurope`+`swedencentral` (default) or `eastus2`+`swedencentral` (alternate) per `FR-025` and the resolved clarification. Region mismatch between WE/EUS2 Foundry account and agent VNet, and between SC Foundry account and SC VNet, is rejected at parameter validation (`FR-007`, edge cases).

### Additional Constraints — Latest first-party models

**Status**: PASS.

- The model account lives in Sweden Central exactly so newly released first-party Azure OpenAI / Foundry models can be deployed on day one. The `MODEL_DEPLOYMENTS` parameter (`FR-012`, `FR-025`) is the operator-facing knob; no model version is pinned in the IaC.

### Additional Constraints — Single source of architectural truth

**Status**: PASS.

- The canonical architecture document is `005_architecture.md`. This plan, the spec, and all subsequent artifacts defer to it. No architectural decision is invented in `plan.md` that is not already present in `005_architecture.md` or recorded in `spec.md` § Clarifications.

### Development Workflow & Quality Gates

**Status**: PASS.

- *Plan gate*: this file lists assumptions (in § Technical Context, § Phase 0 Outputs, and inherited from `spec.md` § Assumptions) and a verification check for each phase.
- *Scope gate*, *Simplicity gate*, *Verification gate*: deferred to `/speckit.implement` PR-time enforcement (this is a planning artifact, not a code change).
- *Architecture gate*: triggered by any future plan or implementation that would change topology, PE placement, APIM routing, or DNS planes. This plan does not.
- *Complexity tracking*: see § Complexity Tracking below — currently empty (no principle violations).

### Aggregate result

**Constitution check (pre-Phase-0)**: ✅ PASS — no violations, no complexity-tracking entries required.

A post-Phase-1 re-check is recorded in § Progress Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/001-private-foundry-iac/
├── plan.md                      # This file (/speckit.plan output)
├── research.md                  # Phase 0 output — research notes & open questions
├── data-model.md                # Phase 1 output — resource topology & AVM-or-fallback decisions
├── quickstart.md                # Phase 1 output — 1-page operator walkthrough
├── contracts/                   # Phase 1 output — parameter & output contracts
│   ├── parameters.schema.json   # Operator-facing inputs (azd env vars / main.parameters.json)
│   └── outputs.schema.json      # main.bicep outputs surface
├── checklists/                  # (existing) per-feature checklists
└── spec.md                      # (existing) feature spec
```

`tasks.md` is *not* produced by `/speckit.plan`. It is produced by `/speckit.tasks` (next step).

### Source Code (repository root) — planned layout for `/speckit.implement`

```text
.
├── azure.yaml                                 # azd project manifest (root-level by azd convention)
├── infra/
│   ├── main.bicep                             # targetScope = 'subscription'; creates 2 RGs, dispatches per-region
│   ├── main.parameters.json                   # ${env:...} bindings to azd env vars
│   ├── modules/
│   │   ├── we-agent-plane.bicep               # WE stack: Foundry account+project, agent VNet+subnets,
│   │   │                                      #   BYO data plane (Cosmos / AI Search / Storage),
│   │   │                                      #   WE PEs, WE private DNS zones + VNet links,
│   │   │                                      #   APIM inbound PE on the WE VNet (cross-region PE).
│   │   ├── sc-model-plane.bicep               # SC stack: Foundry/AOAI model account, SC VNet+subnets,
│   │   │                                      #   SC PE on the model account,
│   │   │                                      #   SC private DNS zones + VNet links,
│   │   │                                      #   APIM Std v2 / Prem v2 with outbound VNet integration into SC VNet,
│   │   │                                      #   APIM policies (inbound + backend stacks).
│   │   └── wiring.bicep                       # Cross-region wiring: Foundry admin-connected model of type
│   │                                          #   `Azure API Management` on the WE project pointing at SC APIM;
│   │                                          #   role assignments (APIM MI → Cognitive Services OpenAI User on SC,
│   │                                          #   WE Foundry project MI → BYO data-plane RBAC).
│   └── policies/                              # APIM policy XML (loadTextContent target — see research.md)
│       ├── inbound.xml
│       └── backend.xml
└── hooks/                                     # azd lifecycle hooks (only if a Bicep gap forces a post-deploy step)
    └── postprovision.sh                       # OPTIONAL — only if Foundry connection authoring cannot be done in Bicep;
                                               #   final decision recorded in research.md.
```

**Structure Decision** (binding for `/speckit.tasks` and `/speckit.implement`):

- **`azure.yaml` location**: repository root, per the conventional `azd` template layout. Speckit does not require it to live under the feature directory.
- **One subscription-scoped entry point**: `infra/main.bicep` with `targetScope = 'subscription'`. It creates the two regional resource groups and instantiates `we-agent-plane.bicep`, `sc-model-plane.bicep`, and `wiring.bicep` as resource-group-scoped modules. The two regional resource group names are exposed as outputs.
- **Three composition modules + one wiring module** — the minimum that maps cleanly to the architecture's two planes plus the cross-region bridge. No "common helpers" module unless a second concrete caller forces it (Principle II).
- **AVM as the first preference inside each module**. Native `Microsoft.*` resources only as fallback, documented in `research.md` and inline.
- **Parameter contract** is owned by `main.bicep`. `main.parameters.json` binds `${env:AZURE_*}` and feature-specific env vars (`REGION_PAIR`, `NAME_PREFIX`, `WE_VNET_CIDR`, `SC_VNET_CIDR`, `APIM_SKU`, `MODEL_DEPLOYMENTS`, `ENABLE_SEMANTIC_CACHE`, `URL_PATH_STYLE`, `ENABLE_DYNAMIC_DISCOVERY`, optional BYO-DNS / BYO-LAW IDs). The full surface is the JSON Schema in `contracts/parameters.schema.json`.
- **Output contract** is owned by `main.bicep`. The schema is `contracts/outputs.schema.json`. Outputs include: two resource group names, the WE Foundry account + project resource IDs, the WE Foundry project endpoint, the APIM gateway hostname (private), the agent project's system-assigned MI principal ID, the APIM system-assigned MI principal ID, and the SC Foundry account resource ID.

## Phase 0 — Research / Unknowns

**Goal**: resolve every IaC-level unknown before module boundaries are committed. Output → `research.md`.

**Status**: research.md produced; see file for Decision / Rationale / Alternatives Considered per item.

**Inputs**:

- `spec.md` (decision-complete, 0 `[NEEDS CLARIFICATION]` markers).
- `005_architecture.md`.
- The constitution (private-by-default, AVM-first, approved regions, single source of architectural truth).
- The technical-stack commitments in this plan (§ Technical Context).

**Research items** (one entry per item in `research.md`):

1. **AVM coverage for Foundry account `projects` and Foundry `connections` sub-resources.** Does `avm/res/cognitive-services/account` (or any AVM module) currently model `Microsoft.CognitiveServices/accounts/projects` and `Microsoft.CognitiveServices/accounts/projects/connections`? If not, fall back to native `Microsoft.CognitiveServices/accounts/projects@<latest>` and `…/projects/connections@<latest>` with explicit, documented API versions.
2. **AVM coverage for APIM v2 SKUs.** Does `avm/res/api-management/service` expose Standard v2 / Premium v2 with (a) outbound VNet integration and (b) inbound private endpoint as first-class properties? Document fallback strategy if not (likely: AVM module for APIM service + native `Microsoft.Network/privateEndpoints` for the inbound PE; outbound VNet integration via the AVM property if exposed, otherwise via the native APIM service property).
3. **AVM coverage for cross-region private endpoints.** Confirm that `avm/res/network/private-endpoint` (or its equivalent) supports a PE whose region differs from the target resource's region — the APIM inbound PE is created in the WE agent VNet and points at an APIM instance in Sweden Central. (Microsoft documents this is supported by the platform; the question is whether the AVM module exposes any blocker.)
4. **Authoritative agent-subnet sizing for `Microsoft.App/environments` delegation.** Confirm the minimum prefix length, RFC1918 requirement, single-Foundry-account-per-subnet rule, and any other Microsoft-documented limits. Used to validate the `agent subnet CIDR` parameter.
5. **APIM policy authoring style in Bicep.** Decide between inline XML in `Microsoft.ApiManagement/service/policies@…` child resources versus `loadTextContent('./policies/inbound.xml')`. Pick one; document the rationale (readability, diffability, lint surface).
6. **Foundry admin-connected model of type `Azure API Management` — authoring path.** Confirm whether this can be authored via `Microsoft.CognitiveServices/accounts/projects/connections` in Bicep, or whether a post-provision `azd` hook is required (e.g., `az ai-foundry connection create` or an `az rest` PUT). Decide the path; if a hook is needed, document the hook script's idempotency and teardown behaviour.
7. **DNS zone ownership.** Default: solution creates new private DNS zones per region. Document the BYO-DNS path (operator passes existing zone resource IDs; solution creates VNet links / A-records only; never deletes the zones on `azd down`).
8. **Diagnostic settings target.** Document the optional BYO Log Analytics workspace wiring (resource ID parameter, optional; no LAW design or sizing in scope).

**Resolution criterion**: every item carries a Decision; items where the answer can be confirmed at this stage are CLOSED, items that depend on the live AVM registry at task-generation time are RESOLVED PROVISIONALLY with an explicit follow-up in `/speckit.tasks`.

**Output**: `research.md` with all items resolved or provisionally resolved with clear follow-up.

## Phase 1 — Design & Contracts

**Goal**: lock the resource topology and the operator-facing contracts before any Bicep is authored.

**Prerequisites**: Phase 0 complete (`research.md` present).

**Steps**:

1. **`data-model.md` (renamed conceptually to "topology" for an IaC project; the filename remains `data-model.md` to match the speckit template).** Enumerate every Azure resource the solution provisions, group by regional plane (WE / SC) and by role (network / data / identity / wiring), and for each resource record:
   - resource type and (planned) API version,
   - the AVM module reference (`br/public:avm/...`) if applicable, or "AVM gap — native fallback" with a one-line justification,
   - parent / child relationships,
   - which subnet / DNS zone / PE / role assignment it participates in,
   - the cross-region links it touches, if any (APIM inbound PE → APIM service; Foundry project → APIM via admin-connected model).

2. **`contracts/parameters.schema.json` — input contract.** A JSON Schema describing the operator-facing parameter surface, sourced from `FR-025` and the resolved clarifications: `regionPair`, `namePrefix`, VNet/subnet CIDRs (defaults + bounds), `apimSku`, `apimCapacity`, `modelDeployments` (array of `{name, model, version, sku, capacity}`), `urlPathStyle` (default `aoai`, alternate `openai`), `enableSemanticCache`, `enableDynamicDiscovery`, `developerPortalExposure`, optional `existingPrivateDnsZoneIds`, optional `logAnalyticsWorkspaceId`. Schema enforces:
   - `regionPair` ∈ `{westeurope+swedencentral, eastus2+swedencentral}`,
   - `apimSku` ∈ `{StandardV2, PremiumV2}` (other values rejected),
   - agent-subnet prefix length ≤ 27 (and RFC1918) once decomposed,
   - `modelDeployments` is a non-empty array.

3. **`contracts/outputs.schema.json` — output contract.** A JSON Schema describing what `main.bicep` emits. At minimum: `agentResourceGroupName`, `modelResourceGroupName`, `weFoundryAccountId`, `weFoundryProjectId`, `weFoundryProjectEndpoint`, `apimServiceId`, `apimGatewayHostname` (private hostname), `apimInboundPrivateEndpointId`, `scFoundryAccountId`, `agentProjectPrincipalId`, `apimPrincipalId`, and per-zone `privateDnsZoneIds` keyed by zone name.

4. **`quickstart.md` — operator walkthrough.** Prerequisites (`az`, Bicep, `azd`, subscription with the listed resource providers registered, AAD principal with the rights to create RBAC role assignments), `azd auth login`, `azd env new <env>`, set required env vars (referenced to `contracts/parameters.schema.json`), `azd up`, smoke test (private VM or Foundry Agent SDK call), `azd down`, troubleshooting hints (partial-failure redeploy, APIM provisioning time).

5. **Agent context update** — update the SPECKIT block in `.github/copilot-instructions.md` to point to this `plan.md`. Done as part of Phase 1 output (so downstream `/speckit.*` commands inherit the right plan reference).

**Output**: `data-model.md`, `contracts/parameters.schema.json`, `contracts/outputs.schema.json`, `quickstart.md`, updated `.github/copilot-instructions.md` SPECKIT block.

## Phase 2 — Task generation strategy (planning only)

Phase 2 is *not executed by `/speckit.plan`*. This section records the strategy that `/speckit.tasks` MUST follow, so the next command is deterministic.

**Task categories (in expected dependency order)**:

1. **Bootstrap** — `azure.yaml` at repo root, `infra/main.parameters.json` with `${env:...}` bindings, `.gitignore` entries for `.azure/`.
2. **`main.bicep` skeleton** — `targetScope = 'subscription'`, two resource groups (WE/EUS2 + SC), parameter declarations matching `contracts/parameters.schema.json`, parameter validation (`@allowed`, `@minLength`/`@maxLength`, custom validations for region pair / APIM SKU / agent-subnet prefix), output declarations matching `contracts/outputs.schema.json`.
3. **WE agent plane** (`infra/modules/we-agent-plane.bicep`) — VNet + two subnets, BYO data plane (Cosmos / AI Search / Storage) via AVM modules, Foundry account + project with system-assigned MI, all WE PEs, WE private DNS zones + VNet links. For each resource: AVM module call pinned to a concrete version, or documented native fallback. APIM inbound PE is created here (resource lives in the WE VNet) but its target reference points at the SC APIM service ID provided by `sc-model-plane.bicep` (cross-module input).
4. **SC model plane** (`infra/modules/sc-model-plane.bicep`) — VNet + two subnets, Foundry / AOAI account + model deployments, SC account PE, SC private DNS zones + VNet links, APIM service (Std v2 / Prem v2) with system-assigned MI and outbound VNet integration into the SC VNet, APIM policy stack (inbound + backend), policy parameterisation for the optional semantic-cache toggle.
5. **Wiring** (`infra/modules/wiring.bicep`) — role assignments (APIM MI → `Cognitive Services OpenAI User` on the SC Foundry account; WE Foundry project MI → BYO data-plane roles), Foundry admin-connected model of type `Azure API Management` on the WE project (Bicep-native or `azd` postprovision hook depending on research item #6).
6. **Validation hooks** (only if a Bicep gap forces them) — `azd` postprovision hook scripts (smoke inference call, public-access posture audit) + optional `azd predown` hook for any cleanup Bicep cannot do natively.
7. **Verification** — `az bicep build` clean, `azd provision --preview` clean from a fresh env, idempotency re-run, posture audit, smoke call.

**Estimated task count**: 25–35 tasks. `/speckit.tasks` MUST produce one task per resource group / module / wiring step / verification step, with explicit dependencies (e.g., "WE VNet before WE PEs"; "SC APIM before APIM inbound PE in WE VNet"; "all roles before Foundry connection").

**AVM version-pinning policy**: every AVM module reference MUST be pinned to an exact version at task-generation time. Patch versions MUST NOT be speculated by this plan — `/speckit.tasks` resolves them against the live registry.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified.

*(none — Constitution Check is PASS in all categories.)*

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|

## Progress Tracking

| Gate / Phase | Status | Notes |
|---|---|---|
| Constitution Check (pre-Phase-0) | ✅ PASS | See § Constitution Check. No violations. |
| Phase 0 — Research | ✅ COMPLETE | `research.md` produced; AVM-coverage items resolved provisionally pending registry check at `/speckit.tasks` time. |
| Phase 1 — Design & Contracts | ✅ COMPLETE | `data-model.md`, `contracts/parameters.schema.json`, `contracts/outputs.schema.json`, `quickstart.md` produced. `.github/copilot-instructions.md` SPECKIT block updated to reference this plan. |
| Constitution Check (post-Phase-1) | ✅ PASS | No new violations introduced by Phase 1 design. Module boundaries (3+1) remain the minimum needed; no speculative abstractions added. |
| Phase 2 — Task generation strategy | ✅ DOCUMENTED | Strategy recorded above; *execution* of task generation is `/speckit.tasks` (next command). |
| Phase 2 — Task generation execution | ✅ DONE | `tasks.md` generated by `/speckit.tasks` (40 tasks across 8 phases); subsequently remediated by `/speckit.analyze` (44 tasks total — added T-030a Cosmos data-plane SQL role, T-030b diagnostic settings, T-035a partial-failure recovery, T-035b region-pair switching; fixed wrong role GUID in T-029 + canonical `category = 'ApiManagement'` in T-031). AVM versions pinned against the live `mcr.microsoft.com/bicep/avm/...` registry; R-01, R-02, R-06 closed in `research.md` § R-A1 (Tasks-time addendum); stale per-section Status lines refreshed. Recommended next: `/speckit.implement`. |
| Phase 3 — Implementation | ✅ DONE | Bicep + AVM-first IaC authored under `infra/` (subscription-scoped `main.bicep` + 9 modules + 4 APIM policy fragments). `az bicep build infra/main.bicep` → 0 errors, ~42 warnings (all BCP081 preview-API-type and `core.windows.net` hardcoded-env-url from AVM internals, no actionable lints in solution code). Native fallbacks (T-014 Foundry project, T-030a Cosmos SQL role, T-031 Foundry connection, T-029/T-030 native role assignments via R-A2) all carry inline `// AVM gap:` comments with retire-when guidance. Hooks (`hooks/postprovision-audit.sh`, `hooks/postprovision-smoke.sh`) + inert fallback templates (`*.template`) + verification scripts (`scripts/verify-bicep.sh`, `whatif.sh`, `verify-idempotency.sh`, `abort-and-resume.sh`, `verify-region-pair-switch.sh`, `verify-teardown.sh`) authored. Quickstart polished with AVM pin table, native-fallback table, T-001 provider registration block, and the helper-script index. 43 of 44 tasks complete; T-001 stays `pending` (manual one-time operator step, documented in `quickstart.md` § Prerequisites). Bicep was NOT deployed against a live subscription per the user's explicit no-`azd up` / no-`azd provision` instruction. |

**Recommended next step**: run `/speckit.analyze` to cross-check the spec / plan / tasks for any drift (e.g. an FR or SC that no task implements, an `Implements:` reference to a non-existent FR), then `/speckit.implement` to author the Bicep, `azure.yaml`, `infra/main.parameters.json`, `infra/policies/*.xml`, and the postprovision hook against the pins captured in `research.md` § R-A1.

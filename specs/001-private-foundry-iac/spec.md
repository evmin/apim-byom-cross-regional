# Feature Specification: Bicep / AZD / AVM IaC for Private Foundry Agent with Cross-Region Model

**Feature Branch**: `001-private-foundry-iac`

**Created**: 2025-05-15

**Status**: Draft

**Input**: User description: "Design BICEP/AZD (azure developer cli)/Azure Verified Modules (AVM) solution for the task defined in 005_architecture.md"

**Source of WHAT**: The authoritative description of the target topology, network exposure rules, identity model, APIM policy stack, packet path, and Foundry wiring lives in `005_architecture.md` at the repository root. This specification translates that architecture into the *requirements that the Infrastructure-as-Code solution itself must satisfy* — it does not redesign the architecture and it does not prescribe how the Bicep templates are organised.

## User Scenarios & Testing *(mandatory)*

### Primary User

A **platform / infrastructure engineer** ("the operator") who:

- Has Owner (or equivalent custom RBAC) on a target Azure subscription.
- Has `azd` (Azure Developer CLI), `az`, and Bicep installed locally or in CI.
- Wants to bring up the entire private Foundry Agent + cross-region APIM + Sweden Central model topology with a single `azd up`, and tear it back down with a single `azd down`.
- Does not write Azure resource definitions by hand — they expect the solution to use Azure Verified Modules (AVM) wherever AVM coverage exists and to document any gap where it does not.
- Must be able to deploy the same code into different environments (dev / test / prod) and different region pairs by changing parameters / environment variables only.

---

### User Story 1 - Single-command private deployment (Priority: P1)

The operator clones the repository, sets a handful of required parameters (subscription, environment name, region pair, resource-name prefix), and runs `azd up`. The tool provisions the full topology described in `005_architecture.md` — the West Europe agent plane, the Sweden Central model plane, the cross-region APIM bridge with inbound private endpoint in the WE agent VNet, the BYO data plane, all private DNS zones with the correct per-region VNet links, the two managed identities with their role assignments, the APIM GenAI policy stack, and the Foundry `Azure API Management` admin-connected model wiring — and at no point during deployment is any resource publicly reachable.

**Why this priority**: This is the MVP. Without it the architecture in `005_architecture.md` cannot be reproduced. Every other story is a refinement of this one.

**Independent Test**: From a clean target subscription with no pre-existing resources in the target resource group(s), the operator runs `azd up` and observes (a) the command exits with success, (b) every Foundry / Azure OpenAI / APIM / Cosmos / AI Search / Storage resource it created reports `publicNetworkAccess = Disabled`, and (c) the WE agent project has a working `Azure API Management` connection that lists the configured Sweden Central model deployments.

**Acceptance Scenarios**:

1. **Given** a clean Azure subscription, `azd` and Bicep installed, and the required parameters set, **When** the operator runs `azd up`, **Then** the command completes successfully and the two regional stacks (WE agent plane, SC model plane) exist as described in the topology table of `005_architecture.md`.
2. **Given** a successful `azd up`, **When** the operator inspects each provisioned Foundry account, Azure OpenAI / Foundry model account, APIM instance, Cosmos DB account, AI Search service, and Storage account, **Then** every one of them reports `publicNetworkAccess = Disabled` (and APIM's public gateway is disabled).
3. **Given** a successful `azd up`, **When** the operator inspects the cross-region wiring, **Then** the APIM instance lives in Sweden Central, its outbound VNet integration is into the SC VNet's APIM-outbound delegated subnet, and its inbound private endpoint NIC is in the WE agent VNet's private-endpoint subnet, resolvable from the WE VNet via `privatelink.azure-api.net`.
4. **Given** a successful `azd up`, **When** the operator opens the WE Foundry project, **Then** an admin-connected model of type `Azure API Management` is configured with AAD auth, audience `https://cognitiveservices.azure.com/`, and the model deployments listed in the parameters.
5. **Given** a successful `azd up`, **When** the operator triggers a sample inference call against the configured model via the agent runtime, **Then** the call completes successfully and the entire packet path (agent runtime → WE PE for APIM → APIM gateway → APIM outbound VNet integration → SC PE for model account → model deployment) traverses only private IPs.

---

### User Story 2 - Reversible teardown (Priority: P1)

The operator runs `azd down` and the solution removes every resource it provisioned — across both regions, both VNets, both DNS planes, every private endpoint NIC, every role assignment, the APIM instance, the Foundry accounts, and the BYO data plane — with no orphaned private endpoints, no dangling private DNS A-records, and no leftover role assignments pointing at deleted principals.

**Why this priority**: Without reliable teardown, the solution is unusable for short-lived test environments and CI loops, and it accumulates cost and security drift. The deploy/teardown pair is the operator's primary lifecycle and must be symmetric. Treated as P1 because broken teardown blocks re-deployment.

**Independent Test**: After a successful `azd up`, the operator runs `azd down`; on completion they query the target subscription (via `az graph` or equivalent) for every resource type the solution provisions and confirm zero matching resources remain in the configured resource group(s), and that every private DNS zone managed by the solution has zero A-records left.

**Acceptance Scenarios**:

1. **Given** a healthy deployment from User Story 1, **When** the operator runs `azd down`, **Then** the command completes successfully and removes every resource the solution created in both regions.
2. **Given** `azd down` has completed, **When** the operator queries the private DNS zones managed by the solution, **Then** no A-records pointing at deleted private endpoints remain in any of the zones (`privatelink.openai.azure.com`, `privatelink.services.ai.azure.com`, `privatelink.cognitiveservices.azure.com`, `privatelink.search.windows.net`, `privatelink.blob.core.windows.net`, `privatelink.documents.azure.com`, `privatelink.azure-api.net`).
3. **Given** `azd down` has completed, **When** the operator queries role assignments on the SC Foundry / Azure OpenAI account and on the BYO data plane resources, **Then** no role assignments granted to managed identities created by the solution remain.

---

### User Story 3 - Idempotent re-run and parameterised re-targeting (Priority: P2)

The operator can re-run `azd up` on an already-deployed environment and observe a no-op (zero meaningful changes). They can also change parameters — for example switching the agent region from West Europe to East US 2, swapping the APIM SKU from Standard v2 to Premium v2, adding a model deployment to the list, or toggling semantic cache on — and re-running `azd up` reconciles the live deployment without requiring a full teardown.

**Why this priority**: Real operations require iterative change. The architecture explicitly supports two region pairs (WE+SC and EUS2+SC) and two APIM SKUs (Std v2 and Prem v2); model lists change; toggles flip. The solution must support all of this through parameters, not through code edits. P2 because it depends on P1 + P2 being reliable.

**Independent Test**: After a successful `azd up`, the operator immediately re-runs `azd up` with no parameter changes and confirms the deployment reports no significant changes. Then they change one parameter (e.g., add a model deployment, toggle the semantic cache, change the APIM SKU from Std v2 to Prem v2 within the same family) and re-run `azd up`; only the affected resources change, and the rest of the topology remains intact and still passes the User Story 1 acceptance checks.

**Acceptance Scenarios**:

1. **Given** a successful first `azd up`, **When** the operator immediately re-runs `azd up` with no parameter changes, **Then** the command completes successfully and no resource is recreated, deleted, or materially mutated.
2. **Given** a successful deployment, **When** the operator adds a new model deployment to the model list parameter and re-runs `azd up`, **Then** the new model deployment is created on the SC Foundry / Azure OpenAI account and the WE Foundry `Azure API Management` admin-connected model exposes it without recreating the APIM instance or the VNets.
3. **Given** a successful deployment, **When** the operator switches the agent region parameter from West Europe to East US 2 (and re-runs `azd up` against a different target environment / resource group), **Then** the same code produces an equivalent topology with the agent plane in East US 2 and the model plane still in Sweden Central, and all User Story 1 acceptance checks pass.

---

### User Story 4 - AVM-first composition with explicit gaps (Priority: P2)

When the operator inspects the Bicep solution, every resource type for which an Azure Verified Module exists is provisioned via the corresponding `br/public:avm/res/...` or `br/public:avm/ptn/...` AVM module. For every resource type where AVM coverage is missing or insufficient at the time of authoring, the solution falls back to native Bicep and explicitly documents the gap (which resource, why AVM is insufficient, what to revisit once AVM ships coverage).

**Why this priority**: AVM-first is a non-negotiable policy of this feature; it pins the solution to a supported, vetted module surface. P2 because it is a property of the implementation and is independently verifiable from the templates themselves, without requiring a deployed environment.

**Independent Test**: A static review of the IaC source produces (a) a list of every Azure resource type the solution provisions, (b) for each, whether it is provisioned via AVM, and (c) for every non-AVM resource, a short documented justification. The ratio of AVM-backed resource types is high and all gaps are explained.

**Acceptance Scenarios**:

1. **Given** the IaC source, **When** the operator (or a reviewer) lists every resource module reference, **Then** AVM modules (`br/public:avm/...`) are used for VNets, subnets, private endpoints, private DNS zones, private DNS zone VNet links, Cognitive Services accounts (Foundry / Azure OpenAI), API Management, Cosmos DB, AI Search, Storage Account, managed identities, and role assignments wherever a current AVM module exists.
2. **Given** a resource type where AVM coverage is missing or insufficient, **When** the operator opens the corresponding module/file, **Then** the deviation is justified in a short inline comment / README entry that names the resource and the reason.

---

### User Story 5 - End-to-end private-path validation (Priority: P3)

After `azd up` completes, the operator can run a documented post-deploy validation step that performs (a) a smoke inference call against one of the configured models through the agent project, and (b) a network-posture check that confirms no provisioned resource accepts public traffic. The validation is part of the `azd` lifecycle (e.g., an `azd up` postprovision hook or a documented `azd hooks run` invocation).

**Why this priority**: Provides confidence that the deployment actually realises the architectural intent (private path end-to-end) without relying on the operator to assemble manual checks. P3 because the deployment itself can be considered "done" on User Story 1; this is hardening.

**Independent Test**: Run the documented validation step against a fresh successful `azd up`; it issues a single chat-completion request through the agent and exits 0; it also iterates the provisioned resources and exits non-zero if any of them reports `publicNetworkAccess != Disabled` or has a public gateway / public endpoint enabled.

**Acceptance Scenarios**:

1. **Given** a successful `azd up`, **When** the operator runs the documented validation hook, **Then** a sample inference request to one of the configured Sweden Central model deployments returns a successful response.
2. **Given** a successful `azd up`, **When** the validation hook checks every Foundry / Azure OpenAI / APIM / Cosmos / AI Search / Storage resource it provisioned, **Then** every one of them reports public network access disabled (and APIM's public gateway is disabled).

---

### Edge Cases

- **Unsupported APIM SKU**: The operator passes `apimSku=BasicV2` (or any SKU that does not support inbound private endpoints, e.g., Developer, Consumption, classic Standard/Premium v1). The solution MUST fail fast at parameter validation / template compile time with a clear error stating that only Standard v2 or Premium v2 are supported, and MUST NOT begin provisioning resources.
- **Region mismatch between WE Foundry account and agent VNet**: An attempt to place the agent VNet (with the `Microsoft.App/environments`-delegated subnet) in a region different from the WE Foundry account's region MUST be rejected before any resource is created. The same applies to mismatches between the SC Foundry / Azure OpenAI model account and the SC VNet.
- **Unsupported region pair**: The solution MUST accept only the qualified region pairs (`westeurope` + `swedencentral`, or `eastus2` + `swedencentral`) and reject any other pair at parameter validation time.
- **Customer-owned private DNS zones**: The customer already owns one or more of the required `privatelink.*` zones (e.g., in a hub subscription). The solution MUST support a mode where the operator passes existing zone resource IDs and the solution only creates the VNet links / A-records into those zones rather than creating the zones themselves.
- **Private DNS zone conflict on link**: A `privatelink.*` zone the solution would create is already linked to the target VNet from another deployment. The solution MUST detect this and surface a clear, actionable error.
- **Subnet delegation conflict**: The configured agent subnet CIDR overlaps with an existing subnet, or an existing subnet is already delegated to a different service. The solution MUST detect this and fail before mutating the VNet.
- **Agent subnet sizing**: The agent subnet MUST be RFC1918, dedicated to a single Foundry account, with `/24` recommended and `/27` minimum; any smaller prefix MUST be rejected at parameter validation.
- **AVM module gap**: An Azure resource the solution must provision has no AVM module (or no module version that meets the requirements, e.g., does not yet expose a property the solution depends on). The solution MUST fall back to native Bicep for that resource only, document the gap, and continue to use AVM for everything else.
- **Partial failure redeploy**: A previous `azd up` failed midway (e.g., APIM provisioning succeeded but the inbound private endpoint did not). Re-running `azd up` MUST reconcile the partial state and reach the target topology without manual cleanup.
- **Capability host immutability**: Once the WE Foundry project's capability host has been provisioned with its agent VNet binding, the solution MUST NOT silently attempt to move it to a different region or different agent VNet on a later run; such a change MUST be surfaced as an explicit, breaking-change operation that requires re-deployment of a new environment.
- **`azd down` with externally created dependencies**: If the operator passed in pre-existing resources (e.g., a customer-owned private DNS zone, an existing Log Analytics workspace), `azd down` MUST NOT delete those externally owned resources; it MUST only remove what the solution itself created.
- **Quota / capacity unavailable**: APIM Standard v2 / Premium v2 capacity, or the model SKU in Sweden Central, is not available in the target subscription. The solution MUST surface the underlying Azure error clearly and MUST NOT leave half-created resources in an unrecoverable state.
- **API keys in runtime path**: The solution MUST NOT create or persist Azure OpenAI / Foundry / APIM subscription keys for the agent-to-model runtime path; only AAD (managed identity) authentication is permitted on that path.

## Requirements *(mandatory)*

### Functional Requirements

**Scope and lifecycle**

- **FR-001**: The solution MUST provision the entire topology described in `005_architecture.md` (rows 1–7 of the topology table) within a single `azd` environment via a single `azd up` invocation.
- **FR-002**: The solution MUST support `azd down` to remove every resource it created, in both regions, without leaving orphaned private endpoints, A-records in solution-managed DNS zones, or role assignments on solution-managed scopes.
- **FR-003**: `azd up` MUST be idempotent: re-running it against an already-converged deployment MUST result in zero material changes.
- **FR-004**: `azd up` MUST be recoverable: re-running it after a partial failure MUST reconcile state and reach the target topology without manual cleanup.

**Agent plane (West Europe by default, or East US 2)**

- **FR-005**: The solution MUST provision a Foundry Account and a Foundry Project in the agent region (WE by default, EUS2 alternate), with public network access disabled.
- **FR-006**: The solution MUST provision the agent VNet in the same region as the agent-region Foundry account, with two subnets: an agent subnet delegated to `Microsoft.App/environments` (recommended `/24`, minimum `/27`), and a private-endpoint subnet.
- **FR-007**: The solution MUST reject any configuration that places the agent-region Foundry account and the agent VNet in different regions.
- **FR-008**: The solution MUST provision a BYO data plane in the agent region — Cosmos DB account, AI Search service, Storage Account — each with public network access disabled and reached only via private endpoints in the agent VNet's PE subnet.
- **FR-009**: The solution MUST enable a **system-assigned** managed identity on the agent project (lifecycle-bound to the project resource; no pre-provisioned user-assigned identity is required) and MUST grant that system-assigned principal the necessary roles on the BYO data plane (Cosmos / AI Search / Storage) and on the agent-region Foundry account/project as required for the Agent Service.

**Model plane (Sweden Central)**

- **FR-010**: The solution MUST provision a Foundry / Azure OpenAI account in Sweden Central with public network access disabled, exposed only via a private endpoint on the `account` sub-resource in the SC VNet's PE subnet.
- **FR-011**: The solution MUST provision the SC VNet with two subnets: an APIM-outbound subnet (delegated as required for APIM Std v2 / Prem v2 outbound VNet integration), and a private-endpoint subnet.
- **FR-012**: The solution MUST provision the model deployments listed in the parameters on the SC Foundry / Azure OpenAI account.
- **FR-013**: The SC VNet MUST NOT be peered to the agent VNet; the two regional VNets remain isolated.

**APIM (cross-region bridge)**

- **FR-014**: The solution MUST provision an API Management instance in Sweden Central, on Standard v2 by default or Premium v2 on request, with:
  - outbound VNet integration into the SC VNet's APIM-outbound delegated subnet,
  - the public gateway disabled,
  - the developer portal disabled (or only privately reachable per the configured posture),
  - an inbound private endpoint NIC in the *agent VNet's* private-endpoint subnet (cross-region PE), resolved via `privatelink.azure-api.net` linked to the agent VNet.
- **FR-015**: The solution MUST reject APIM SKUs that do not support inbound private endpoints (Basic v2, Developer, Consumption, classic Standard/Premium v1) at parameter validation time, before any resource is created.
- **FR-016**: The solution MUST install on the APIM instance the GenAI-gateway policy stack described in `005_architecture.md`, in order:
  - inbound: `validate-azure-ad-token` (audience `https://cognitiveservices.azure.com/`, matching the agent project MI's client/application ID), `llm-token-limit`, optional `llm-semantic-cache-lookup` (when enabled by parameter), `set-backend-service`;
  - backend: `authentication-managed-identity` (resource `https://cognitiveservices.azure.com`, using APIM's own managed identity), optional `llm-semantic-cache-store` (when enabled by parameter).
- **FR-017**: The solution MUST enable a **system-assigned** managed identity on the APIM instance (lifecycle-bound to the APIM resource; no pre-provisioned user-assigned identity is required) and MUST grant that system-assigned principal `Cognitive Services OpenAI User` on the SC Foundry / Azure OpenAI account.

**Private DNS planes**

- **FR-018**: The solution MUST link the following private DNS zones to the **agent VNet** (only): `privatelink.services.ai.azure.com`, `privatelink.openai.azure.com`, `privatelink.cognitiveservices.azure.com`, `privatelink.search.windows.net`, `privatelink.blob.core.windows.net`, `privatelink.documents.azure.com`, `privatelink.azure-api.net`.
- **FR-019**: The solution MUST link the following private DNS zones to the **SC VNet** (only): `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com`, `privatelink.cognitiveservices.azure.com`.
- **FR-020**: The two DNS planes MUST NOT share zones or zone links; the solution MUST treat them as independent.
- **FR-021**: The solution MUST support a BYO-DNS mode: when the operator passes resource IDs of pre-existing private DNS zones, the solution MUST reuse them (creating only VNet links / A-records into them, never deleting them on `azd down`).

**Foundry wiring (BYOM via APIM)**

- **FR-022**: The solution MUST create on the WE Foundry project an Admin-connected model of type `Azure API Management`, wired to the SC APIM instance, with:
  - `authType: AAD` (managed identity, no API keys),
  - audience `https://cognitiveservices.azure.com/`,
  - the URL-path style configured by parameter — default `/deployments/{name}/chat/completions` (AOAI-style); `/chat/completions` (OpenAI-style) remains selectable,
  - the model deployment entries derived from the model list parameter,
  - optional static headers / API version as supplied by parameters,
  - static or dynamic model discovery as selected by parameter.

**Public-access posture (cross-cutting)**

- **FR-023**: At every stage of `azd up`, every Foundry account, Azure OpenAI / Foundry model account, APIM instance, Cosmos DB account, AI Search service, and Storage account provisioned by the solution MUST have public network access disabled. A "deploy with public access on, then disable" pattern is not acceptable.
- **FR-024**: The solution MUST NOT create or persist any subscription key, account key, connection string, or other shared-secret credential on the agent-to-model runtime path. All authentication on that path MUST be AAD via managed identity.

**Parameterisation surface**

- **FR-025**: The solution MUST expose the following parameters through `main.parameters.json` and/or `azd` environment variables (operator MUST be able to set every one of them without editing Bicep source):
  - target Azure subscription ID,
  - `azd` environment name,
  - `regionPair` — region pair (default `westeurope`+`swedencentral`; `eastus2`+`swedencentral` selectable),
  - resource-name prefix / naming inputs,
  - CIDR ranges per VNet (agent VNet, SC VNet) and per subnet (agent subnet, agent PE subnet, APIM-outbound subnet, SC PE subnet),
  - APIM SKU (Standard v2 / Premium v2) and capacity units,
  - list of model deployments to create on the SC account (name, model, version, SKU/capacity),
  - URL-path style for the Foundry `Azure API Management` connection (default `/deployments/{name}/chat/completions`; `/chat/completions` selectable),
  - toggle: semantic cache (off by default; on enables `llm-semantic-cache-lookup` / `llm-semantic-cache-store`),
  - toggle: dynamic vs static model discovery on the Foundry connection,
  - toggle: developer portal exposure (default: disabled),
  - optional inputs for BYO existing private DNS zones (resource IDs) and BYO Log Analytics workspace (resource ID).
- **FR-026**: Every parameter MUST have either a documented default or be explicitly marked required at parameter validation time; the solution MUST fail fast with a readable error when a required parameter is missing or invalid.

**AVM-first policy**

- **FR-027**: For every resource type provisioned by the solution where an Azure Verified Module (`br/public:avm/res/...` or `br/public:avm/ptn/...`) exists and is fit for purpose, the solution MUST use the AVM module rather than a hand-rolled resource block.
- **FR-028**: For every resource type where AVM coverage is missing or insufficient, the solution MUST document the gap (which resource, why, and what AVM version would close the gap if known) and fall back to native Bicep for that resource only.

**Validation hooks**

- **FR-029**: The solution MUST ship a documented post-provision validation step (e.g., an `azd` postprovision hook) that performs a smoke inference call against one of the configured model deployments through the agent project and a posture check that every provisioned resource has public network access disabled. The smoke call MUST be optional via parameter for environments where outbound calls are not desired.

### Key Entities *(infrastructure-level)*

- **Agent regional stack**: Foundry account + project in WE (or EUS2), agent VNet (agent subnet delegated to `Microsoft.App/environments` + PE subnet), BYO data plane (Cosmos DB, AI Search, Storage), private DNS zones listed in FR-018 with VNet links, agent project's managed identity and its role assignments, cross-region APIM inbound private endpoint NIC.
- **Model regional stack**: Foundry / Azure OpenAI account in SC + its model deployments, SC VNet (APIM-outbound subnet + PE subnet), private endpoint for the model account, private DNS zones listed in FR-019 with VNet links.
- **APIM bridge**: APIM Std v2 or Prem v2 instance in SC, outbound VNet integration into the SC VNet, inbound private endpoint NIC in the agent VNet, GenAI-gateway policy stack, APIM's managed identity, role assignment of that identity on the SC model account, Foundry `Azure API Management` admin-connected model on the WE project.
- **Identity model**: Two **system-assigned** managed identities — one on the agent project, one on the APIM instance — each lifecycle-bound to its host resource (no user-assigned identities and no pre-provisioning step), plus their RBAC role assignments and the AAD token audience used by APIM's `validate-azure-ad-token` policy.
- **`azd` environment**: The single `azure.yaml` + `infra/` + `main.parameters.json` + environment variables that bind the operator's lifecycle to all of the above.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a clean target subscription, a single `azd up` invocation produces the complete topology described in `005_architecture.md` and exits with success, without any manual intervention between phases.
- **SC-002**: After `azd up`, 100% of the Foundry accounts, Azure OpenAI / Foundry model accounts, APIM instances, Cosmos DB accounts, AI Search services, and Storage accounts provisioned by the solution report public network access disabled (and APIM's public gateway is disabled).
- **SC-003**: After `azd up`, an inference call from the agent runtime to one of the configured Sweden Central model deployments succeeds end-to-end and traverses only private IPs (no segment of the path traverses a public IP).
- **SC-004**: A second consecutive `azd up` with unchanged parameters reports zero material resource changes (true idempotency).
- **SC-005**: `azd down` removes 100% of the resources the solution created in both regions and leaves zero orphaned A-records in solution-managed private DNS zones and zero orphaned role assignments on solution-managed scopes.
- **SC-006**: Switching the region-pair parameter from WE+SC to EUS2+SC (or vice versa) and re-running `azd up` against a different `azd` environment produces an equivalent, fully private topology in the new region pair, with all of SC-001…SC-005 holding.
- **SC-007**: Of the Azure resource types the solution provisions, the ratio provisioned through Azure Verified Modules is high (target: ≥ 80% of resource types), and 100% of non-AVM resources are accompanied by an inline justification documenting the AVM gap.
- **SC-008**: No subscription key, account key, connection string, or other shared-secret credential is created or persisted by the solution on the agent-to-model runtime path; that path authenticates exclusively via AAD / managed identity.
- **SC-009**: Any attempt to deploy with an unsupported APIM SKU (Basic v2, Developer, Consumption, classic v1) or an unsupported region pair fails at parameter / template validation time, before any Azure resource is created.

## Assumptions

- **Subscription posture**: The target subscription has sufficient quota for APIM Standard v2 / Premium v2 in Sweden Central and for the requested model deployments; quota acquisition is the operator's responsibility and is out of scope of this feature.
- **Tooling**: `azd` (recent stable), Azure CLI, and Bicep CLI are available on the operator's workstation and in CI. The solution targets `azd`'s standard `infra/` + `azure.yaml` layout.
- **Naming**: Resource naming follows a parameter-driven prefix + standard Azure CAF abbreviation pattern; exact convention is a default that the operator can override via parameters.
- **CIDR defaults**: Default CIDR ranges for the two VNets and four subnets are RFC1918 ranges that satisfy FR-006 (agent subnet `/24` recommended, `/27` minimum); the operator can override any of them via parameters.
- **Semantic cache**: Defaults to OFF. The `llm-semantic-cache-lookup` / `llm-semantic-cache-store` policies are present but only enabled when the toggle is on.
- **Developer portal**: Defaults to disabled, matching the lockdown posture of `005_architecture.md`.
- **Egress control**: Out of scope. The operator brings their own egress control (or accepts the default Container Apps managed-identity egress in the WE agent VNet). The solution does not provision an Azure Firewall or any other egress-control resource. See *Out of Scope* below.
- **Model discovery**: Defaults to static discovery on the Foundry `Azure API Management` connection (simpler operator experience). Dynamic discovery via `/deployments` or `/models` is supported via the toggle.
- **Region pair default**: `westeurope` + `swedencentral` is the default; `eastus2` + `swedencentral` is the documented alternate, selectable via the `regionPair` parameter. Default CIDR examples, default-naming examples, and data-residency wording assume the WE+SC pair unless the operator selects EUS2+SC.
- **URL-path style default**: The Foundry `Azure API Management` admin-connected model defaults to the AOAI-style URL path `/deployments/{name}/chat/completions` (chosen so calls from the agent runtime are shaped identically to a direct Azure OpenAI call against the SC model account). The OpenAI-style `/chat/completions` is selectable via parameter for clients that prefer the OpenAI URL shape.
- **Managed-identity flavour**: Both the agent project MI and the APIM MI are **system-assigned** by default and by design for this feature (demo / single-environment posture). Lifecycle is bound to the host resource; role assignments are granted to the host's system-assigned principal at deploy time; no user-assigned identities are pre-created or referenced.
- **BYO data plane content**: The solution provisions empty Cosmos DB / AI Search / Storage Account resources; loading data into them is out of scope.
- **Observability**: The solution can accept a pre-existing Log Analytics workspace resource ID as a parameter and wire diagnostics settings to it, but designing/provisioning that workspace is out of scope.
- **Existing private DNS zones**: The solution can run in either "create the zones" or "reuse existing zones" mode based on parameters; in reuse mode, the existing zones are never deleted on `azd down`.
- **Capability host immutability**: The operator accepts that, once the WE Foundry project's capability host is provisioned and bound to an agent VNet, it cannot be moved later; changing region or agent VNet is a new-environment operation.
- **BYOM legal posture**: The operator accepts the BYOM Responsible-AI / content-safety responsibility shift described in `005_architecture.md`. The IaC itself does not encode or enforce this posture.

## Clarifications

### Session 2026-05-15

- Q: What should be the **default region pair** for the IaC deployment? → A: `westeurope` + `swedencentral` is the default; `eastus2` + `swedencentral` remains selectable via the `regionPair` parameter. Default CIDR/naming examples and data-residency wording assume WE+SC unless the operator picks EUS2+SC.
- Q: Should the agent project's managed identity and APIM's managed identity be **system-assigned** or **user-assigned**? → A: **System-assigned for both** (demo posture: simplest option, lifecycle bound to the host resource, no separate identity resources to pre-provision). Role assignments are granted to each host resource's system-assigned principal at deploy time; the user-assigned option is removed from the parameter surface.
- Q: Is the optional **Azure Firewall egress** on the WE agent VNet's egress path part of this feature? → A: **Out of scope.** The operator brings their own egress (or accepts the default Container Apps managed-identity egress). The optional firewall toggle is removed from the parameter surface and the related Bicep responsibilities are removed from this feature; egress control is recorded under *Out of Scope* as a future-extensibility note.
- Q: What should be the default **URL-path style** for the Foundry `Azure API Management` admin-connected model? → A: AOAI-style `/deployments/{name}/chat/completions` is the default; OpenAI-style `/chat/completions` remains selectable via parameter.

## Out of Scope

The following are explicitly **not** part of this feature and must not bleed into the spec, plan, or tasks:

- The agent's own code (skills, tools, prompts, orchestration logic).
- Model fine-tuning, evaluation pipelines, or model lifecycle management beyond `create the deployments listed in parameters`.
- Multi-tenant isolation beyond what AVM defaults and the architecture's lockdown posture already provide.
- ExpressRoute, hub-and-spoke peering, S2S/P2S VPN, or any cross-on-prem connectivity. The two regional VNets stay isolated; no peering is required.
- Observability stack *design*: a Log Analytics workspace resource ID may be passed in as a parameter and the solution may wire diagnostic settings to it, but designing, sizing, retention policy, dashboards, or alert rules for that workspace are out of scope.
- Data plane content: no documents, indexes, containers, blobs, or items are loaded into AI Search / Cosmos DB / Storage Account. Empty resources only.
- Agent SDK / client libraries, CI/CD pipelines for the agent code, deployment of any application-layer code via `azd up`.
- Production change-management policy (PR review, environment promotion gates, drift detection alerting) — these are operational concerns, not IaC requirements.
- Cost-management tooling (budgets, alerts, tagging policies beyond what is naturally produced by the AVM modules).
- Encoding the BYOM Responsible-AI / content-safety policy in the IaC.
- **Azure Firewall / egress control on the WE agent VNet**: The solution does not provision an Azure Firewall, NAT Gateway, or any other egress-control resource on the agent VNet. The operator brings their own egress (or accepts the default Container Apps managed-identity egress). This is recorded as a future-extensibility note for a follow-up feature; this feature does not expose any parameter or AVM module reference for it.
- **User-assigned managed identities**: The agent project MI and APIM MI are system-assigned only in this feature. Provisioning, referencing, or RBAC-binding user-assigned managed identities is out of scope for this feature and would be a follow-up extension.

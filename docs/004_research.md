# Design research — AVM coverage and IaC decisions

This page collects the design analysis behind the Bicep choices: which modules ship from Azure Verified Modules, where the IaC falls back to native Bicep, and why. It is a working reference, not a journal. Each section gives the decision, the rationale, and what was ruled out.

The high-level "why" lives in [`madr/`](./madr/). The full deployed topology lives in [`001_architecture.md`](./001_architecture.md). This page sits between them — module-level detail without the noise of historical task tracking.

## 1. AVM coverage for Foundry account, projects, and connections

**Decision.** Provision the Foundry / Cognitive Services account through AVM. Fall back to native Bicep for `Microsoft.CognitiveServices/accounts/projects` and `Microsoft.CognitiveServices/accounts/projects/connections`.

| Resource | Authored as | Pin |
|---|---|---|
| `Microsoft.CognitiveServices/accounts` | AVM `avm/res/cognitive-services/account` | `0.14.2` |
| `…/accounts/deployments` | AVM (via `deployments[]` param) | `0.14.2` |
| `…/accounts/projects@2025-06-01` | Native | n/a |
| `…/accounts/projects/connections@2025-06-01` | Native (in `infra/modules/foundry-connection.bicep`) | n/a |

**Rationale.** AVM `cognitive-services/account@0.14.2` authors `accounts` and `accounts/deployments` and exposes `allowProjectManagement`, but does not author `projects` or `projects/connections` as child types. The gap is small (two resource types, a handful of properties) so a thin native block is preferable to blocking on upstream.

**Connection schema.** The `connections@2025-06-01` API surface is a discriminated union on `authType`. This stack uses `ApiKey` (the Foundry Responses runtime rejects the connection with `400 "Connection not found"` when `authType=AAD`). The shared secret lives in `credentials.key` on the connection and in a `secret: true` APIM named value — APIM's inbound policy checks the inbound `api-key` header against the named value and falls through to AAD validation for non-key callers. See [`madr/0004-apim-dual-auth-policy-with-aad-fallthrough.md`](./madr/0004-apim-dual-auth-policy-with-aad-fallthrough.md) for the auth design.

**Retire-when.** Switch to AVM once a module ships first-class `projects[]` and nested `connections[]` coverage (target: `avm/res/cognitive-services/account` ≥ `0.15.x`, or a dedicated `avm/res/cognitive-services/account-project-connection`).

## 2. AVM coverage for APIM v2 with VNet integration and cross-region inbound PE

**Decision.** Use AVM `avm/res/api-management/service` for the APIM service itself. Author the cross-region inbound private endpoint as a separate AVM `private-endpoint` resource in the agent-region module.

| Concern | Authored as | Where |
|---|---|---|
| APIM service (Standard v2 / Premium v2) | AVM `avm/res/api-management/service@0.14.1` | `infra/modules/sc-model-plane.bicep` |
| Outbound VNet integration into SC subnet | AVM property: `subnetResourceId` → `properties.virtualNetworkConfiguration` | same module |
| `publicNetworkAccess = Disabled` | AVM property | same module |
| Developer portal disabled | AVM property: `enableDeveloperPortal = false` | same module |
| Inbound private endpoint (cross-region, in the agent VNet) | Separate AVM `avm/res/network/private-endpoint@0.12.1` | `infra/modules/we-agent-plane.bicep` |

**Rationale.** APIM v2 SKUs use the same `subnetResourceId` shape for outbound VNet integration that classic Premium did. The `privateEndpoints[]` first-class param on the AVM APIM module is *not* used here because the PE is in a different region than the service — it is authored in the agent-region module, which is where the agent VNet is provisioned.

**Watchpoint.** The optional APIM-outbound-subnet *delegation* requirement for v2 SKUs is ambiguous in Microsoft Learn. If `azd provision --preview` flags a delegation error, a native subnet `delegations[]` block on the SC VNet's APIM-outbound subnet is sufficient. No module replacement.

## 3. Cross-region private endpoint authoring

**Decision.** Author the APIM inbound PE in the agent VNet (`location = <agent region>`) targeting the APIM service in `swedencentral`. Same `Microsoft.Network/privateEndpoints` resource, region-agnostic `privateLinkServiceId`.

**Rationale.** The platform documents that an APIM inbound PE NIC may live in a region different from the APIM instance. AVM `private-endpoint@0.12.1` does not validate location equality; if a future module version regresses on that, the fallback is a native `Microsoft.Network/privateEndpoints` block with the same property shape.

**What was ruled out.**

- Putting APIM in the agent region. Defeats the design — APIM must be in Sweden Central to reach the model account over its own SC VNet integration.
- Adding a Standard Load Balancer with PrivateLink Service to "bridge" the regions. APIM v2 ships an inbound PE first-class; adding a PLS is unnecessary plumbing.

## 4. Agent-subnet sizing for `Microsoft.App/environments`

**Decision.** Enforce at parameter-validation time:

- Delegated to `Microsoft.App/environments` — no other delegation, no shared use.
- RFC1918.
- Prefix length **≤ /27** — `/24` recommended, `/27` minimum. The IaC rejects `/28` and smaller with a clear error.
- Dedicated to a single Foundry account — no multi-tenant sharing.
- Same region as the Foundry account that backs the capability host.

**Rationale.** These are non-negotiable platform constraints. Validation happens at parameter time so the failure mode is "deploy refuses to start" rather than "deploy fails halfway through after 30 minutes of APIM provisioning".

## 5. APIM policy authoring style

**Decision.** APIM policy XML lives in standalone files under `infra/policies/`. Bicep loads them with `loadTextContent()` and substitutes placeholder tokens via `replace()`.

| File | What's in it |
|---|---|
| `infra/policies/inbound.xml` | The always-on inbound policy stack: api-key gate, AAD fall-through, header strip, backend rewrite, managed-identity bearer. |
| `infra/policies/backend.xml` | The always-on backend policy stack. |
| `infra/policies/inbound-cache.xml` | The optional `llm-semantic-cache-lookup` fragment. Composed in when `ENABLE_SEMANTIC_CACHE=true`. |
| `infra/policies/backend-cache.xml` | The optional `llm-semantic-cache-store` fragment. Same toggle. |

**Rationale.** Policy XML is verbose; inline string literals balloon the Bicep file. Standalone files lint cleanly with XML tools, diff small, and let reviewers open them in their normal editor. The composition is in `infra/modules/apim-policy.bicep`.

**Placeholder tokens.** Tokens use the convention `{{UPPER_CASE}}` and are substituted by Bicep at deploy time. The `{{apim-byom-key}}` reference (kebab-case) is *not* a Bicep token — it is an APIM **named value** reference, resolved at gateway-execution time. The two conventions don't collide.

## 6. APIM named value for the shared api-key

**Decision.** Author a `Microsoft.ApiManagement/service/namedValues@2024-05-01` resource named `apim-byom-key` with `secret: true`. The value is `uniqueString(subscription().subscriptionId, azdEnvironmentName, namePrefix, 'apim-byom-key-v1')`, threaded through Bicep as a `@secure()` parameter, set on both the Foundry connection (`credentials.key`) and the APIM named value.

**Rationale.**

- No secret in source control. The value is derived deterministically at deploy time.
- Both the connection and the policy gate see the same value because it comes from the same Bicep expression.
- Rotation = redeploy. Both ends rotate atomically.

The inbound policy compares the request `api-key` header against `{{apim-byom-key}}` and skips AAD validation on match. AAD-only callers fall through to `validate-azure-ad-token`. See [`madr/0004-apim-dual-auth-policy-with-aad-fallthrough.md`](./madr/0004-apim-dual-auth-policy-with-aad-fallthrough.md).

## 7. DNS zone ownership — create-new and BYO

**Decision.** Default to create-new — the IaC provisions every `privatelink.*` zone the deployment needs in the appropriate region and links them to the right VNet. Operator-owned zones are supported via `existingPrivateDnsZoneIds` (a map of `zone-name → resource-ID`). In BYO mode the IaC creates only the VNet links and the A-records (via PE DNS-zone-group bindings). On `azd down`, only those links and records are removed; the operator-owned zones stay.

**Rationale.** A hub-and-spoke shop typically owns its `privatelink.*` zones in a hub subscription. Refusing to reuse them would force the solution into the hub's RBAC scope or require zone duplication.

## 8. Diagnostic settings — BYO only

**Decision.** The IaC accepts an optional `logAnalyticsWorkspaceId`. When set, the solution wires diagnostic settings on APIM, both Foundry / OpenAI accounts, and the BYO data-plane resources to that workspace. When unset, no diagnostic settings are created. The IaC does not provision a workspace, never sizes one, never sets retention, never authors dashboards or alert rules.

**Rationale.** Observability stack design is explicitly out of scope. Owning a workspace inside this feature would bleed scope and create a hidden architectural component.

## 9. Semantic-cache toggle composition

**Decision.** When `ENABLE_SEMANTIC_CACHE=true`, `infra/modules/apim-policy.bicep` splices `inbound-cache.xml` into the inbound stack before `set-backend-service`, and `backend-cache.xml` into the backend stack before `forward-request`. The composition happens in Bicep; the deployed policy XML literally does not contain the cache elements when the toggle is off.

**Rationale.**

- Keeps the always-on policy file clean.
- "Is the cache active in this environment?" is answerable by reading the deployed policy, not by inspecting an APIM `<choose>` branch.
- Avoids smuggling Bicep parameter expressions into APIM policy XML (which is fragile).

## 10. Default CIDR allocation

**Decision.** Non-overlapping RFC1918 defaults, well clear of typical hub ranges. Overridable per parameter.

| Block | CIDR |
|---|---|
| Agent VNet (`WE_VNET_CIDR`) | `10.40.0.0/20` |
| Agent subnet (`Microsoft.App/environments` delegated) | `10.40.0.0/24` |
| Agent PE subnet | `10.40.1.0/27` |
| SC VNet (`SC_VNET_CIDR`) | `10.50.0.0/20` |
| APIM-outbound delegated subnet | `10.50.0.0/27` |
| SC PE subnet | `10.50.1.0/27` |

**Rationale.** Comfortable RFC1918, well clear of common hub ranges like `10.0.0.0/16`. Agent subnet at the recommended `/24`. Both VNets at `/20` leave room for a dozen extra subnets per region without re-IP.

## 11. Role assignments — two native fallbacks

Role assignments span two unrelated Azure surfaces. The IaC has a native fallback for each.

**Azure RBAC (agent-RG and model-RG assignments).** AVM `authorization/role-assignment/rg-scope@0.1.1` does not expose `principalId`, `roleDefinitionIdOrName`, or `resourceId` on its params surface in a way that supports the assignments this stack needs (APIM MI → SC Foundry account, agent project MI → BYO data plane). The IaC authors these as native `Microsoft.Authorization/roleAssignments@2022-04-01` blocks in `infra/modules/rbac-agent-rg.bicep` and `infra/modules/rbac-model-rg.bicep`.

**Cosmos DB SQL data-plane.** The Cosmos data-plane role assignment is a *different* resource type — `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15` — and it references built-in Cosmos role definitions (well-known GUIDs under the Cosmos account), not generic Azure RBAC role definitions. AVM `document-db/database-account@0.19.0` exposes the account itself but does not author `sqlRoleAssignments` children. The IaC authors a single native block in `infra/modules/cosmos-sql-role-assignment.bicep`.

**Rationale.** Small surgical native blocks where AVM's parameter surface does not match the use case. Each block carries an inline `// AVM gap:` comment.

**Retire-when.** Drop the rg-scope native fallback once the AVM role-assignment module exposes the parameter surface we need. Drop the Cosmos data-plane native fallback once AVM ships `sqlRoleAssignments[]` coverage on the Cosmos account module (target: `avm/res/document-db/database-account >= 0.20.x`).

## Module pin summary

| AVM module | Pin |
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

All pins are stable SemVer (no `-alpha`, `-beta`, `-rc.*`). Pre-1.0 `0.y.z` versions are stable per the AVM publishing rule.

## See also

- [`001_architecture.md`](./001_architecture.md) — the full deployed topology.
- [`002_quickstart.md`](./002_quickstart.md) — deploy, verify, tear down.
- [`madr/`](./madr/) — Architecture Decision Records.

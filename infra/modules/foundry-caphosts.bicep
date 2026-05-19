// foundry-caphosts.bicep — Foundry Agent Service capability hosts.

// Authors the two capability-host sub-resources required for the Foundry
// "standard agent setup with private networking" topology:

// 1. Account-level capability host (`acctcaphost`)
// kind = Agents
// customerSubnet = MUST match `networkInjections[0].subnetArmId` on the
// Foundry account (the `agent-subnet` delegated to
// `Microsoft.App/environments`). Foundry's runtime
// provisions a managed Container Apps Environment in this
// subnet on first use.

// 2. Project-level capability host (`projcaphost`)
// kind = Agents
// aiServicesConnections = [ apim-byom ] (cross-region model bridge)
// threadStorageConnections = [ cosmos-byom ]
// storageConnections = [ storage-byom ]
// vectorStoreConnections = [ search-byom ]
// customerSubnet = NOT permitted on project caphost; Foundry
// returns `BadRequest: "CapabilityHost for
// Project cannot be created with Subnet"`
// if set.

// CRITICAL ordering:
// project caphost MUST be authored AFTER the account caphost (Foundry returns
// `UserError: Foundry Account capabilityHost Not Found` otherwise).
// `dependsOn:[acctcaphost]` enforces this.

// Capability hosts are also IMMUTABLE — `Update of capability is not currently
// supported` is returned for any PATCH. Bicep's incremental deploy is fine here
// because it always issues PUT, but a change to any property in this file
// requires a manual `az rest --method delete` of the corresponding caphost
// before the next `azd up`. Treat this as a breaking change.

// AVM gap: AVM `cognitive-services/account@0.14.2` does NOT author either
// capability-host child resource. Native fallback. Retire when
// AVM ships first-class coverage (target: `avm/res/cognitive-services/account`
// >= 0.15.x with `capabilityHosts[]`, or a dedicated AVM caphost module).

targetScope = 'resourceGroup'

@description('WE Foundry account name (parent of the account-level capability host).')
param weFoundryAccountName string

@description('WE Foundry project name (parent of the project-level capability host).')
param weFoundryProjectName string

@description('Agent subnet resource ID. MUST match `networkInjections[0].subnetArmId` on the Foundry account.')
param agentSubnetId string

@description('Project connection name for the cross-region model bridge (apim-byom).')
param apimConnectionName string

@description('Project connection name for the BYO Cosmos DB account (thread storage).')
param cosmosConnectionName string

@description('Project connection name for the BYO Storage account (file/system storage).')
param storageConnectionName string

@description('Project connection name for the BYO AI Search service (vector stores).')
param searchConnectionName string

// Existing parents.

resource weAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: weFoundryAccountName
}

resource weProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: weAccount
  name: weFoundryProjectName
}

// Account-level capability host — AUTO-CREATED by Foundry.
// When the Foundry account is created with `networkInjections`, the Foundry
// resource provider **auto-creates** an account-level capability host at
// `<accountName>@aml_aiagentservice` with `capabilityHostKind=Agents` and
// `customerSubnet=<networkInjections[0].subnetArmId>`. Attempting to PUT a
// second named caphost (e.g. `acctcaphost`) on the same account returns:
// "There is an existing Capability Host with name: …@aml_aiagentservice,
// provisioning state: Succeeded for workspace: …/<account>@AML/acctcaphost,
// cannot create a new Capability Host with name: acctcaphost for the same
// ClientId."
// So we do NOT author one here. The `existing` reference below is used only
// to gate the project capability host's `dependsOn` so Bicep waits for the
// auto-caphost to be Succeeded before authoring the project caphost (Foundry
// returns `UserError: Foundry Account capabilityHost Not Found` otherwise).
// The name `<accountName>@aml_aiagentservice` is deterministic per Foundry
// platform behavior.
resource accountCapabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-06-01' existing = {
  parent: weAccount
  name: '${weFoundryAccountName}@aml_aiagentservice'
}

// Project-level capability host.
// All four connection arrays MUST be populated for a standard-agent-setup with
// BYO data plane (a Foundry agent run will fail with `server_error` / 0 tokens
// until they are). Each name must match an existing connection on the project.
resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01' = {
  parent: weProject
  name: 'projcaphost'
  properties: {
    capabilityHostKind: 'Agents'
    aiServicesConnections: [
      apimConnectionName
    ]
    threadStorageConnections: [
      cosmosConnectionName
    ]
    storageConnections: [
      storageConnectionName
    ]
    vectorStoreConnections: [
      searchConnectionName
    ]
  }
  dependsOn: [
    accountCapabilityHost
  ]
}

output accountCapabilityHostId string = accountCapabilityHost.id
output accountCapabilityHostName string = accountCapabilityHost.name
output projectCapabilityHostId string = projectCapabilityHost.id

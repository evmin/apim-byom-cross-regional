// =============================================================================
// we-agent-plane.bicep — WE (or EUS2) agent-plane stack (resource-group scope).
// =============================================================================
//
// Provisions:
//   - agent VNet + delegated agent subnet + agent PE subnet (T-011)
//   - 7 WE private DNS zones + VNet links, BYO-aware (T-012)
//   - WE Foundry / Cognitive Services account via AVM (T-013)
//   - WE Foundry project via NATIVE Bicep (T-014, AVM gap — see R-01/R-A1)
//   - Cosmos DB / AI Search / Storage via AVM (T-015/16/17)
//   - PE for the WE Foundry account, with three-zone DNS group (T-018)
//   - PEs for Cosmos / AI Search / Storage (T-019)
//   - Cross-region APIM inbound PE in the WE PE subnet (T-020)
//   - Diagnostic settings (T-030b) — gated on logAnalyticsWorkspaceId
//
// AVM pins (resolved against the live registry — see research.md § R-A1):
//   br/public:avm/res/network/virtual-network:0.9.0
//   br/public:avm/res/network/private-dns-zone:0.8.1
//   br/public:avm/res/network/private-endpoint:0.12.1
//   br/public:avm/res/cognitive-services/account:0.14.2
//   br/public:avm/res/document-db/database-account:0.19.0
//   br/public:avm/res/search/search-service:0.12.1
//   br/public:avm/res/storage/storage-account:0.32.0
// =============================================================================

targetScope = 'resourceGroup'

// =============================================================================
// Parameters
// =============================================================================

@description('Lowercase short prefix (e.g., "myfdry") used in resource names.')
param namePrefix string

@description('azd environment name (e.g., "dev").')
param azdEnvironmentName string

@description('Short token for the agent region (we / eus2) used in account names.')
param agentRegionShort string

@description('Agent VNet CIDR.')
param weVnetCidr string

@description('Agent subnet CIDR (delegated to Microsoft.App/environments).')
param agentSubnetCidr string

@description('Agent PE subnet CIDR.')
param agentPeSubnetCidr string

@description('AzureBastion subnet CIDR (>= /26 required by platform; name MUST be exactly AzureBastionSubnet).')
param bastionSubnetCidr string = '10.40.2.0/26'

@description('Demo jumpbox subnet CIDR.')
param jumpboxSubnetCidr string = '10.40.3.0/27'

@description('BYO private DNS zone IDs (parsed object). Empty/absent key => create-new.')
param existingPrivateDnsZoneIds object

@description('Optional Log Analytics workspace resource ID. When non-empty, diagnostic settings are wired on every solution-managed resource (T-030b).')
param logAnalyticsWorkspaceId string

@description('Common tags stamped on every resource.')
param solutionTags object

// ---- Cross-region inputs (from sc-model-plane.bicep) ----
@description('SC APIM service resource ID — target of the cross-region inbound PE (T-020).')
param apimServiceId string

@description('SC APIM private gateway hostname (e.g., <apim-name>.azure-api.net) — used for output wiring.')
param apimGatewayHostname string

// =============================================================================
// Locals (naming, DNS zone topology, derived values)
// =============================================================================

var rgLocation = resourceGroup().location

// Naming.
var vnetName = '${namePrefix}-${azdEnvironmentName}-agent-${agentRegionShort}-vnet'
var agentSubnetName = 'agent-subnet'
var agentPeSubnetName = 'agent-pe-subnet'
// AzureBastion: subnet name is platform-enforced — do NOT parameterise.
var bastionSubnetName = 'AzureBastionSubnet'
var jumpboxSubnetName = 'jumpbox-subnet'

// CAF-style account names (must be globally unique for some types -> suffix with the
// RG resource ID hash to keep names stable across re-runs in the same env).
var uniq = take(uniqueString(resourceGroup().id, namePrefix, azdEnvironmentName), 6)

var weFoundryAccountName = '${namePrefix}${take(azdEnvironmentName, 6)}fdry${agentRegionShort}${uniq}'
var weFoundryProjectName = 'agent-project'

// BYO data-plane: Cosmos / AI Search / Storage. Storage account name has tight rules
// (lowercase, 3-24 chars, alphanumeric only) — take only the prefix + env + uniq + sa.
var cosmosAccountName = '${namePrefix}-${take(azdEnvironmentName, 8)}-cosmos-${uniq}'
var searchServiceName = '${namePrefix}-${take(azdEnvironmentName, 8)}-search-${uniq}'
// Storage: strip dashes, lowercase, max 24.
var storageAccountName = toLower(take('${namePrefix}${take(azdEnvironmentName, 6)}sa${uniq}', 24))

// DNS zones the WE VNet should resolve.
var weZoneNames = [
  'privatelink.services.ai.azure.com'      // W-Z1 Foundry-services
  'privatelink.openai.azure.com'           // W-Z2 AOAI
  'privatelink.cognitiveservices.azure.com' // W-Z3 Cognitive Services
  'privatelink.search.windows.net'          // W-Z4 AI Search
  'privatelink.blob.core.windows.net'       // W-Z5 Storage blob
  'privatelink.documents.azure.com'         // W-Z6 Cosmos
  'privatelink.azure-api.net'               // W-Z7 APIM (cross-region resolution)
]

// =============================================================================
// W-N1/W-N2/W-N3 — VNet + two subnets (T-011)
// =============================================================================
//
// AVM: br/public:avm/res/network/virtual-network:0.9.0
//
// The agent subnet is delegated to Microsoft.App/environments per FR-006 + R-04.
// The agent PE subnet hosts all WE PE NICs incl. the cross-region APIM inbound PE.
// =============================================================================

module vnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'we-vnet'
  params: {
    name: vnetName
    location: rgLocation
    tags: solutionTags
    addressPrefixes: [
      weVnetCidr
    ]
    subnets: [
      {
        name: agentSubnetName
        addressPrefix: agentSubnetCidr
        delegation: 'Microsoft.App/environments'
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: agentPeSubnetName
        addressPrefix: agentPeSubnetCidr
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        // AzureBastion-required subnet. /26 minimum. No NSG attached at the
        // subnet level here — Bastion manages its own ingress.
        name: bastionSubnetName
        addressPrefix: bastionSubnetCidr
      }
      {
        // Demo jumpbox subnet. NSG is attached by demo-jumpbox.bicep so the
        // NSG resource itself lives in the same RG and can be re-applied
        // idempotently on subsequent `azd up` runs.
        name: jumpboxSubnetName
        addressPrefix: jumpboxSubnetCidr
      }
    ]
  }
}

// Subnet IDs (recomputed locally — AVM module exposes a `subnetResourceIds[]` array
// but indexing into it is fragile across module versions; we compose directly).
var agentSubnetId = '${vnet.outputs.resourceId}/subnets/${agentSubnetName}'
var agentPeSubnetId = '${vnet.outputs.resourceId}/subnets/${agentPeSubnetName}'
var bastionSubnetId = '${vnet.outputs.resourceId}/subnets/${bastionSubnetName}'
var jumpboxSubnetId = '${vnet.outputs.resourceId}/subnets/${jumpboxSubnetName}'

// =============================================================================
// W-Z1..W-Z7 — Private DNS zones + VNet links (T-012)
// =============================================================================
//
// AVM: br/public:avm/res/network/private-dns-zone:0.8.1
//
// BYO-aware: for each zone name, if existingPrivateDnsZoneIds[name] is present
// and non-empty, we SKIP zone creation and author only a native VNet link as a
// child of the BYO zone. Otherwise we create the zone and link via AVM.
//
// The AVM PE module accepts a DNS zone group keyed off a zoneResourceId; both
// the AVM-created zone and the BYO zone are referenced via their resource IDs,
// so PE binding (T-018, T-019, T-020) is uniform regardless of provenance.
// =============================================================================

module weZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for zoneName in weZoneNames: if (!contains(existingPrivateDnsZoneIds, zoneName) || empty(existingPrivateDnsZoneIds[zoneName] ?? '')) {
  name: 'we-zone-${replace(zoneName, '.', '-')}'
  params: {
    name: zoneName
    tags: solutionTags
    virtualNetworkLinks: [
      {
        name: 'link-to-${vnetName}'
        virtualNetworkResourceId: vnet.outputs.resourceId
        registrationEnabled: false
      }
    ]
  }
}]

// BYO-DNS path — native VNet link as child of operator-owned zone.
// We split the zone ID to get the zone resource group + zone name.
resource byoZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for zoneName in weZoneNames: if (contains(existingPrivateDnsZoneIds, zoneName) && !empty(existingPrivateDnsZoneIds[zoneName] ?? '')) {
  // Scope the VNet link to the BYO zone via the resource ID. We cannot use the
  // child-resource shorthand because the parent zone lives in the operator's RG,
  // not this module's RG; we use the full name and a scope-existing reference.
  #disable-next-line use-parent-property
  name: '${last(split(existingPrivateDnsZoneIds[zoneName], '/'))}/link-to-${vnetName}'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.outputs.resourceId
    }
    registrationEnabled: false
  }
}]

// Effective zone ID lookup — used by PE DNS zone groups below.
var weZoneIdMap = {
  'privatelink.services.ai.azure.com': (contains(existingPrivateDnsZoneIds, 'privatelink.services.ai.azure.com') && !empty(existingPrivateDnsZoneIds['privatelink.services.ai.azure.com'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.services.ai.azure.com']
    : weZones[0].outputs.resourceId
  'privatelink.openai.azure.com': (contains(existingPrivateDnsZoneIds, 'privatelink.openai.azure.com') && !empty(existingPrivateDnsZoneIds['privatelink.openai.azure.com'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.openai.azure.com']
    : weZones[1].outputs.resourceId
  'privatelink.cognitiveservices.azure.com': (contains(existingPrivateDnsZoneIds, 'privatelink.cognitiveservices.azure.com') && !empty(existingPrivateDnsZoneIds['privatelink.cognitiveservices.azure.com'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.cognitiveservices.azure.com']
    : weZones[2].outputs.resourceId
  'privatelink.search.windows.net': (contains(existingPrivateDnsZoneIds, 'privatelink.search.windows.net') && !empty(existingPrivateDnsZoneIds['privatelink.search.windows.net'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.search.windows.net']
    : weZones[3].outputs.resourceId
  'privatelink.blob.core.windows.net': (contains(existingPrivateDnsZoneIds, 'privatelink.blob.core.windows.net') && !empty(existingPrivateDnsZoneIds['privatelink.blob.core.windows.net'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.blob.core.windows.net']
    : weZones[4].outputs.resourceId
  'privatelink.documents.azure.com': (contains(existingPrivateDnsZoneIds, 'privatelink.documents.azure.com') && !empty(existingPrivateDnsZoneIds['privatelink.documents.azure.com'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.documents.azure.com']
    : weZones[5].outputs.resourceId
  'privatelink.azure-api.net': (contains(existingPrivateDnsZoneIds, 'privatelink.azure-api.net') && !empty(existingPrivateDnsZoneIds['privatelink.azure-api.net'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.azure-api.net']
    : weZones[6].outputs.resourceId
}

// =============================================================================
// W-I1 — Agent Foundry / Cognitive Services account (T-013)
// =============================================================================
//
// AVM: br/public:avm/res/cognitive-services/account:0.14.2
// =============================================================================

// Network injection MUST be set at account creation time. Per Microsoft Foundry
// Agent Service docs:
//   "For Hosted agents, the virtual network configuration (network injection)
//    must be included when you first create the Foundry account. Adding network
//    injection to an existing Foundry account after creation isn't supported
//    for Hosted agents."
// — https://learn.microsoft.com/azure/ai-foundry/agents/how-to/virtual-networks
//
// The injected subnet MUST be the same agent-subnet that is delegated to
// `Microsoft.App/environments` (the account capability host's `customerSubnet`
// must match this value). Foundry's runtime provisions a managed Container
// Apps Environment into this subnet, so the subnet sizing rules from CAE apply
// (recommended /24; minimum /27 per the same doc).
module weFoundryAccount 'br/public:avm/res/cognitive-services/account:0.14.2' = {
  name: 'we-foundry-account'
  params: {
    name: weFoundryAccountName
    location: rgLocation
    tags: solutionTags
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: weFoundryAccountName
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    allowProjectManagement: true
    managedIdentities: {
      systemAssigned: true
    }
    networkInjections: {
      scenario: 'agent'
      subnetResourceId: agentSubnetId
      useMicrosoftManagedNetwork: false
    }
    diagnosticSettings: empty(logAnalyticsWorkspaceId) ? [] : [
      {
        name: 'we-foundry-account-diag'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// =============================================================================
// W-I2 — Agent Foundry project (T-014)
//
// AVM gap: AVM `cognitive-services/account@0.14.2` exposes `allowProjectManagement`
// but does NOT author `Microsoft.CognitiveServices/accounts/projects` children.
// Native fallback per research R-01 / Tasks-time addendum R-A1.
// Retire this native block once an AVM module ships first-class projects coverage
// (target: `avm/res/cognitive-services/account` >= 0.15.x with `projects[]` param,
// OR a dedicated `avm/res/cognitive-services/account-project` module).
// =============================================================================

// Reference the AVM-authored account by name so we can declare the project as
// a child resource via the parent/name shorthand.
resource weFoundryAccountExisting 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: weFoundryAccountName
  dependsOn: [
    weFoundryAccount
  ]
}

// AVM gap: see research.md R-01 / R-A1.
resource weFoundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: weFoundryAccountExisting
  name: weFoundryProjectName
  location: rgLocation
  tags: solutionTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Agent project (${azdEnvironmentName})'
    description: 'Private Foundry agent project provisioned by 001-private-foundry-iac.'
  }
}

// =============================================================================
// W-D1/W-D2/W-D3 — BYO data plane: Cosmos, AI Search, Storage (T-015/16/17)
// =============================================================================

module cosmos 'br/public:avm/res/document-db/database-account:0.19.0' = {
  name: 'we-cosmos'
  params: {
    name: cosmosAccountName
    location: rgLocation
    tags: solutionTags
    failoverLocations: [
      {
        locationName: rgLocation
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    networkRestrictions: {
      publicNetworkAccess: 'Disabled'
      ipRules: []
      virtualNetworkRules: []
    }
    disableKeyBasedMetadataWriteAccess: true
    disableLocalAuthentication: true
    capabilitiesToAdd: []
    diagnosticSettings: empty(logAnalyticsWorkspaceId) ? [] : [
      {
        name: 'we-cosmos-diag'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

module search 'br/public:avm/res/search/search-service:0.12.1' = {
  name: 'we-search'
  params: {
    name: searchServiceName
    location: rgLocation
    tags: solutionTags
    sku: 'basic'
    replicaCount: 1
    partitionCount: 1
    publicNetworkAccess: 'Disabled'
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    disableLocalAuth: false
    diagnosticSettings: empty(logAnalyticsWorkspaceId) ? [] : [
      {
        name: 'we-search-diag'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'we-storage'
  params: {
    name: storageAccountName
    location: rgLocation
    tags: solutionTags
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
    diagnosticSettings: empty(logAnalyticsWorkspaceId) ? [] : [
      {
        name: 'we-storage-diag'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// =============================================================================
// W-P1 — PE for the WE Foundry account (T-018)
// =============================================================================
//
// AVM: br/public:avm/res/network/private-endpoint:0.12.1
// groupIds: [ 'account' ]
// DNS zones: services.ai + openai + cognitiveservices (W-Z1, W-Z2, W-Z3)
// =============================================================================

module peWeFoundry 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'we-pe-foundry'
  params: {
    name: '${weFoundryAccountName}-pe'
    location: rgLocation
    tags: solutionTags
    subnetResourceId: agentPeSubnetId
    privateLinkServiceConnections: [
      {
        name: 'foundry-account-pls'
        properties: {
          privateLinkServiceId: weFoundryAccount.outputs.resourceId
          groupIds: [
            'account'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          name: 'services-ai'
          privateDnsZoneResourceId: weZoneIdMap['privatelink.services.ai.azure.com']
        }
        {
          name: 'openai'
          privateDnsZoneResourceId: weZoneIdMap['privatelink.openai.azure.com']
        }
        {
          name: 'cogsvc'
          privateDnsZoneResourceId: weZoneIdMap['privatelink.cognitiveservices.azure.com']
        }
      ]
    }
  }
}

// =============================================================================
// W-P2 / W-P3 / W-P4 — PEs for Cosmos / AI Search / Storage (T-019)
// =============================================================================

module peCosmos 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'we-pe-cosmos'
  params: {
    name: '${cosmosAccountName}-pe'
    location: rgLocation
    tags: solutionTags
    subnetResourceId: agentPeSubnetId
    privateLinkServiceConnections: [
      {
        name: 'cosmos-pls'
        properties: {
          privateLinkServiceId: cosmos.outputs.resourceId
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          name: 'documents'
          privateDnsZoneResourceId: weZoneIdMap['privatelink.documents.azure.com']
        }
      ]
    }
  }
}

module peSearch 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'we-pe-search'
  params: {
    name: '${searchServiceName}-pe'
    location: rgLocation
    tags: solutionTags
    subnetResourceId: agentPeSubnetId
    privateLinkServiceConnections: [
      {
        name: 'search-pls'
        properties: {
          privateLinkServiceId: search.outputs.resourceId
          groupIds: [
            'searchService'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          name: 'search'
          privateDnsZoneResourceId: weZoneIdMap['privatelink.search.windows.net']
        }
      ]
    }
  }
}

module peStorage 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'we-pe-storage'
  params: {
    name: '${storageAccountName}-pe'
    location: rgLocation
    tags: solutionTags
    subnetResourceId: agentPeSubnetId
    privateLinkServiceConnections: [
      {
        name: 'storage-blob-pls'
        properties: {
          privateLinkServiceId: storage.outputs.resourceId
          groupIds: [
            'blob'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          name: 'blob'
          privateDnsZoneResourceId: weZoneIdMap['privatelink.blob.core.windows.net']
        }
      ]
    }
  }
}

// =============================================================================
// W-P5 — Cross-region APIM inbound PE in the WE agent PE subnet (T-020)
// =============================================================================
//
// AVM: br/public:avm/res/network/private-endpoint:0.12.1
// PE `location` is the agent region (westeurope or eastus2), DIFFERENT from
// the APIM service's swedencentral. groupIds: [ 'Gateway' ].
// DNS zone binds privatelink.azure-api.net (W-Z7).
// =============================================================================

module peApimGateway 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'we-pe-apim-gateway'
  params: {
    name: '${namePrefix}-${azdEnvironmentName}-apim-gw-pe-${agentRegionShort}'
    location: rgLocation
    tags: solutionTags
    subnetResourceId: agentPeSubnetId
    privateLinkServiceConnections: [
      {
        name: 'apim-gateway-pls'
        properties: {
          privateLinkServiceId: apimServiceId
          groupIds: [
            'Gateway'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          name: 'azure-api-net'
          privateDnsZoneResourceId: weZoneIdMap['privatelink.azure-api.net']
        }
      ]
    }
  }
}

// =============================================================================
// Outputs — feed main.bicep and wiring.bicep
// =============================================================================

output agentVnetId string = vnet.outputs.resourceId
output agentSubnetId string = agentSubnetId
output agentPeSubnetId string = agentPeSubnetId
output bastionSubnetId string = bastionSubnetId
output jumpboxSubnetId string = jumpboxSubnetId

output weFoundryAccountId string = weFoundryAccount.outputs.resourceId
output weFoundryAccountName string = weFoundryAccountName

output weFoundryProjectId string = weFoundryProject.id
output weFoundryProjectName string = weFoundryProject.name
// AI Foundry **project** endpoint — required by the Azure AI Projects SDK
// (`AIProjectClient(endpoint=...)`). Format:
//   https://<account-name>.services.ai.azure.com/api/projects/<project-name>
//
// We deliberately construct this URL rather than re-using
// `weFoundryAccountExisting.properties.endpoint`, because that property
// returns the *account* endpoint (`https://<name>.cognitiveservices.azure.com/`)
// which is the Cognitive Services data-plane URL, not the per-project
// endpoint the AIProjectClient SDK expects. (And earlier revisions of this
// output emitted `https://` *twice* — the account endpoint already includes
// the scheme.)
output weFoundryProjectEndpoint string = 'https://${weFoundryAccountName}.services.ai.azure.com/api/projects/${weFoundryProjectName}'
// Cognitive Services account endpoint (without the duplicate scheme bug);
// surfaced for diagnostics — not the value the AIProjectClient SDK expects.
output weFoundryAccountEndpoint string = weFoundryAccountExisting.properties.endpoint

@description('System-assigned managed identity principalId of the WE Foundry project (W-I2). The principal APIM\'s validate-azure-ad-token policy validates.')
output agentProjectPrincipalId string = weFoundryProject.identity.principalId

output cosmosAccountId string = cosmos.outputs.resourceId
output cosmosAccountName string = cosmosAccountName

output searchServiceId string = search.outputs.resourceId
output searchServiceName string = searchServiceName

output storageAccountId string = storage.outputs.resourceId
output storageAccountName string = storageAccountName

output apimInboundPrivateEndpointId string = peApimGateway.outputs.resourceId

// Map of effective zone resource IDs (BYO or AVM-created) — surfaced for the
// solution-wide outputs.privateDnsZoneIds.we block.
output privateDnsZoneIds object = weZoneIdMap

// Echo the APIM gateway hostname for output wiring at the top level.
output apimGatewayHostnameEcho string = apimGatewayHostname

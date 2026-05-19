// sc-model-plane.bicep — Sweden Central model-plane stack (resource-group scope).

// Provisions:
// - SC VNet + APIM-outbound subnet + SC PE subnet
// - 3 SC private DNS zones + VNet links (BYO-aware)
// - SC Foundry / AOAI account + N model deployments via AVM
// - PE for the SC account, three-zone DNS group
// - APIM Std v2 / Prem v2 service with system-assigned MI, outbound VNet
// integration, publicNetworkAccess = Disabled
// - APIM service policy assembled from infra/policies/*.xml
// - Diagnostic settings — gated on logAnalyticsWorkspaceId

// AVM pins (resolved against the live registry):
// br/public:avm/res/network/virtual-network:0.9.0
// br/public:avm/res/network/private-dns-zone:0.8.1
// br/public:avm/res/network/private-endpoint:0.12.1
// br/public:avm/res/cognitive-services/account:0.14.2
// br/public:avm/res/api-management/service:0.14.1

targetScope = 'resourceGroup'

// Parameters

@description('Lowercase short prefix used in resource names.')
param namePrefix string

@description('azd environment name.')
param azdEnvironmentName string

@description('SC VNet CIDR.')
param scVnetCidr string

@description('APIM-outbound subnet CIDR.')
param apimOutboundSubnetCidr string

@description('SC PE subnet CIDR.')
param scPeSubnetCidr string

@description('APIM SKU.')
@allowed([
  'StandardV2'
  'PremiumV2'
])
param apimSku string

@description('APIM capacity units.')
@minValue(1)
@maxValue(12)
param apimCapacity int

@description('Model deployments to create on the SC account (already parsed array).')
param modelDeployments array

@description('APIM developer-portal exposure (disabled / privatePreviewOnly).')
@allowed([
  'disabled'
  'privatePreviewOnly'
])
param developerPortalExposure string

@description('BYO private DNS zone IDs (parsed object). Empty/absent key => create-new.')
param existingPrivateDnsZoneIds object

@description('Optional Log Analytics workspace resource ID for diagnostic settings.')
param logAnalyticsWorkspaceId string

@description('Common tags stamped on every resource.')
param solutionTags object

// Locals

var rgLocation = resourceGroup().location
var uniq = take(uniqueString(resourceGroup().id, namePrefix, azdEnvironmentName), 6)

var vnetName = '${namePrefix}-${azdEnvironmentName}-sc-vnet'
var apimOutboundSubnetName = 'apim-outbound-subnet'
var scPeSubnetName = 'sc-pe-subnet'
var apimOutboundNsgName = '${namePrefix}-${azdEnvironmentName}-apim-outbound-nsg'

var scFoundryAccountName = '${namePrefix}${take(azdEnvironmentName, 6)}fdrysc${uniq}'

// APIM service names must be globally unique (DNS) and 1-50 chars.
var apimServiceName = toLower(take('${namePrefix}-${azdEnvironmentName}-apim-sc-${uniq}', 50))

var scZoneNames = [
  'privatelink.openai.azure.com'            // C-Z1 AOAI
  'privatelink.services.ai.azure.com'       // C-Z2 Foundry-services
  'privatelink.cognitiveservices.azure.com' // C-Z3 Cognitive Services
]

// C-N1/C-N2/C-N3 — SC VNet + two subnets

// APIM v2 outbound VNet integration consumes the apim-outbound subnet by
// resource ID. APIM Std v2 / Prem v2 validation requires an NSG to be
// associated with the outbound subnet (the validator only checks presence; the
// default platform rules suffice for Std v2 with `virtualNetworkType=External`).
// SC VNet is NOT peered to the WE VNet.

resource apimOutboundNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: apimOutboundNsgName
  location: rgLocation
  tags: solutionTags
}

module vnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'sc-vnet'
  params: {
    name: vnetName
    location: rgLocation
    tags: solutionTags
    addressPrefixes: [
      scVnetCidr
    ]
    subnets: [
      {
        name: apimOutboundSubnetName
        addressPrefix: apimOutboundSubnetCidr
        privateEndpointNetworkPolicies: 'Disabled'
        networkSecurityGroupResourceId: apimOutboundNsg.id
        delegation: 'Microsoft.Web/serverFarms'
      }
      {
        name: scPeSubnetName
        addressPrefix: scPeSubnetCidr
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
  }
}

var apimOutboundSubnetId = '${vnet.outputs.resourceId}/subnets/${apimOutboundSubnetName}'
var scPeSubnetId = '${vnet.outputs.resourceId}/subnets/${scPeSubnetName}'

// C-Z1/C-Z2/C-Z3 — SC private DNS zones + VNet links

// The SC DNS plane is independent from the WE DNS plane. Zones live
// in this RG and are linked only to the SC VNet.

module scZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for zoneName in scZoneNames: if (!contains(existingPrivateDnsZoneIds, zoneName) || empty(existingPrivateDnsZoneIds[zoneName] ?? '')) {
  name: 'sc-zone-${replace(zoneName, '.', '-')}'
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
resource byoZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for zoneName in scZoneNames: if (contains(existingPrivateDnsZoneIds, zoneName) && !empty(existingPrivateDnsZoneIds[zoneName] ?? '')) {
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

var scZoneIdMap = {
  'privatelink.openai.azure.com': (contains(existingPrivateDnsZoneIds, 'privatelink.openai.azure.com') && !empty(existingPrivateDnsZoneIds['privatelink.openai.azure.com'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.openai.azure.com']
    : scZones[0].outputs.resourceId
  'privatelink.services.ai.azure.com': (contains(existingPrivateDnsZoneIds, 'privatelink.services.ai.azure.com') && !empty(existingPrivateDnsZoneIds['privatelink.services.ai.azure.com'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.services.ai.azure.com']
    : scZones[1].outputs.resourceId
  'privatelink.cognitiveservices.azure.com': (contains(existingPrivateDnsZoneIds, 'privatelink.cognitiveservices.azure.com') && !empty(existingPrivateDnsZoneIds['privatelink.cognitiveservices.azure.com'] ?? ''))
    ? existingPrivateDnsZoneIds['privatelink.cognitiveservices.azure.com']
    : scZones[2].outputs.resourceId
}

// C-I1 / C-I2 — SC Foundry / AOAI account + model deployments

module scFoundryAccount 'br/public:avm/res/cognitive-services/account:0.14.2' = {
  name: 'sc-foundry-account'
  params: {
    name: scFoundryAccountName
    location: rgLocation
    tags: solutionTags
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: scFoundryAccountName
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    // No managedIdentities block — SC Foundry account is a passive resource;
    // APIM MI is the principal that authenticates against it. Passing
    // `systemAssigned: false` triggers BCP / ARM-engine null-identity bug.
    deployments: [for d in modelDeployments: {
      name: d.name
      model: {
        format: 'OpenAI'
        name: d.model
        version: d.version
      }
      sku: {
        name: d.skuName
        capacity: d.skuCapacity
      }
    }]
    diagnosticSettings: empty(logAnalyticsWorkspaceId) ? [] : [
      {
        name: 'sc-foundry-account-diag'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// C-P1 — PE for SC model account

module peScAccount 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'sc-pe-account'
  params: {
    name: '${scFoundryAccountName}-pe'
    location: rgLocation
    tags: solutionTags
    subnetResourceId: scPeSubnetId
    privateLinkServiceConnections: [
      {
        name: 'sc-account-pls'
        properties: {
          privateLinkServiceId: scFoundryAccount.outputs.resourceId
          groupIds: [
            'account'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          name: 'openai'
          privateDnsZoneResourceId: scZoneIdMap['privatelink.openai.azure.com']
        }
        {
          name: 'services-ai'
          privateDnsZoneResourceId: scZoneIdMap['privatelink.services.ai.azure.com']
        }
        {
          name: 'cogsvc'
          privateDnsZoneResourceId: scZoneIdMap['privatelink.cognitiveservices.azure.com']
        }
      ]
    }
  }
}

// APIM service

// AVM: br/public:avm/res/api-management/service:0.14.1

module apim 'br/public:avm/res/api-management/service:0.14.1' = {
  name: 'sc-apim'
  params: {
    name: apimServiceName
    location: rgLocation
    tags: solutionTags
    sku: apimSku
    skuCapacity: apimCapacity
    publisherEmail: 'iac-noreply@${namePrefix}.invalid'
    publisherName: '${namePrefix} private foundry iac'
    // Azure-side constraint: APIM Std v2 / Prem v2 rejects publicNetworkAccess=
    // 'Disabled' at create time (ActivateServiceWithPrivateEndpointAccessNotAllowed).
    // We create with 'Enabled', then the postprovision-finalize hook patches it
    // to 'Disabled'. The inbound validate-azure-ad-token policy gates auth even
    // during the brief window between create and patch.
    publicNetworkAccess: 'Enabled'
    managedIdentities: {
      systemAssigned: true
    }
    // Outbound VNet integration into the apim-outbound subnet.
    virtualNetworkType: 'External'
    subnetResourceId: apimOutboundSubnetId
    // Developer portal disabled (developerPortalExposure resolves to disabled).
    enableDeveloperPortal: developerPortalExposure != 'disabled'
    diagnosticSettings: empty(logAnalyticsWorkspaceId) ? [] : [
      {
        name: 'sc-apim-diag'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// APIM 'openai' API + catchall operations

// The service-level policy (apim-policy.bicep) validates the project MI's
// `oid` claim and points the backend at the SC AOAI account, but APIM cannot
// route any request until there is at least one *API* resource whose `path`
// matches the URL prefix the caller uses. Foundry's `apim-byom` connection
// with `urlPathStyle: aoai` constructs URLs like
// `https://{apimGateway}/openai/deployments/{deployment}/chat/completions`,
// so we author an API with `path: openai` and two catchall operations
// (POST + GET on `/*`) to cover every AOAI verb/route.

// We deliberately leave `subscriptionRequired: false` — auth is enforced
// solely by the service-level validate-azure-ad-token policy, not by an
// APIM subscription key. The `serviceUrl` is the AOAI account's data-plane
// root with the `/openai` prefix; the service-level `set-backend-service`
// policy overrides it on every request (this default is only used by
// `Try it` in the developer portal).

resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
  dependsOn: [apim]
}

resource apimOpenAiApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apimService
  name: 'openai'
  properties: {
    displayName: 'OpenAI (BYOM via APIM)'
    path: 'openai'
    protocols: ['https']
    subscriptionRequired: false
    type: 'http'
    serviceUrl: 'https://${scFoundryAccountName}.openai.azure.com/openai'
  }
}

resource apimOpenAiCatchallPost 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apimOpenAiApi
  name: 'catchall-post'
  properties: {
    displayName: 'Catch-all POST'
    method: 'POST'
    urlTemplate: '/*'
  }
}

resource apimOpenAiCatchallGet 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apimOpenAiApi
  name: 'catchall-get'
  properties: {
    displayName: 'Catch-all GET'
    method: 'GET'
    urlTemplate: '/*'
  }
}

// Outputs

output scVnetId string = vnet.outputs.resourceId
output apimOutboundSubnetId string = apimOutboundSubnetId
output scPeSubnetId string = scPeSubnetId

output scFoundryAccountId string = scFoundryAccount.outputs.resourceId
output scFoundryAccountName string = scFoundryAccountName

output modelDeploymentNames array = [for d in modelDeployments: d.name]

output apimServiceId string = apim.outputs.resourceId
output apimServiceName string = apimServiceName
output apimPrincipalId string = apim.outputs.?systemAssignedMIPrincipalId ?? ''
output apimGatewayHostname string = '${apimServiceName}.azure-api.net'

output privateDnsZoneIds object = scZoneIdMap

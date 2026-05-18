// =============================================================================
// foundry-connection.bicep — native Foundry admin-connected model.
// =============================================================================
//
// AVM gap (T-031): AVM `cognitive-services/account@0.14.2` does not author
// `Microsoft.CognitiveServices/accounts/projects/connections` children. This
// module is the documented native fallback per research.md R-01 / R-06 / R-A1
// and data-model.md X-5.
//
// The connection is the "Azure API Management" admin-connected model on the
// WE Foundry project. Through it the agent runtime reaches the SC model
// deployments via the cross-region private path.
//
// Retire this module when an AVM module ships `projects/connections` coverage
// (target: a dedicated avm/res/cognitive-services/account-project-connection
// module, or `avm/res/cognitive-services/account` >= 0.15.x with `projects[]`
// + nested `connections[]` first-class params).
//
// `properties.category` MUST be `ApiManagement` (verified against the Foundry
// portal-authored example at R-A1 time). If Foundry rejects `ApiManagement` at
// deploy time, switch to `ModelGateway` (documented second-choice fallback)
// and record the working value in an inline comment.
// =============================================================================

targetScope = 'resourceGroup'

@description('WE Foundry account name (parent of the project).')
param weFoundryAccountName string

@description('WE Foundry project name (parent of the connection).')
param weFoundryProjectName string

@description('Connection name visible in the Foundry portal Connected Resources view.')
param connectionName string = 'apim-byom'

@description('APIM private gateway hostname (e.g., my-apim.azure-api.net).')
param apimGatewayHostname string

@description('APIM service resource ID — surfaced in connection metadata for cross-reference.')
param apimServiceId string

@description('Model deployment names — comma-joined into metadata.deployments for static discovery.')
param modelDeploymentNames array

@description('URL-path style: aoai or openai.')
@allowed([
  'aoai'
  'openai'
])
param urlPathStyle string

@description('When true, the connection uses dynamic discovery (APIM serves /deployments or /models).')
param enableDynamicDiscovery bool

// Existing parents — we author the connection as a grandchild of the account.
resource weAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: weFoundryAccountName
}

resource weProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: weAccount
  name: weFoundryProjectName
}

// AVM gap: see research.md R-01 / R-06 / R-A1.
// The 2025-06-01 type definition for projects/connections confirms
//   authType=AAD, target, category, metadata are all authorable.
// If Foundry rejects category='ApiManagement', try 'ModelGateway' (R-A1).
resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: weProject
  name: connectionName
  properties: {
    authType: 'AAD'
    category: 'ApiManagement'
    target: 'https://${apimGatewayHostname}'
    isSharedToAll: false
    metadata: {
      audience: 'https://cognitiveservices.azure.com/'
      urlPathStyle: urlPathStyle
      dynamicDiscovery: enableDynamicDiscovery ? 'true' : 'false'
      deployments: join(modelDeploymentNames, ',')
      location: 'swedencentral'
      apimServiceId: apimServiceId
    }
  }
}

output connectionId string = connection.id
output connectionName string = connection.name

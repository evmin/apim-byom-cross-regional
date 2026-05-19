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
// Connection schema follows the verified-working shape from
// microsoft-foundry/foundry-samples 01-connections/apim — specifically:
//   - authType: 'ApiKey' for private VNet standard agents (AAD is
//     internally mapped to ProjectManagedIdentity by the runtime, which
//     is rejected on private VNet setups)
//   - target MUST include the APIM API path (e.g. /openai) — without it
//     the Responses API returns 'Connection not found'
//   - metadata.models: JSON-stringified array with full model properties
//   - metadata.deploymentInPath: 'true' for AOAI-shape backends
//   - metadata.inferenceAPIVersion: GA AOAI API version
//
// `properties.category` MUST be `ApiManagement` (verified against the Foundry
// portal-authored example at R-A1 time and the foundry-cross-resource skill).
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

@description('APIM API path (e.g., openai). Appended to the gateway hostname in the connection target. Must match the APIM API resource path property.')
param apimApiPath string = 'openai'

@description('APIM subscription key for ApiKey auth. Required — the Responses API on private VNet standard agents only supports ApiKey, not AAD/PMI.')
@secure()
param apimSubscriptionKey string

@description('Full model deployment specs — needed to build the JSON-stringified models metadata with name, format, version, publisher.')
param modelDeployments array

@description('URL-path style: aoai or openai. Maps to metadata.deploymentInPath: aoai→true, openai→false.')
@allowed([
  'aoai'
  'openai'
])
param urlPathStyle string

// Existing parents — we author the connection as a grandchild of the account.
resource weAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: weFoundryAccountName
}

resource weProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: weAccount
  name: weFoundryProjectName
}

// Build the JSON-stringified models array required by the Foundry APIM connection.
// Each entry must carry the full model identity (name, format, version, publisher).
// The metadata.models value is a Dictionary<string, string> entry so the JSON array
// must be serialized as a string — NOT passed as a native Bicep array.
var modelsJsonEntries = [for d in modelDeployments: '{"name":"${d.name}","properties":{"model":{"name":"${d.model}","format":"OpenAI","version":"${d.version}","publisher":"Microsoft"}}}']
var modelsJsonString = '[${join(modelsJsonEntries, ',')}]'

// Connection schema: verified-working shape from foundry-cross-resource skill
// (live-verified 2026-04-23 against microsoft-foundry/foundry-samples).
resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: weProject
  name: connectionName
  properties: {
    authType: 'ApiKey'
    category: 'ApiManagement'
    target: 'https://${apimGatewayHostname}/${apimApiPath}'
    isSharedToAll: false
    credentials: {
      key: apimSubscriptionKey
    }
    metadata: {
      deploymentInPath: urlPathStyle == 'aoai' ? 'true' : 'false'
      inferenceAPIVersion: '2024-10-21'
      models: modelsJsonString
    }
  }
}

output connectionId string = connection.id
output connectionName string = connection.name

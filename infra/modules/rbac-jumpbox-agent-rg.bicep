// =============================================================================
// rbac-jumpbox-agent-rg.bicep — DJ-005 — agent-RG-scoped role assignments
// for the jumpbox UAMI.
// =============================================================================
//
// Authored against:
//   - the agent Foundry **project** (Microsoft.CognitiveServices/accounts/projects)
//     -> Azure AI Developer (64702f94-c441-49e6-a78b-ef80e0188fee)
//        Required for AIProjectClient.inference.get_chat_completions_client()
//        to enumerate connections and broker the inference call.
//   - the agent Foundry **account** (Microsoft.CognitiveServices/accounts)
//     -> Cognitive Services User (a97b65f3-24c7-4388-baec-2e87135dc908)
//        Required at the account level so the SDK can resolve the project.
//
// The jumpbox UAMI deliberately does NOT receive any role on APIM. This is
// what makes `smoke-reject.sh` a meaningful test — APIM's validate-azure-ad-
// token policy only accepts the agent project's MI oid, and a non-project
// caller must be rejected with 401/403.
//
// AVM gap (same as rbac-agent-rg.bicep): role-assignment AVM module's params
// surface is too narrow at v0.1.1; we use the native resource directly.
// =============================================================================

targetScope = 'resourceGroup'

@description('Jumpbox UAMI principalId.')
param principalId string

@description('Agent Foundry account name.')
param weFoundryAccountName string

@description('Agent Foundry project name (e.g. agent-project).')
param weFoundryProjectName string

var roleReader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var roleAzureAIDeveloper = '64702f94-c441-49e6-a78b-ef80e0188fee'
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource weFoundryAccountExisting 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: weFoundryAccountName
}

resource weFoundryProjectExisting 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: weFoundryAccountExisting
  name: weFoundryProjectName
}

resource raReaderAgentRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, principalId, roleReader)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleReader)
    description: 'Demo jumpbox UAMI needs Reader on the agent RG to drive `az resource list` from posture-from-vnet.sh.'
  }
}

resource raAIDeveloperProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: weFoundryProjectExisting
  name: guid(weFoundryProjectExisting.id, principalId, roleAzureAIDeveloper)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAzureAIDeveloper)
    description: 'Jumpbox UAMI needs Azure AI Developer on the agent project to drive AIProjectClient.'
  }
}

resource raCognitiveServicesUserAccount 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: weFoundryAccountExisting
  name: guid(weFoundryAccountExisting.id, principalId, roleCognitiveServicesUser)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    description: 'Jumpbox UAMI needs Cognitive Services User on the agent Foundry account so the project SDK can resolve and broker through the account.'
  }
}

output aiDeveloperRoleAssignmentId string = raAIDeveloperProject.id
output cogSvcUserRoleAssignmentId string = raCognitiveServicesUserAccount.id
output readerAgentRgRoleAssignmentId string = raReaderAgentRg.id

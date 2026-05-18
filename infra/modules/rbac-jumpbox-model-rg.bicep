// =============================================================================
// rbac-jumpbox-model-rg.bicep — DJ-005 — model-RG-scoped Reader for the
// jumpbox UAMI. Read-only access so posture-from-vnet.sh can enumerate the
// SC Foundry + APIM resources.
// =============================================================================

targetScope = 'resourceGroup'

@description('Jumpbox UAMI principalId.')
param principalId string

var roleReader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource raReaderModelRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, principalId, roleReader)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleReader)
    description: 'Demo jumpbox UAMI needs Reader on the model RG to drive `az resource list` from posture-from-vnet.sh.'
  }
}

output readerModelRgRoleAssignmentId string = raReaderModelRg.id

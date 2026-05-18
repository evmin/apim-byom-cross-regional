// =============================================================================
// rbac-model-rg.bicep — model-RG-scoped role assignments.
// =============================================================================
//
// Authors the APIM MI → Cognitive Services OpenAI User role assignment on the
// SC Foundry account (T-029 / X-3 of data-model.md).
//
// AVM gap (R-A2): avm/res/authorization/role-assignment/rg-scope:0.1.1 in this
// version does not expose `principalId`/`resourceId`/`roleDefinitionIdOrName`
// on its `params` struct — its param surface is limited to {name, condition,
// conditionVersion, delegatedManagedIdentityResourceId, enableTelemetry}. Use a
// native role-assignment resource so the assignment is unambiguous and scoped
// to the target resource (not the whole RG).
//
// Retire this native fallback when an AVM resource-scope role-assignment module
// ships with the full {principalId, roleDefinitionIdOrName, resourceId,
// principalType, description} surface (target: avm/res/authorization/
// role-assignment/resource-scope >= 0.x, or a future revision of rg-scope).
// =============================================================================

targetScope = 'resourceGroup'

@description('Existing SC Foundry / AOAI account name to scope the role assignment to.')
param scFoundryAccountName string

@description('APIM system-assigned MI principal ID (object id of the SP).')
param apimPrincipalId string

@description('Built-in role definition GUID for Cognitive Services OpenAI User.')
@allowed([
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
])
param roleCognitiveServicesOpenAIUser string

// CRITICAL: do NOT replace the role with `Cognitive Services User`
// (a97b65f3-24c7-4388-baec-2e87135dc908) — the authentication-managed-identity
// hop from APIM to Foundry/AOAI requires the *OpenAI User* role. data-model.md
// X-3 explicitly forbids the swap.

resource scFoundryExisting 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: scFoundryAccountName
}

resource raApimOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: scFoundryExisting
  name: guid(scFoundryExisting.id, apimPrincipalId, roleCognitiveServicesOpenAIUser)
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    description: 'APIM MI needs Cognitive Services OpenAI User on the SC Foundry account so authentication-managed-identity succeeds on the backend hop. Role GUID: 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd. DO NOT swap for a97b65f3-24c7-4388-baec-2e87135dc908 (wrong role).'
  }
}

output roleAssignmentId string = raApimOpenAiUser.id

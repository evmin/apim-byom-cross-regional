// =============================================================================
// rbac-agent-rg.bicep — agent-RG-scoped control-plane role assignments.
// =============================================================================
//
// Authors four control-plane role assignments for the WE Foundry project MI
// against the BYO data-plane stack (T-030 / X-4 control plane in
// data-model.md):
//   1. DocumentDB Account Contributor (Cosmos control plane)
//   2. Search Index Data Contributor (AI Search data)
//   3. Search Service Contributor (AI Search admin)
//   4. Storage Blob Data Contributor (Storage)
//
// The Cosmos *data plane* SQL role assignment is in cosmos-sql-role-assignment.bicep
// (separate native fallback per T-030a; AVM gap R-A1).
//
// AVM gap (R-A2): avm/res/authorization/role-assignment/rg-scope:0.1.1 does
// not expose the full {principalId, roleDefinitionIdOrName, resourceId} surface
// on its `params` struct. Native fallback per the same justification recorded
// in rbac-model-rg.bicep. Retire when AVM ships full resource-scope coverage.
// =============================================================================

targetScope = 'resourceGroup'

@description('WE Foundry project system-assigned MI principal ID.')
param weFoundryProjectPrincipalId string

@description('WE Cosmos DB account name (existing, BYO data plane).')
param weCosmosAccountName string

@description('WE AI Search service name (existing, BYO data plane).')
param weSearchServiceName string

@description('WE Storage account name (existing, BYO data plane).')
param weStorageAccountName string

// =============================================================================
// Built-in role definition IDs — control plane.
// =============================================================================

var roleDocumentDbAccountContributor   = '5bd9cd88-fe45-4216-938b-f97437e15450'
var roleCosmosDbOperator               = '230815da-be43-4aae-9cb4-875f7bd000aa'
var roleSearchIndexDataContributor     = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var roleSearchServiceContributor       = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var roleStorageBlobDataContributor     = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleStorageBlobDataOwner           = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleStorageAccountContributor      = '17d1049b-9a84-46fb-8f53-869881c3d3ab'

// =============================================================================
// Existing target resources.
// =============================================================================

resource cosmosExisting 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: weCosmosAccountName
}

resource searchExisting 'Microsoft.Search/searchServices@2024-03-01-preview' existing = {
  name: weSearchServiceName
}

resource storageExisting 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: weStorageAccountName
}

// =============================================================================
// Role assignments.
// =============================================================================

resource raCosmosControl 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cosmosExisting
  name: guid(cosmosExisting.id, weFoundryProjectPrincipalId, roleDocumentDbAccountContributor)
  properties: {
    principalId: weFoundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDocumentDbAccountContributor)
    description: 'WE Foundry project MI needs DocumentDB Account Contributor for control-plane operations on the BYO Cosmos account.'
  }
}

// Foundry standard agent setup additionally requires Cosmos DB Operator on the
// account so the runtime can provision the `enterprise_memory` database and the
// three required containers (agent-entity-store, thread-message-store,
// system-thread-message-store). Source: Microsoft Foundry standard-agent-setup docs.
resource raCosmosDbOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cosmosExisting
  name: guid(cosmosExisting.id, weFoundryProjectPrincipalId, roleCosmosDbOperator)
  properties: {
    principalId: weFoundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCosmosDbOperator)
    description: 'Foundry standard-agent-setup requires Cosmos DB Operator on the Cosmos account so the runtime can provision enterprise_memory DB and containers (1000 RU/s autoscale each).'
  }
}

resource raSearchIndex 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: searchExisting
  name: guid(searchExisting.id, weFoundryProjectPrincipalId, roleSearchIndexDataContributor)
  properties: {
    principalId: weFoundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    description: 'WE Foundry project MI needs Search Index Data Contributor on the BYO AI Search service.'
  }
}

resource raSearchService 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: searchExisting
  name: guid(searchExisting.id, weFoundryProjectPrincipalId, roleSearchServiceContributor)
  properties: {
    principalId: weFoundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    description: 'WE Foundry project MI needs Search Service Contributor on the BYO AI Search service.'
  }
}

resource raStorageBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageExisting
  name: guid(storageExisting.id, weFoundryProjectPrincipalId, roleStorageBlobDataContributor)
  properties: {
    principalId: weFoundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    description: 'WE Foundry project MI needs Storage Blob Data Contributor on the BYO Storage account.'
  }
}

// Foundry standard agent setup additionally requires Storage Blob Data Owner
// on the *-agents-blobstore container (provisioned by Foundry at runtime).
// We assign at account scope rather than container scope because the container
// name is workspace-id-derived and only known after the runtime starts.
resource raStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageExisting
  name: guid(storageExisting.id, weFoundryProjectPrincipalId, roleStorageBlobDataOwner)
  properties: {
    principalId: weFoundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataOwner)
    description: 'Foundry standard-agent-setup requires Storage Blob Data Owner on the workspaceId-agents-blobstore container; assigned at account scope so the role applies before Foundry creates that container.'
  }
}

// Foundry standard agent setup requires Storage Account Contributor (control
// plane) on the storage account so the runtime can author the two required
// blob containers (workspaceId-azureml-blobstore, workspaceId-agents-blobstore).
resource raStorageAccountContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageExisting
  name: guid(storageExisting.id, weFoundryProjectPrincipalId, roleStorageAccountContributor)
  properties: {
    principalId: weFoundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageAccountContributor)
    description: 'Foundry standard-agent-setup requires Storage Account Contributor so the runtime can create the workspaceId-prefixed blob containers it stores files and agent data in.'
  }
}

output cosmosControlRoleAssignmentId string = raCosmosControl.id
output cosmosDbOperatorRoleAssignmentId string = raCosmosDbOperator.id
output searchIndexRoleAssignmentId string = raSearchIndex.id
output searchServiceRoleAssignmentId string = raSearchService.id
output storageBlobRoleAssignmentId string = raStorageBlob.id
output storageBlobOwnerRoleAssignmentId string = raStorageBlobOwner.id
output storageAccountContributorRoleAssignmentId string = raStorageAccountContrib.id

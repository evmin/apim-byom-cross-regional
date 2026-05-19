// cosmos-sql-role-assignment.bicep — native Cosmos DB data-plane role assignment.

// AVM gap: document-db/database-account@0.19.0 exposes the account
// itself but does not author `databaseAccounts/sqlRoleAssignments` children.
// This module is the documented native fallback.

// The Cosmos SQL role assignment lives under
// Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15
// and uses Cosmos-specific role definitions (NOT the Microsoft.Authorization
// roleAssignment type). The built-in Cosmos DB Data Contributor role definition
// ID is the well-known GUID 00000000-0000-0000-0000-000000000002.

// Retire this module when AVM ships `sqlRoleAssignments[]` coverage on the
// Cosmos account module (target: avm/res/document-db/database-account >= 0.20.x).

targetScope = 'resourceGroup'

@description('Cosmos DB account name (the parent of the sqlRoleAssignments child resource).')
param cosmosAccountName string

@description('AAD principal ID to grant the data-plane role to (the WE Foundry project MI).')
param principalId string

@description('Cosmos data-plane role definition GUID (default: Cosmos DB Built-in Data Contributor).')
param roleDefinitionId string = '00000000-0000-0000-0000-000000000002'

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosAccountName
}

resource sqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${roleDefinitionId}'
    principalId: principalId
    scope: cosmos.id
  }
}

output id string = sqlRoleAssignment.id
output roleAssignmentName string = sqlRoleAssignment.name

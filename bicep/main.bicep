targetScope = 'resourceGroup'

@description('Prefix for the globally unique PostgreSQL server name.')
@minLength(3)
@maxLength(49)
param serverNamePrefix string = 'microhack-pg'

@description('PostgreSQL administrator login name.')
param administratorLogin string

@description('PostgreSQL administrator password.')
@secure()
param administratorLoginPassword string

@description('Client IPv4 address allowed through the PostgreSQL firewall.')
param clientIpAddress string

@description('PostgreSQL major version.')
@allowed([
  '16'
  '17'
  '18'
])
param postgresqlVersion string = '16'

@description('Azure Container Registry SKU.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param containerRegistrySku string = 'Basic'

@description('Container image repository and tag in the deployed registry.')
param containerImageName string = 'lego-catalog/app:latest'

@description('API key required by the performance test endpoint.')
@secure()
param performanceApiKey string

@description('OpenTelemetry OTLP endpoint used by the application.')
param otelExporterOtlpEndpoint string = 'http://localhost:4317'

@description('Deploy the Container App after its image and data are available.')
param deployContainerApp bool = true

@description('GitHub repository allowed to federate with the deployment identity, in owner/name format.')
param githubRepository string

var serverName = '${serverNamePrefix}-${uniqueString(resourceGroup().id)}'
var containerRegistryName = 'microhackacr${uniqueString(resourceGroup().id)}'
var storageAccountName = 'mhcatalog${uniqueString(resourceGroup().id)}'
var managedEnvironmentName = 'mh-catalog-environment'
var containerAppName = 'mh-catalog'
var loadTestName = 'mh-loadtest-${uniqueString(resourceGroup().id)}'
var workloadProfileName = 'Consumption'
var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var contributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
var containerAppFqdn = containerApp.?properties.?configuration.?ingress.?fqdn ?? ''

resource postgresqlServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: resourceGroup().location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    version: postgresqlVersion
    network: {
      publicNetworkAccess: 'Enabled'
    }
    storage: {
      storageSizeGB: 32
    }
  }
}

resource clientFirewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgresqlServer
  name: 'AllowClientIp'
  properties: {
    startIpAddress: clientIpAddress
    endIpAddress: clientIpAddress
  }
}

resource azureServicesFirewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgresqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: containerRegistryName
  location: resourceGroup().location
  sku: {
    name: containerRegistrySku
  }
}

resource containerAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'mh-catalog-identity'
  location: resourceGroup().location
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, containerAppIdentity.id, acrPullRoleDefinitionId)
  scope: containerRegistry
  properties: {
    principalId: containerAppIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource githubActionsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'mh-github-actions-identity'
  location: resourceGroup().location
}

resource githubMainFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: githubActionsIdentity
  name: 'github-main'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepository}:ref:refs/heads/main'
  }
}

resource githubActionsContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, githubActionsIdentity.id, contributorRoleDefinitionId)
  scope: resourceGroup()
  properties: {
    principalId: githubActionsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleDefinitionId
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: storageAccountName
  location: resourceGroup().location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-06-01' = {
  parent: storageAccount
  name: 'default'
}

resource seedFileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-06-01' = {
  parent: fileService
  name: 'seed'
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
    shareQuota: 5
  }
}

resource imagesFileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-06-01' = {
  parent: fileService
  name: 'images'
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
    shareQuota: 10
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: managedEnvironmentName
  location: resourceGroup().location
  properties: {
    workloadProfiles: [
      {
        name: workloadProfileName
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource seedEnvironmentStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: managedEnvironment
  name: 'seed-storage'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: seedFileShare.name
      accessMode: 'ReadOnly'
    }
  }
}

resource imagesEnvironmentStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: managedEnvironment
  name: 'images-storage'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: imagesFileShare.name
      accessMode: 'ReadOnly'
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = if (deployContainerApp) {
  name: containerAppName
  location: resourceGroup().location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerAppIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    workloadProfileName: workloadProfileName
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: containerAppIdentity.id
        }
      ]
      secrets: [
        {
          name: 'database-password'
          value: administratorLoginPassword
        }
        {
          name: 'performance-api-key'
          value: performanceApiKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'catalog'
          image: '${containerRegistry.properties.loginServer}/${containerImageName}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'CATALOG_DATABASE_HOST'
              value: postgresqlServer.properties.fullyQualifiedDomainName
            }
            {
              name: 'CATALOG_DATABASE_PORT'
              value: '5432'
            }
            {
              name: 'CATALOG_DATABASE_NAME'
              value: 'postgres'
            }
            {
              name: 'CATALOG_DATABASE_USERNAME'
              value: administratorLogin
            }
            {
              name: 'CATALOG_DATABASE_PASSWORD'
              secretRef: 'database-password'
            }
            {
              name: 'CATALOG_DATABASE_SSL_MODE'
              value: 'require'
            }
            {
              name: 'CATALOG_IMAGES_PATH'
              value: '/mnt/images'
            }
            {
              name: 'CATALOG_SEED_PATH'
              value: '/mnt/seed/catalog.json'
            }
            {
              name: 'PERFTEST_API_KEY'
              secretRef: 'performance-api-key'
            }
            {
              name: 'OTEL_EXPORTER_OTLP_ENDPOINT'
              value: otelExporterOtlpEndpoint
            }
            {
              name: 'OTEL_SERVICE_VERSION'
              value: containerImageName
            }
            {
              name: 'DEPLOYMENT_ENVIRONMENT'
              value: 'lab'
            }
            {
              name: 'OTEL_SDK_DISABLED'
              value: 'true'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'seed-volume'
              mountPath: '/mnt/seed'
            }
            {
              volumeName: 'images-volume'
              mountPath: '/mnt/images'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
        rules: [
          {
            name: 'http-scaling-rule'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'seed-volume'
          storageType: 'AzureFile'
          storageName: seedEnvironmentStorage.name
        }
        {
          name: 'images-volume'
          storageType: 'AzureFile'
          storageName: imagesEnvironmentStorage.name
        }
      ]
    }
  }
  dependsOn: [
    acrPullRoleAssignment
  ]
}

module loadTest 'br/public:avm/res/load-test-service/load-test:0.4.3' = {
  params: {
    name: loadTestName
    location: resourceGroup().location
  }
}

output serverName string = postgresqlServer.name
output serverFqdn string = postgresqlServer.properties.fullyQualifiedDomainName
output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output storageAccountName string = storageAccount.name
output seedFileShareName string = seedFileShare.name
output imagesFileShareName string = imagesFileShare.name
output containerAppUrl string = empty(containerAppFqdn) ? '' : 'https://${containerAppFqdn}'
output loadTestName string = loadTestName
output githubActionsIdentityClientId string = githubActionsIdentity.properties.clientId
output githubActionsIdentityPrincipalId string = githubActionsIdentity.properties.principalId
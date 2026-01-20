# Container Cosmos DB Monitoring with Managed Identity

A Helm chart for deploying applications with Azure Cosmos DB, Application Insights monitoring, and Managed Identity using Azure Service Operator (ASO) v2.

## Overview

This chart provisions:
- **Azure Cosmos DB** account, database, and container with private endpoint
- **Application Insights** with Log Analytics workspace for monitoring
- **Managed Identity** with workload identity federation
- **Kubernetes Deployment** with auto-instrumentation for distributed tracing

## Prerequisites

1. **AKS cluster** with:
   - OIDC issuer enabled
   - Workload identity enabled
   - Azure CNI networking

2. **ASO v2** installed and configured with credentials

3. **Platform ConfigMaps** (created by platform team):
   - `aso-platform-config` in `kube-public` namespace
   - Team-specific `aso-team-config` in your namespace

4. **OpenTelemetry Operator** (optional, for auto-instrumentation):
   ```bash
   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   ```

## Quick Start

### Minimal Configuration

Developers only need to specify:

```yaml
# team-b/cosmosdb-app.yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: my-api
  namespace: team-b
spec:
  chart:
    spec:
      chart: container-cosmosdb-monitoring-mi
      sourceRef:
        kind: HelmRepository
        name: platform-charts
      version: "0.x"
  values:
    appName: my-api
    resourceGroup: rg-team-b
```

### Full Configuration

```yaml
values:
  appName: "my-api"
  resourceGroup: "rg-team-b"
  port: 8080
  
  image:
    repository: "myregistry.azurecr.io/my-api"
    tag: "v1.0.0"
  
  cosmos:
    databaseName: "orders"
    containerName: "items"
    partitionKeyPath: "/customerId"
    throughput: 400
  
  monitoring:
    enabled: true
    retentionDays: 30
    autoInstrumentation:
      enabled: true
      language: "nodejs"  # java, nodejs, python, dotnet
```

## Values Reference

| Parameter                                 | Description                                      | Default               |
| ----------------------------------------- | ------------------------------------------------ | --------------------- |
| `appName`                                 | Application name (used for naming all resources) | `"myapp"`             |
| `resourceGroup`                           | Azure Resource Group for resources               | `"rg-team-resources"` |
| `port`                                    | Application port                                 | `8080`                |
| `image.repository`                        | Container image repository                       | `"nginx"`             |
| `image.tag`                               | Container image tag                              | `"1.25-alpine"`       |
| `cosmos.databaseName`                     | Cosmos DB database name                          | `"appdb"`             |
| `cosmos.containerName`                    | Cosmos DB container name                         | `"items"`             |
| `cosmos.partitionKeyPath`                 | Partition key path                               | `"/id"`               |
| `cosmos.throughput`                       | Provisioned throughput (RU/s), 0 for serverless  | `400`                 |
| `cosmos.consistencyLevel`                 | Consistency level                                | `"Session"`           |
| `monitoring.enabled`                      | Enable Application Insights                      | `true`                |
| `monitoring.retentionDays`                | Log retention in days                            | `30`                  |
| `monitoring.autoInstrumentation.enabled`  | Enable OpenTelemetry auto-instrumentation        | `true`                |
| `monitoring.autoInstrumentation.language` | Language for auto-instrumentation                | `"nodejs"`            |

## Infrastructure Discovery

The chart automatically discovers infrastructure configuration from ConfigMaps:

### Platform ConfigMap (kube-public/aso-platform-config)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-platform-config
  namespace: kube-public
data:
  oidcIssuerUrl: "https://eastus.oic.prod-aks.azure.com/..."
  cosmosDnsZoneId: "/subscriptions/.../privatelink.documents.azure.com"
```

### Team ConfigMap (team-namespace/aso-team-config)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-team-config
  namespace: team-b
data:
  privateEndpointSubnetId: "/subscriptions/.../subnets/private-endpoints"
  cosmosDnsZoneId: "/subscriptions/.../privatelink.documents.azure.com"
```

## Security Features

### Workload Identity
- Uses Azure AD workload identity federation
- No secrets stored in Kubernetes
- Managed identity with least-privilege access

### Private Networking
- Cosmos DB has public access disabled
- Access only via private endpoint
- Automatic DNS registration for private endpoint

### RBAC
- Cosmos DB Built-in Data Contributor role
- Scoped to the specific Cosmos DB account

## Auto-Instrumentation

When enabled, the chart adds OpenTelemetry annotations to the deployment for automatic distributed tracing:

| Language | Annotation                                               |
| -------- | -------------------------------------------------------- |
| Java     | `instrumentation.opentelemetry.io/inject-java: "true"`   |
| Node.js  | `instrumentation.opentelemetry.io/inject-nodejs: "true"` |
| Python   | `instrumentation.opentelemetry.io/inject-python: "true"` |
| .NET     | `instrumentation.opentelemetry.io/inject-dotnet: "true"` |

**Prerequisite**: OpenTelemetry Operator must be installed in the cluster.

## Environment Variables

Your application has access to these environment variables:

| Variable                                | Description                             |
| --------------------------------------- | --------------------------------------- |
| `COSMOS_ENDPOINT`                       | Cosmos DB account endpoint URL          |
| `COSMOS_DATABASE`                       | Database name                           |
| `COSMOS_CONTAINER`                      | Container name                          |
| `AZURE_CLIENT_ID`                       | Managed identity client ID for SDK auth |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | App Insights connection string          |
| `OTEL_SERVICE_NAME`                     | OpenTelemetry service name              |

## Application Code Example

### Node.js with Azure SDK

```javascript
const { CosmosClient } = require("@azure/cosmos");
const { DefaultAzureCredential } = require("@azure/identity");

// Uses AZURE_CLIENT_ID from environment
const credential = new DefaultAzureCredential();

const client = new CosmosClient({
  endpoint: process.env.COSMOS_ENDPOINT,
  aadCredentials: credential
});

const database = client.database(process.env.COSMOS_DATABASE);
const container = database.container(process.env.COSMOS_CONTAINER);

// Read an item
const { resource } = await container.item("item-id", "partition-key").read();
```

### Python with Azure SDK

```python
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
import os

credential = DefaultAzureCredential()

client = CosmosClient(
    url=os.environ["COSMOS_ENDPOINT"],
    credential=credential
)

database = client.get_database_client(os.environ["COSMOS_DATABASE"])
container = database.get_container_client(os.environ["COSMOS_CONTAINER"])

# Query items
items = list(container.query_items(
    query="SELECT * FROM c WHERE c.status = @status",
    parameters=[{"name": "@status", "value": "active"}]
))
```

## Troubleshooting

### Check ASO Resource Status

```bash
# View all resources
kubectl get databaseaccounts,sqldatabases,sqldatabasecontainers -n team-b

# Check for errors
kubectl describe databaseaccount my-api-cosmos -n team-b
```

### Common Issues

1. **ConfigMap not found**: Ensure platform and team ConfigMaps exist
2. **Identity not ready**: Wait for ASO to provision the managed identity
3. **Private endpoint pending**: DNS resolution may take a few minutes
4. **Auto-instrumentation not working**: Verify OpenTelemetry Operator is installed

## Chart Dependencies

This chart requires ASO v2 CRDs to be installed. It uses these ASO resource types:
- `managedidentity.azure.com/UserAssignedIdentity`
- `managedidentity.azure.com/FederatedIdentityCredential`
- `documentdb.azure.com/DatabaseAccount`
- `documentdb.azure.com/SqlDatabase`
- `documentdb.azure.com/SqlDatabaseContainer`
- `documentdb.azure.com/SqlRoleAssignment`
- `network.azure.com/PrivateEndpoint`
- `network.azure.com/PrivateEndpointsPrivateDnsZoneGroup`
- `operationalinsights.azure.com/Workspace`
- `insights.azure.com/Component`

---

## Disclaimer

**This documentation is provided "as is" without warranty of any kind.** The author takes no responsibility for any errors, omissions, or inaccuracies contained herein. This material may contain incorrect or outdated information. Always verify configurations against official Microsoft Azure and Kubernetes documentation before use in production environments. Use at your own risk.

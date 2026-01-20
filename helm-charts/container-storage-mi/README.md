# Container Storage with Managed Identity Helm Chart

This Helm chart creates an Azure Storage Account with Private Link and Managed Identity using Azure Service Operator v2 (ASO).

## Prerequisites

- Azure Service Operator v2 installed in the cluster
- ASO credentials configured in the target namespace
- AKS cluster with workload identity enabled
- Private DNS zones configured for blob storage
- **Platform ConfigMaps** created (see [Infrastructure ConfigMaps](#infrastructure-configmaps))

## Features

- **Storage Account**: Creates a storage account with public access disabled
- **Blob Container**: Creates a blob container within the storage account
- **Managed Identity**: Creates a User-Assigned Managed Identity
- **Workload Identity**: Configures federated credentials for Kubernetes workload identity
- **Role Assignment**: Grants Storage Blob Data Contributor role to the managed identity
- **Private Endpoint**: Creates a private endpoint for secure connectivity
- **Private DNS**: Registers the private endpoint in the private DNS zone
- **Deployment**: Deploys a container (nginx by default) with workload identity configured
- **ConfigMap Auto-Discovery**: Automatically reads infrastructure values from platform/team ConfigMaps

## Infrastructure ConfigMaps

This chart automatically reads infrastructure configuration from ConfigMaps, so developers don't need to know infrastructure details.

### Platform ConfigMap (created by platform team)

```yaml
# In kube-public namespace
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-platform-config
  namespace: kube-public
data:
  oidcIssuerUrl: "https://oidc.prod-aks.azure.com/..."
  location: "swedencentral"
  blobDnsZoneId: "/subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net"
  keyvaultDnsZoneId: "/subscriptions/.../privateDnsZones/privatelink.vaultcore.azure.net"
  cosmosdbDnsZoneId: "/subscriptions/.../privateDnsZones/privatelink.documents.azure.com"
  postgresqlDnsZoneId: "/subscriptions/.../privateDnsZones/privatelink.postgres.database.azure.com"
```

### Team ConfigMap (created by platform team, per namespace)

```yaml
# In each team namespace
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-team-config
  namespace: team-a
data:
  privateEndpointSubnetId: "/subscriptions/.../subnets/snet-team-a-pe"
  subscriptionId: "..."
```

## Quick Start (Developer Usage)

With ConfigMaps in place, developers only need to specify application-specific values:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: my-app
  namespace: team-a
spec:
  interval: 5m
  chart:
    spec:
      chart: container-storage-mi
      sourceRef:
        kind: HelmRepository
        name: acr-helm
        namespace: flux-system
  values:
    # Only these are required!
    appName: my-app
    resourceGroup: rg-team-a
```

That's it! All infrastructure values are auto-discovered from ConfigMaps.

## Installation

### From OCI Registry (Recommended for Flux)

```bash
# Push to ACR
helm package .
helm push container-storage-mi-1.0.0.tgz oci://<acr-name>.azurecr.io/helm

# Install from OCI
helm install my-storage oci://<acr-name>.azurecr.io/helm/container-storage-mi \
  --namespace team-a \
  --set appName=myapp \
  --set resourceGroup=rg-team-a \
  --set port=8080 \
  --set privateEndpointSubnetId="/subscriptions/.../subnets/snet-team-a-pe" \
  --set privateDnsZoneId="/subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net" \
  --set oidcIssuerUrl="https://oidc.prod-aks.azure.com/..."
```

### Using Flux HelmRelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: myapp-storage
  namespace: team-a
spec:
  interval: 5m
  chart:
    spec:
      chart: container-storage-mi
      version: "1.0.0"
      sourceRef:
        kind: HelmRepository
        name: acr-helm
        namespace: flux-system
  values:
    appName: myapp
    resourceGroup: rg-team-a
    port: 8080
    privateEndpointSubnetId: "/subscriptions/.../subnets/snet-team-a-pe"
    privateDnsZoneId: "/subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net"
    oidcIssuerUrl: "https://oidc.prod-aks.azure.com/..."
```

## Configuration

### Developer Values (Required)

| Parameter       | Description                                            | Default             |
| --------------- | ------------------------------------------------------ | ------------------- |
| `appName`       | Application name (used for naming Azure/K8s resources) | `myapp`             |
| `resourceGroup` | Azure Resource Group for resources                     | `rg-team-resources` |

### Developer Values (Optional)

| Parameter            | Description                           | Default        |
| -------------------- | ------------------------------------- | -------------- |
| `port`               | Application port                      | `8080`         |
| `image.repository`   | Container image                       | `nginx`        |
| `image.tag`          | Container image tag                   | `1.25-alpine`  |
| `storageAccountName` | Storage account name (auto-generated) | Auto-generated |
| `storageSku`         | Storage SKU                           | `Standard_LRS` |
| `storageKind`        | Storage kind                          | `StorageV2`    |
| `blobContainerName`  | Blob container name                   | `data`         |

### Infrastructure Values (Auto-Discovered from ConfigMaps)

These values are automatically read from platform/team ConfigMaps. Only specify if you need to override.

| Parameter                                   | Description                    | Source ConfigMap                  |
| ------------------------------------------- | ------------------------------ | --------------------------------- |
| `oidcIssuerUrl`                             | AKS OIDC issuer URL            | `kube-public/aso-platform-config` |
| `privateDnsZoneId`                          | Private DNS zone ID for blob   | `kube-public/aso-platform-config` |
| `privateEndpointSubnetId`                   | Subnet ID for private endpoint | `<namespace>/aso-team-config`     |
| `infrastructure.platformConfigMap`          | Platform ConfigMap name        | `aso-platform-config`             |
| `infrastructure.platformConfigMapNamespace` | Platform ConfigMap namespace   | `kube-public`                     |
| `infrastructure.teamConfigMap`              | Team ConfigMap name            | `aso-team-config`                 |

## Outputs

### Kubernetes Resources

- **ServiceAccount**: `sa-<appName>` - Use in pod specs for workload identity
- **ConfigMap**: `<appName>-storage-config` - Contains storage configuration
- **ConfigMap**: `<appName>-identity-config` - Contains identity IDs (principalId, clientId, tenantId)
- **Secret**: `<appName>-storage-secrets` - Contains blob endpoint URL

### Azure Resources

- **StorageAccount**: `st<appName><random>`
- **BlobContainer**: `<blobContainerName>`
- **UserAssignedIdentity**: `id-<appName>-storage`
- **FederatedIdentityCredential**: `id-<appName>-storage-fed-cred`
- **RoleAssignment**: Storage Blob Data Contributor
- **PrivateEndpoint**: `pe-<appName>-blob`

## Usage in Applications

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    spec:
      serviceAccountName: sa-myapp
      containers:
      - name: myapp
        image: myapp:latest
        envFrom:
        - configMapRef:
            name: myapp-storage-config
        env:
        - name: AZURE_STORAGE_BLOB_ENDPOINT
          valueFrom:
            secretKeyRef:
              name: myapp-storage-secrets
              key: blobEndpoint
        - name: AZURE_CLIENT_ID
          valueFrom:
            configMapKeyRef:
              name: myapp-identity-config
              key: clientId
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────────────────┐     │
│  │ ServiceAccount  │───▶│ Azure Managed Identity      │     │
│  │ (sa-myapp)      │    │ (id-myapp-storage)          │     │
│  └─────────────────┘    └──────────────┬──────────────┘     │
│           │                            │                     │
│           │ Workload Identity          │ Role Assignment     │
│           │ Federation                 │ (Blob Contributor)  │
│           ▼                            ▼                     │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                 Azure Storage Account                │    │
│  │                 (Private Endpoint)                   │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## Disclaimer

**This documentation is provided "as is" without warranty of any kind.** The author takes no responsibility for any errors, omissions, or inaccuracies contained herein. This material may contain incorrect or outdated information. Always verify configurations against official Microsoft Azure and Kubernetes documentation before use in production environments. Use at your own risk.

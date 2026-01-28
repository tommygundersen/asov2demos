# Installing AKS and Azure Service Operator v2 (Multi-Tenant)

This guide walks you through creating an Azure Kubernetes Service (AKS) cluster and installing Azure Service Operator v2 (ASO) using Azure CLI with **multi-tenant isolation**.

## Templating Approaches for ASO v2

There are several common approaches for templating and deploying ASO resources. This repository contains **working examples of all three main approaches**:

| Approach                                | Complexity | Flexibility | Best For                                    | Folder                      |
| --------------------------------------- | ---------- | ----------- | ------------------------------------------- | --------------------------- |
| **Helm + ConfigMap lookups** ✅          | Medium     | High        | Multi-tenant platforms, GitOps (this guide) | `/helm-charts/`             |
| **Kustomize overlays**                  | Low        | Medium      | Environment variations (dev/staging/prod)   | `/kustomize-overlays/`      |
| **Crossplane Compositions**             | High       | Very High   | Full platform engineering, custom APIs      | `/crossplane-compositions/` |
| Raw ASO manifests + GitOps substitution | Low        | Low         | Simple, direct usage                        | (not included)              |

> **📁 See the respective folders for complete working examples of each approach.**

### Approach Comparison

| Feature                  | Helm + ConfigMaps        | Kustomize Overlays | Crossplane           |
| ------------------------ | ------------------------ | ------------------ | -------------------- |
| **Templating**           | Go templates             | Patches & overlays | Schema-based patches |
| **Validation**           | Runtime only             | kubectl dry-run    | OpenAPI schema       |
| **Developer Experience** | HelmRelease YAML         | kustomization.yaml | Custom CRD Claims    |
| **Secret Propagation**   | Env vars from ConfigMaps | Manual             | ConnectionDetails    |
| **Learning Curve**       | Medium                   | Low                | High                 |
| **GitOps Integration**   | Flux HelmRelease         | Flux Kustomization | Native CRs           |

### Why Helm + ConfigMaps? (This Guide)

This approach separates concerns between **platform teams** and **developers**:

- **Platform team** manages infrastructure ConfigMaps with OIDC issuer URLs, DNS zone IDs, subnet IDs
- **Developers** only specify application values like `appName` and `resourceGroup`
- Works natively with Flux/ArgoCD GitOps workflows
- No additional tools beyond Helm required

### Chart Versioning & Updates

When the platform team publishes a new chart version, developers can control how updates are applied using **semver ranges** in their HelmRelease:

| Environment    | Version Strategy | Example             | Behavior                                  |
| -------------- | ---------------- | ------------------- | ----------------------------------------- |
| **Dev**        | Auto-update      | `version: "0.x"`    | Gets all 0.x updates automatically        |
| **Staging**    | Patch only       | `version: "~0.1.0"` | Auto-patches (0.1.1, 0.1.2), manual minor |
| **Production** | Pinned           | `version: "0.1.0"`  | Explicit update required                  |

**Example HelmRelease with auto-update:**
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
      version: "0.x"           # Auto-update within 0.x range
      sourceRef:
        kind: HelmRepository
        name: platform-charts  # Defined in flux-system (see Step 13)
        namespace: flux-system # Flux's shared resource namespace
      interval: 1m             # Check for new versions every minute
  values:
    appName: my-app
    resourceGroup: rg-team-a
```

**Update flow:**
1. Platform team pushes chart v0.2.0 to ACR
2. Flux detects new version (within `0.x` range)
3. Flux upgrades the HelmRelease automatically
4. ASO reconciles any changed Azure resources

> **Tip:** Use the Flux Notification Controller to alert teams via Slack/Teams when chart updates are applied.

> **Note:** For organizations building a full Internal Developer Platform with custom abstractions, consider **Crossplane** on top of ASO for stronger validation and simplified developer APIs.

---

## Architecture Overview

This setup uses a **single ASO deployment** with **per-namespace Azure Managed Identities** and **network isolation with private endpoints**:

### Identity & Namespace Isolation (Recommended Production Pattern)
- One shared ASO controller deployment in `azureserviceoperator-system`
- Each team/tenant gets their own Kubernetes namespace (e.g., `team-a`, `team-b`)
- **Each namespace has its own Managed Identity** with least-privilege RBAC scoped to that team's resources
- Each namespace has an `aso-credential` secret referencing that team's Managed Identity
- **Namespace is the security boundary** - ASO is deployed with Kubernetes RBAC that limits secret reads to the resource's namespace (the controller does not have cluster-wide secret read permissions)

> **✅ Security Model:** This follows the recommended production pattern for multi-tenant ASO deployments:
> - **Per-namespace credentials**: ASO reads the `aso-credential` secret from the resource's namespace ([ASO Credential Scope docs](https://azure.github.io/azure-service-operator/guide/authentication/credential-scope/))
> - **Workload Identity authentication**: No secrets stored, uses OIDC federation ([ASO Workload Identity docs](https://azure.github.io/azure-service-operator/guide/authentication/credential-format/#azure-workload-identity))
> - **Namespace isolation**: ASO's default RBAC does not grant cluster-wide secret read permissions
> 
> This isolation depends on correctly configured Kubernetes RBAC (no ClusterRoleBindings granting tenants cross-namespace access).

> **🔐 Key Insight:** Although we create one Managed Identity per team, all federated credentials point to the **same ASO controller service account** (`azureserviceoperator-system:azureserviceoperator-default`). This is because the ASO controller pod makes all Azure API calls - it reads the namespace-scoped secret to determine which identity to assume.

### Network Architecture
- **AKS VNet** (`vnet-aks`): Hosts the AKS cluster
- **Team A VNet** (`vnet-team-a`): For Team A's Azure resources with private endpoints
- **Team B VNet** (`vnet-team-b`): For Team B's Azure resources with private endpoints
- VNet peering enables connectivity between AKS and team VNets
- Private DNS zones linked to AKS VNet for name resolution of private endpoints

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Network Topology                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────────────┐      Peering      ┌─────────────────────┐              │
│  │   vnet-team-a       │◄─────────────────►│     vnet-aks        │              │
│  │   10.1.0.0/16       │                   │     10.0.0.0/16     │              │
│  │                     │                   │                     │              │
│  │  ┌───────────────┐  │                   │  ┌───────────────┐  │              │
│  │  │ Private       │  │                   │  │ AKS Cluster   │  │              │
│  │  │ Endpoints     │  │                   │  │ (nodes)       │  │              │
│  │  │ (Storage,     │  │                   │  └───────────────┘  │              │
│  │  │  KeyVault,    │  │                   │                     │              │
│  │  │  CosmosDB,    │  │      Peering      │  Private DNS Zones: │              │
│  │  │  PostgreSQL)  │  │                   │  - blob.core...     │              │
│  │  └───────────────┘  │                   │  - vault.azure...   │              │
│  └─────────────────────┘                   │  - cosmos.azure...  │              │
│                                            │  - postgres.azure.. │              │
│  ┌─────────────────────┐      Peering      │                     │              │
│  │   vnet-team-b       │◄─────────────────►│                     │              │
│  │   10.2.0.0/16       │                   └─────────────────────┘              │
│  │                     │                                                        │
│  │  ┌───────────────┐  │                                                        │
│  │  │ Private       │  │                                                        │
│  │  │ Endpoints     │  │                                                        │
│  │  └───────────────┘  │                                                        │
│  └─────────────────────┘                                                        │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     AKS Cluster                             │
├─────────────────────────────────────────────────────────────┤
│  azureserviceoperator-system (shared ASO controller)        │
│  └─ Uses WorkloadIdentityCredential                         │
├─────────────────────────────────────────────────────────────┤
│  team-a namespace          │  team-b namespace              │
│  ├─ aso-credential ────────┼─► aso-credential ──────────────│
│  │  → MI: team-a-aso-mi    │   → MI: team-b-aso-mi          │
│  └─ Azure resources        │   └─ Azure resources           │
│     (team-a identity)      │      (team-b identity)         │
└─────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
  ┌──────────────────┐          ┌──────────────────┐
  │ rg-team-a        │          │ rg-team-b        │
  │ (Team A's scope) │          │ (Team B's scope) │
  └──────────────────┘          └──────────────────┘
```

✅ **Namespace is the security boundary** - ASO cannot read secrets across namespaces

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/docs/intro/install/) v3 installed
- Azure subscriptions for each tenant/team with sufficient permissions to create resources

---

## Step 1: Set Environment Variables

Define the variables that will be used throughout this guide. Customize these values for your environment.

```bash
# Azure configuration
export RESOURCE_GROUP="rg-aso-demo"
export LOCATION="swedencentral"
export AKS_CLUSTER_NAME="aso-demo-aks"

# Network configuration
export AKS_VNET_NAME="vnet-aks"
export AKS_VNET_CIDR="10.0.0.0/16"
export AKS_SUBNET_NAME="snet-aks"
export AKS_SUBNET_CIDR="10.0.0.0/22"

# AKS networking - must not overlap with VNet CIDRs
export AKS_SERVICE_CIDR="172.16.0.0/16"
export AKS_DNS_SERVICE_IP="172.16.0.10"

export TEAM_A_VNET_NAME="vnet-team-a"
export TEAM_A_VNET_CIDR="10.1.0.0/16"
export TEAM_A_SUBNET_NAME="snet-team-a-pe"
export TEAM_A_SUBNET_CIDR="10.1.0.0/24"

export TEAM_B_VNET_NAME="vnet-team-b"
export TEAM_B_VNET_CIDR="10.2.0.0/16"
export TEAM_B_SUBNET_NAME="snet-team-b-pe"
export TEAM_B_SUBNET_CIDR="10.2.0.0/24"

# ASO authentication (will be set after creating the service principal)
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
```

---

## Step 2: Login to Azure

Authenticate with Azure CLI if you haven't already.

```bash
az login
```

Set your subscription (if you have multiple):

```bash
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
```

---

## Step 3: Create Resource Group and Network Infrastructure

Create a resource group and set up the network infrastructure with VNets for AKS and each team.

### Create Resource Group

```bash
az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION
```

### Create AKS VNet and Subnet

```bash
# Create AKS VNet
az network vnet create \
    --resource-group $RESOURCE_GROUP \
    --name $AKS_VNET_NAME \
    --address-prefix $AKS_VNET_CIDR \
    --location $LOCATION

# Create AKS subnet
az network vnet subnet create \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $AKS_VNET_NAME \
    --name $AKS_SUBNET_NAME \
    --address-prefix $AKS_SUBNET_CIDR

# Get the subnet ID for AKS
export AKS_SUBNET_ID=$(az network vnet subnet show \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $AKS_VNET_NAME \
    --name $AKS_SUBNET_NAME \
    --query id -o tsv)
```

### Create Team A VNet and Subnet (for Private Endpoints)

```bash
# Create Team A VNet
az network vnet create \
    --resource-group $RESOURCE_GROUP \
    --name $TEAM_A_VNET_NAME \
    --address-prefix $TEAM_A_VNET_CIDR \
    --location $LOCATION

# Create Team A subnet for private endpoints
az network vnet subnet create \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $TEAM_A_VNET_NAME \
    --name $TEAM_A_SUBNET_NAME \
    --address-prefix $TEAM_A_SUBNET_CIDR
```

### Create Team B VNet and Subnet (for Private Endpoints)

```bash
# Create Team B VNet
az network vnet create \
    --resource-group $RESOURCE_GROUP \
    --name $TEAM_B_VNET_NAME \
    --address-prefix $TEAM_B_VNET_CIDR \
    --location $LOCATION

# Create Team B subnet for private endpoints
az network vnet subnet create \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $TEAM_B_VNET_NAME \
    --name $TEAM_B_SUBNET_NAME \
    --address-prefix $TEAM_B_SUBNET_CIDR
```

### Export Subnet IDs

Capture the full ARM resource IDs for the private endpoint subnets (used later for ConfigMaps):

```bash
export TEAM_A_SUBNET_ID=$(az network vnet subnet show \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $TEAM_A_VNET_NAME \
    --name $TEAM_A_SUBNET_NAME \
    --query id -o tsv)

export TEAM_B_SUBNET_ID=$(az network vnet subnet show \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $TEAM_B_VNET_NAME \
    --name $TEAM_B_SUBNET_NAME \
    --query id -o tsv)

echo "Team A Subnet ID: $TEAM_A_SUBNET_ID"
echo "Team B Subnet ID: $TEAM_B_SUBNET_ID"
```

### Create VNet Peerings

Peer the AKS VNet with each team's VNet for private endpoint connectivity. We use the full resource ID for reliable cross-VNet references and run commands sequentially to avoid race conditions.

```bash
# Get VNet resource IDs
export AKS_VNET_ID=$(az network vnet show \
    --resource-group $RESOURCE_GROUP \
    --name $AKS_VNET_NAME \
    --query id -o tsv)

export TEAM_A_VNET_ID=$(az network vnet show \
    --resource-group $RESOURCE_GROUP \
    --name $TEAM_A_VNET_NAME \
    --query id -o tsv)

export TEAM_B_VNET_ID=$(az network vnet show \
    --resource-group $RESOURCE_GROUP \
    --name $TEAM_B_VNET_NAME \
    --query id -o tsv)

echo "AKS VNet ID: $AKS_VNET_ID"
echo "Team A VNet ID: $TEAM_A_VNET_ID"
echo "Team B VNet ID: $TEAM_B_VNET_ID"
```

Create the peerings one pair at a time, waiting for each to complete:

```bash
# Create AKS <-> Team A peering pair
echo "Creating AKS to Team A peering..."
az network vnet peering create \
    --resource-group $RESOURCE_GROUP \
    --name aks-to-team-a \
    --vnet-name $AKS_VNET_NAME \
    --remote-vnet $TEAM_A_VNET_ID \
    --allow-vnet-access \
    --output none

echo "Waiting for propagation..."
sleep 10

echo "Creating Team A to AKS peering..."
az network vnet peering create \
    --resource-group $RESOURCE_GROUP \
    --name team-a-to-aks \
    --vnet-name $TEAM_A_VNET_NAME \
    --remote-vnet $AKS_VNET_ID \
    --allow-vnet-access \
    --output none

# Sync the peerings to ensure Connected state
az network vnet peering sync \
    --resource-group $RESOURCE_GROUP \
    --name aks-to-team-a \
    --vnet-name $AKS_VNET_NAME \
    --output none

echo "AKS <-> Team A peering complete."
```

```bash
# Create AKS <-> Team B peering pair
echo "Creating AKS to Team B peering..."
az network vnet peering create \
    --resource-group $RESOURCE_GROUP \
    --name aks-to-team-b \
    --vnet-name $AKS_VNET_NAME \
    --remote-vnet $TEAM_B_VNET_ID \
    --allow-vnet-access \
    --output none

echo "Waiting for propagation..."
sleep 10

echo "Creating Team B to AKS peering..."
az network vnet peering create \
    --resource-group $RESOURCE_GROUP \
    --name team-b-to-aks \
    --vnet-name $TEAM_B_VNET_NAME \
    --remote-vnet $AKS_VNET_ID \
    --allow-vnet-access \
    --output none

# Sync the peerings to ensure Connected state
az network vnet peering sync \
    --resource-group $RESOURCE_GROUP \
    --name aks-to-team-b \
    --vnet-name $AKS_VNET_NAME \
    --output none

echo "AKS <-> Team B peering complete."
```

### Verify VNet Peerings

```bash
# Verify peering status - all should show "Connected"
az network vnet peering list \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $AKS_VNET_NAME \
    --query "[].{Name:name, State:peeringState}" -o table

az network vnet peering list \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $TEAM_A_VNET_NAME \
    --query "[].{Name:name, State:peeringState}" -o table

az network vnet peering list \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $TEAM_B_VNET_NAME \
    --query "[].{Name:name, State:peeringState}" -o table
```

All peerings should show `Connected` state.

### Create Private DNS Zones

Create private DNS zones for Azure services that will use private endpoints. Link them to the AKS VNet so the cluster can resolve private endpoint addresses.

```bash
# Azure Blob Storage private DNS zone
az network private-dns zone create \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.blob.core.windows.net"

# Azure Key Vault private DNS zone
az network private-dns zone create \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.vaultcore.azure.net"

# Azure Cosmos DB (SQL API) private DNS zone
az network private-dns zone create \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.documents.azure.com"

# Azure Database for PostgreSQL Flexible Server private DNS zone
az network private-dns zone create \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.postgres.database.azure.com"
```

### Link Private DNS Zones to AKS VNet

Link each private DNS zone to the AKS VNet so pods can resolve private endpoint DNS names.

```bash
# Link Blob Storage DNS zone to AKS VNet
az network private-dns link vnet create \
    --resource-group $RESOURCE_GROUP \
    --zone-name "privatelink.blob.core.windows.net" \
    --name "link-aks-blob" \
    --virtual-network $AKS_VNET_NAME \
    --registration-enabled false

# Link Key Vault DNS zone to AKS VNet
az network private-dns link vnet create \
    --resource-group $RESOURCE_GROUP \
    --zone-name "privatelink.vaultcore.azure.net" \
    --name "link-aks-keyvault" \
    --virtual-network $AKS_VNET_NAME \
    --registration-enabled false

# Link Cosmos DB DNS zone to AKS VNet
az network private-dns link vnet create \
    --resource-group $RESOURCE_GROUP \
    --zone-name "privatelink.documents.azure.com" \
    --name "link-aks-cosmosdb" \
    --virtual-network $AKS_VNET_NAME \
    --registration-enabled false

# Link PostgreSQL DNS zone to AKS VNet
az network private-dns link vnet create \
    --resource-group $RESOURCE_GROUP \
    --zone-name "privatelink.postgres.database.azure.com" \
    --name "link-aks-postgresql" \
    --virtual-network $AKS_VNET_NAME \
    --registration-enabled false
```

### Link Private DNS Zones to Team VNets

Also link the DNS zones to team VNets so resources can resolve each other within the same team's network.

```bash
# Link all DNS zones to Team A VNet
for zone in "privatelink.blob.core.windows.net" "privatelink.vaultcore.azure.net" "privatelink.documents.azure.com" "privatelink.postgres.database.azure.com"; do
    az network private-dns link vnet create \
        --resource-group $RESOURCE_GROUP \
        --zone-name $zone \
        --name "link-team-a-${zone%%.*}" \
        --virtual-network $TEAM_A_VNET_NAME \
        --registration-enabled false
done

# Link all DNS zones to Team B VNet
for zone in "privatelink.blob.core.windows.net" "privatelink.vaultcore.azure.net" "privatelink.documents.azure.com" "privatelink.postgres.database.azure.com"; do
    az network private-dns link vnet create \
        --resource-group $RESOURCE_GROUP \
        --zone-name $zone \
        --name "link-team-b-${zone%%.*}" \
        --virtual-network $TEAM_B_VNET_NAME \
        --registration-enabled false
done
```

> **Note:** When teams create resources with private endpoints via ASO, the private endpoint DNS records will be registered in these zones, allowing the AKS cluster to resolve the private IP addresses.

---

## Step 4: Create an AKS Cluster with Workload Identity

Create an AKS cluster in the dedicated VNet with OIDC issuer and workload identity enabled. We specify a service CIDR that doesn't overlap with our VNets.

```bash
az aks create \
    --resource-group $RESOURCE_GROUP \
    --name $AKS_CLUSTER_NAME \
    --node-count 3 \
    --vnet-subnet-id $AKS_SUBNET_ID \
    --enable-managed-identity \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --network-plugin azure \
    --service-cidr $AKS_SERVICE_CIDR \
    --dns-service-ip $AKS_DNS_SERVICE_IP \
    --generate-ssh-keys
```

> **Note:** This creates a 3-node cluster in the AKS VNet with Azure CNI networking and workload identity support. The service CIDR (172.16.0.0/16) is used for Kubernetes services and must not overlap with VNet address spaces. The creation process takes approximately 5-10 minutes.

After the cluster is created, get the OIDC issuer URL (needed for federated credentials):

```bash
export AKS_OIDC_ISSUER=$(az aks show \
    --resource-group $RESOURCE_GROUP \
    --name $AKS_CLUSTER_NAME \
    --query "oidcIssuerProfile.issuerUrl" -o tsv)

echo "OIDC Issuer: $AKS_OIDC_ISSUER"
```

---

## Step 5: Get AKS Credentials

Configure kubectl to connect to your new AKS cluster.

```bash
az aks get-credentials \
    --resource-group $RESOURCE_GROUP \
    --name $AKS_CLUSTER_NAME \
    --overwrite-existing
```

Verify the connection:

```bash
kubectl get nodes
```

You should see your 3 nodes in `Ready` status.

---

## Step 6: Install cert-manager

Azure Service Operator v2 requires cert-manager for certificate management. Install it first.

```bash
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.14.1/cert-manager.yaml
```

> **📝 Version Compatibility:** ASO v2 requires cert-manager ≥ v1.12. The version above (v1.14.1) is known to work, but you can use any compatible version. Check the [cert-manager releases](https://github.com/cert-manager/cert-manager/releases) for the latest stable version.

Wait for cert-manager pods to be ready:

```bash
kubectl get pods -n cert-manager --watch
```

All three pods should show `Running` status:
- `cert-manager`
- `cert-manager-cainjector`
- `cert-manager-webhook`

Press `Ctrl+C` to exit the watch once all pods are running.

---

## Step 7: Create Per-Team Managed Identities with Federated Credentials

Create a **separate User-Assigned Managed Identity for each team**, with federated credentials linked to ASO's controller service account. Each identity will have least-privilege permissions scoped to that team's resources.

> **✅ Recommended Production Pattern:** This follows the Microsoft-recommended approach where each namespace has its own identity with scoped permissions. The ASO controller service account (`azureserviceoperator-system:azureserviceoperator-default`) is federated to ALL team identities, allowing it to assume the appropriate identity based on which namespace's `aso-credential` secret it reads.

### Create Per-Team Managed Identities

```bash
# Set team subscriptions (defaults to same subscription as AKS)
export TEAM_A_SUBSCRIPTION_ID="${TEAM_A_SUBSCRIPTION_ID:-$AZURE_SUBSCRIPTION_ID}"
export TEAM_B_SUBSCRIPTION_ID="${TEAM_B_SUBSCRIPTION_ID:-$AZURE_SUBSCRIPTION_ID}"
export AZURE_TENANT_ID=$(az account show --subscription $AZURE_SUBSCRIPTION_ID --query tenantId -o tsv)

# Create a resource group for identities (recommended to keep identities separate)
az group create --name rg-aso-identities --location $LOCATION

# Create Team A's Managed Identity
az identity create \
    --name team-a-aso-mi \
    --resource-group rg-aso-identities \
    --location $LOCATION

export TEAM_A_CLIENT_ID=$(az identity show \
    --name team-a-aso-mi \
    --resource-group rg-aso-identities \
    --query clientId -o tsv)

export TEAM_A_PRINCIPAL_ID=$(az identity show \
    --name team-a-aso-mi \
    --resource-group rg-aso-identities \
    --query principalId -o tsv)

echo "Team A Client ID: $TEAM_A_CLIENT_ID"
echo "Team A Principal ID: $TEAM_A_PRINCIPAL_ID"

# Create Team B's Managed Identity
az identity create \
    --name team-b-aso-mi \
    --resource-group rg-aso-identities \
    --location $LOCATION

export TEAM_B_CLIENT_ID=$(az identity show \
    --name team-b-aso-mi \
    --resource-group rg-aso-identities \
    --query clientId -o tsv)

export TEAM_B_PRINCIPAL_ID=$(az identity show \
    --name team-b-aso-mi \
    --resource-group rg-aso-identities \
    --query principalId -o tsv)

echo "Team B Client ID: $TEAM_B_CLIENT_ID"
echo "Team B Principal ID: $TEAM_B_PRINCIPAL_ID"
```

### Grant Least-Privilege Permissions Per Team

Each team's identity gets permissions **scoped only to their resources**:

```bash
# Pre-create resource groups for each team (recommended for least-privilege)
az group create --name rg-team-a --location $LOCATION --subscription $TEAM_A_SUBSCRIPTION_ID
az group create --name rg-team-b --location $LOCATION --subscription $TEAM_B_SUBSCRIPTION_ID

# Grant Team A's identity Contributor access ONLY to Team A's resource group
az role assignment create \
    --assignee-object-id $TEAM_A_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope /subscriptions/$TEAM_A_SUBSCRIPTION_ID/resourceGroups/rg-team-a

# Grant Team B's identity Contributor access ONLY to Team B's resource group
az role assignment create \
    --assignee-object-id $TEAM_B_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope /subscriptions/$TEAM_B_SUBSCRIPTION_ID/resourceGroups/rg-team-b
```

> **✅ Least Privilege:** Each team's identity only has access to their own resource group. Team A's identity cannot create or modify resources in Team B's resource group, providing cryptographic isolation.

> **📝 Alternative: Subscription-Scoped Access**
> 
> If teams need to create their own resource groups dynamically, grant subscription-level Contributor:
> ```bash
> az role assignment create \
>     --assignee-object-id $TEAM_A_PRINCIPAL_ID \
>     --assignee-principal-type ServicePrincipal \
>     --role Contributor \
>     --scope /subscriptions/$TEAM_A_SUBSCRIPTION_ID
> ```

> **⚠️ RoleAssignment Resources Require Additional Permissions:**
>
> If your Helm charts or manifests create ASO `RoleAssignment` resources (e.g., granting a managed identity access to a storage account), the team identity needs **Role Based Access Control Administrator** or **User Access Administrator**:
>
> ```bash
> # Grant RBAC Administrator (scoped to team's resource group for least privilege)
> az role assignment create \
>     --assignee-object-id $TEAM_A_PRINCIPAL_ID \
>     --assignee-principal-type ServicePrincipal \
>     --role "Role Based Access Control Administrator" \
>     --scope /subscriptions/$TEAM_A_SUBSCRIPTION_ID/resourceGroups/rg-team-a
> ```
>
> Without this, ASO can create resources but cannot assign roles to managed identities.

### Create Federated Credentials for Each Team Identity

Create a federated credential for **each team's identity**, all pointing to the **same ASO controller service account**:

```bash
# Federated credential for Team A's identity
az identity federated-credential create \
    --name aso-team-a-federated-cred \
    --identity-name team-a-aso-mi \
    --resource-group rg-aso-identities \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default \
    --audiences api://AzureADTokenExchange

# Federated credential for Team B's identity
az identity federated-credential create \
    --name aso-team-b-federated-cred \
    --identity-name team-b-aso-mi \
    --resource-group rg-aso-identities \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default \
    --audiences api://AzureADTokenExchange
```

> **🔑 Key Insight:** All federated credentials use the **same subject** (`system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default`) because the ASO controller pod makes all Azure API calls. The controller reads the `aso-credential` secret from the resource's namespace to determine which identity's client ID to use for token exchange.

> **✅ This allows ASO to exchange its Kubernetes token for Azure tokens using the team-specific identity.**

### Grant Private DNS Zone Permissions to Each Team Identity

Each team's identity needs permission to create DNS records in the central private DNS zones when resources with private endpoints are created:

```bash
# Get the DNS zone resource IDs
export BLOB_DNS_ZONE_ID=$(az network private-dns zone show \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.blob.core.windows.net" \
    --query id -o tsv)

export KEYVAULT_DNS_ZONE_ID=$(az network private-dns zone show \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.vaultcore.azure.net" \
    --query id -o tsv)

export COSMOSDB_DNS_ZONE_ID=$(az network private-dns zone show \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.documents.azure.com" \
    --query id -o tsv)

export POSTGRESQL_DNS_ZONE_ID=$(az network private-dns zone show \
    --resource-group $RESOURCE_GROUP \
    --name "privatelink.postgres.database.azure.com" \
    --query id -o tsv)

# Grant Team A's identity access to all private DNS zones
for DNS_ZONE_ID in $BLOB_DNS_ZONE_ID $KEYVAULT_DNS_ZONE_ID $COSMOSDB_DNS_ZONE_ID $POSTGRESQL_DNS_ZONE_ID; do
    az role assignment create \
        --assignee-object-id $TEAM_A_PRINCIPAL_ID \
        --assignee-principal-type ServicePrincipal \
        --role "Private DNS Zone Contributor" \
        --scope $DNS_ZONE_ID
done

# Grant Team B's identity access to all private DNS zones
for DNS_ZONE_ID in $BLOB_DNS_ZONE_ID $KEYVAULT_DNS_ZONE_ID $COSMOSDB_DNS_ZONE_ID $POSTGRESQL_DNS_ZONE_ID; do
    az role assignment create \
        --assignee-object-id $TEAM_B_PRINCIPAL_ID \
        --assignee-principal-type ServicePrincipal \
        --role "Private DNS Zone Contributor" \
        --scope $DNS_ZONE_ID
done
```

> **Security Note:** The "Private DNS Zone Contributor" role allows creating, updating, and deleting DNS records within these zones, but does not grant permissions to delete the zones themselves or modify zone-level settings.

> **🌐 Central Connectivity / Hub Subscription Pattern:** In many enterprise environments following the Azure Landing Zone architecture, private DNS zones are owned by a central **connectivity/platform subscription** (hub-spoke model). If your DNS zones live in a different subscription than the team resources, grant each team's identity the "Private DNS Zone Contributor" role **across subscriptions** by specifying the full resource ID of the DNS zone in the central connectivity subscription.

---

## Step 8: Add the ASO Helm Repository

Add the Azure Service Operator Helm chart repository.

```bash
helm repo add aso2 https://raw.githubusercontent.com/Azure/azure-service-operator/main/v2/charts
helm repo update
```

---

## Step 9: Install Azure Service Operator v2 with Workload Identity

Install ASO using Helm with workload identity and **multitenant mode** enabled. With per-namespace credentials, the `azureClientID` here is just a fallback - each namespace will use its own identity via the `aso-credential` secret.

> **📝 Note on Global vs Per-Namespace Credentials:** The `azureClientID` Helm value is **only used if no `aso-credential` secret exists in the resource's namespace**. When a namespace has an `aso-credential` secret, ASO uses the credentials from that secret instead. For maximum security in multi-tenant environments, ensure every tenant namespace has its own `aso-credential` secret.

```bash
# Use Team A's identity as the fallback (or create a separate minimal-privilege identity)
helm upgrade --install aso2 aso2/azure-service-operator \
    --create-namespace \
    --namespace azureserviceoperator-system \
    --set azureSubscriptionID=$AZURE_SUBSCRIPTION_ID \
    --set azureTenantID=$AZURE_TENANT_ID \
    --set azureClientID=$TEAM_A_CLIENT_ID \
    --set useWorkloadIdentityAuth=true \
    --set multitenant.enable=true \
    --set crdPattern='resources.azure.com/*;containerservice.azure.com/*;keyvault.azure.com/*;managedidentity.azure.com/*;authorization.azure.com/*;storage.azure.com/*;cache.azure.com/*;documentdb.azure.com/*;dbforpostgresql.azure.com/*;dbformysql.azure.com/*;servicebus.azure.com/*;eventhub.azure.com/*;insights.azure.com/*;operationalinsights.azure.com/*;network.azure.com/*'
```

> **Note:** The `crdPattern` above includes common resource types including:
> - `keyvault.azure.com/*` - Azure Key Vault
> - `managedidentity.azure.com/*` - User-Assigned Managed Identities and Federated Credentials
> - `authorization.azure.com/*` - Role Assignments (required for granting identities access to resources)
> - `insights.azure.com/*` - Application Insights
> - `operationalinsights.azure.com/*` - Log Analytics Workspaces
> - `documentdb.azure.com/*` - Azure Cosmos DB
> - `dbforpostgresql.azure.com/*` - Azure Database for PostgreSQL
> - `storage.azure.com/*` - Azure Storage
> - `network.azure.com/*` - Network resources including Private Endpoints and Private DNS Zones
>
> Adjust based on your needs.

> **⚠️ Warning: Avoid `crdPattern='*'`** — Installing all ASO CRDs causes:
> - **Startup latency:** 200+ CRDs significantly slow controller initialization
> - **Memory pressure:** Each CRD consumes API server memory and etcd storage
> - **Reconciliation churn:** Unused CRDs still consume controller cycles
>
> **CRDs are cluster-scoped** — installing unnecessary CRDs affects all tenants, not just one team. This is especially problematic on:
> - **AKS Free tier** (limited control plane resources)
> - **Small control plane SKUs** (Basic, Standard with few nodes)
> - **Dev/test clusters** with constrained resources
>
> Always specify only the CRDs you actually need.

Verify ASO is running:

```bash
kubectl get pods -n azureserviceoperator-system
```

You should see the `azureserviceoperator-controller-manager` pod in `Running` status.

---

## Step 10: Create Team Namespaces and Credential Secrets

Create a dedicated namespace for each team with an `aso-credential` secret that references **that team's Managed Identity**. The ASO controller will use the identity specified in each namespace's secret.

> **✅ Security Boundary:** The namespace's `aso-credential` secret is the security boundary. ASO is deployed with Kubernetes RBAC that limits secret reads to the resource's namespace, so each team's credentials are isolated. No custom annotations are needed on resources.

### Create Team A Namespace and Credentials

```bash
# Create namespace for Team A
kubectl create namespace team-a

# Create Team A's credential secret pointing to Team A's identity
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aso-credential
  namespace: team-a
type: Opaque
stringData:
  AZURE_SUBSCRIPTION_ID: "$TEAM_A_SUBSCRIPTION_ID"
  AZURE_TENANT_ID: "$AZURE_TENANT_ID"
  AZURE_CLIENT_ID: "$TEAM_A_CLIENT_ID"
EOF
```

> **✅ No client secret, no certificates** - uses Workload Identity via the federated credential created in Step 7.

### Create Team B Namespace and Credentials

```bash
# Create namespace for Team B
kubectl create namespace team-b

# Create Team B's credential secret pointing to Team B's identity
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aso-credential
  namespace: team-b
type: Opaque
stringData:
  AZURE_SUBSCRIPTION_ID: "$TEAM_B_SUBSCRIPTION_ID"
  AZURE_TENANT_ID: "$AZURE_TENANT_ID"
  AZURE_CLIENT_ID: "$TEAM_B_CLIENT_ID"
EOF
```

> **✅ Architecture Summary:** With this setup:
> - Each team has their **own Managed Identity** with least-privilege permissions
> - Each namespace's `aso-credential` secret references that team's identity
> - **Namespace is the security boundary** - ASO's RBAC limits secret reads to the resource's namespace
> - Team A's identity cannot access Team B's resources and vice versa
> - No additional policy enforcement (Kyverno/Gatekeeper) is required for basic isolation
>
> **⚠️ Important:** This assumes namespace-scoped Kubernetes RBAC is correctly configured (no ClusterRoleBindings for tenants).

> **📋 RBAC Configuration:** Ensure each team only has RoleBindings in their own namespace, not ClusterRoleBindings. Example:
> ```yaml
> apiVersion: rbac.authorization.k8s.io/v1
> kind: RoleBinding
> metadata:
>   name: team-a-developers
>   namespace: team-a
> subjects:
>   - kind: Group
>     name: team-a-group
>     apiGroup: rbac.authorization.k8s.io
> roleRef:
>   kind: ClusterRole
>   name: edit  # or a custom role
>   apiGroup: rbac.authorization.k8s.io
> ```
> Ensure each team only has RoleBindings in their own namespace, not ClusterRoleBindings.

> **🔑 How ASO Resolves Credentials**
>
> When ASO reconciles a resource, it looks for an `aso-credential` secret in the **resource's namespace**:
>
> ```
> ASO Resource in team-a namespace
>         │
>         ▼
> Reads team-a/aso-credential secret
>         │
>         ▼
> Uses AZURE_CLIENT_ID from secret (Team A's identity)
>         │
>         ▼
> Exchanges K8s token for Azure token via Workload Identity
>         │
>         ▼
> Creates Azure resource using Team A's identity & permissions
> ```
>
> **✅ This is the security boundary** - ASO's Kubernetes RBAC restricts secret reads to the resource's namespace.

### Verify Resources

```bash
kubectl get secrets -n team-a
kubectl get secrets -n team-b
```

> **Tip:** For additional teams, follow the [Adding New Teams](#adding-new-teams) section. Each new team needs: a new Managed Identity, a federated credential, RBAC permissions, and a namespace with `aso-credential` secret.

---

## Step 11: Create Infrastructure ConfigMaps for Helm Charts

Create ConfigMaps that provide infrastructure values to Helm charts. This allows developers to deploy applications without knowing infrastructure details like DNS zone IDs or subnet IDs.

### Platform-Wide ConfigMap

Create a ConfigMap in `kube-public` namespace with values that are shared across all teams:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-platform-config
  namespace: kube-public
  labels:
    app.kubernetes.io/managed-by: platform-team
    app.kubernetes.io/purpose: aso-infrastructure
data:
  # AKS OIDC Issuer for workload identity federation
  oidcIssuerUrl: "$AKS_OIDC_ISSUER"
  
  # Default Azure location
  location: "$LOCATION"
  
  # Private DNS Zone IDs for private endpoints
  blobDnsZoneId: "$BLOB_DNS_ZONE_ID"
  keyvaultDnsZoneId: "$KEYVAULT_DNS_ZONE_ID"
  cosmosdbDnsZoneId: "$COSMOSDB_DNS_ZONE_ID"
  postgresqlDnsZoneId: "$POSTGRESQL_DNS_ZONE_ID"
EOF
```

### Team-Specific ConfigMaps

Create a ConfigMap in each team's namespace with team-specific infrastructure values:

```bash
# Team A ConfigMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-team-config
  namespace: team-a
  labels:
    app.kubernetes.io/managed-by: platform-team
    app.kubernetes.io/purpose: aso-infrastructure
data:
  # Team A's private endpoint subnet
  privateEndpointSubnetId: "$TEAM_A_SUBNET_ID"
  
  # Team A's subscription (informational)
  subscriptionId: "$TEAM_A_SUBSCRIPTION_ID"
  
  # Team A's VNet (informational)
  vnetId: "/subscriptions/$TEAM_A_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$TEAM_A_VNET_NAME"
EOF

# Team B ConfigMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-team-config
  namespace: team-b
  labels:
    app.kubernetes.io/managed-by: platform-team
    app.kubernetes.io/purpose: aso-infrastructure
data:
  # Team B's private endpoint subnet
  privateEndpointSubnetId: "$TEAM_B_SUBNET_ID"
  
  # Team B's subscription (informational)
  subscriptionId: "$TEAM_B_SUBSCRIPTION_ID"
  
  # Team B's VNet (informational)
  vnetId: "/subscriptions/$TEAM_B_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$TEAM_B_VNET_NAME"
EOF
```

### Verify ConfigMaps

```bash
# View platform ConfigMap
kubectl get configmap aso-platform-config -n kube-public -o yaml

# View team ConfigMaps
kubectl get configmap aso-team-config -n team-a -o yaml
kubectl get configmap aso-team-config -n team-b -o yaml
```

> **Developer Experience:** With these ConfigMaps in place, developers using the `container-storage-mi` Helm chart only need to specify:
> - `appName` - unique name for their application
> - `resourceGroup` - Azure resource group to create resources in
> - `port` - application port (optional)
>
> All infrastructure values (OIDC issuer, DNS zones, subnet IDs) are automatically populated from the ConfigMaps.

---

## Step 12: Verify the Installation

Check that ASO is ready to manage resources by viewing the controller logs:

```bash
kubectl logs -n azureserviceoperator-system \
    $(kubectl get pods -n azureserviceoperator-system -o jsonpath='{.items[0].metadata.name}') \
    -c manager
```

---

## Step 13: Install Flux and Create HelmRepository (For GitOps)

This step sets up Flux for GitOps-based Helm chart deployment. The HelmRepository resources define where Flux pulls charts from.

### Why `flux-system` Namespace?

Flux uses `flux-system` as its default namespace for:
- **Flux controllers** (source-controller, helm-controller, etc.)
- **Shared resources** like HelmRepository that can be referenced from any namespace

When a HelmRelease in `team-a` namespace references a HelmRepository, it uses `namespace: flux-system` because the HelmRepository is a cluster-wide shared resource, not team-specific.

### Install Flux

```bash
# Install Flux CLI (if not already installed)
# Windows (winget):
winget install --id Flux.Flux

# macOS (Homebrew):
# brew install fluxcd/tap/flux

# Linux:
# curl -s https://fluxcd.io/install.sh | sudo bash

# Bootstrap Flux into the cluster
flux install
```

Verify Flux is running:

```bash
kubectl get pods -n flux-system
```

### Create HelmRepository for Platform Charts

Create a HelmRepository pointing to your chart repository. Choose one of the following options:

#### Option A: Azure Container Registry (ACR) with Helm Charts

If you're hosting charts in ACR:

```bash
# Set your ACR name
export ACR_NAME="<your-acr-name>"

# Create the HelmRepository for ACR
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: acr-helm
  namespace: flux-system
spec:
  interval: 5m
  url: oci://${ACR_NAME}.azurecr.io/helm
  type: oci
  provider: azure  # Uses workload identity for auth
EOF
```

> **Note:** For ACR OCI repositories, ensure the AKS cluster has `acrpull` role or use workload identity for authentication.

#### Option B: Git-Based Chart Repository (GitHub/Azure DevOps)

If your charts are in a Git repository:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: platform-charts
  namespace: flux-system
spec:
  interval: 5m
  url: https://raw.githubusercontent.com/<org>/<repo>/main/helm-charts
  # For private repos, add secretRef for authentication
EOF
```

#### Option C: Local Development (File-Based)

For local testing, you can use a GitRepository source instead:

```bash
# Create a GitRepository pointing to your charts repo
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: GitRepository
metadata:
  name: platform-repo
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/<org>/<repo>
  ref:
    branch: main
EOF
```

Then reference it in HelmRelease as:
```yaml
sourceRef:
  kind: GitRepository
  name: platform-repo
  namespace: flux-system
```

### Verify HelmRepository

```bash
# List all HelmRepositories
kubectl get helmrepositories -n flux-system

# Check status of a specific repository
kubectl describe helmrepository acr-helm -n flux-system
```

### Push Charts to ACR (if using Option A)

```bash
# Login to ACR
az acr login --name $ACR_NAME

# Package and push charts
cd helm-charts

# Push storage chart
helm package container-storage-mi
helm push container-storage-mi-0.1.0.tgz oci://${ACR_NAME}.azurecr.io/helm

# Push cosmosdb chart
helm package container-cosmosdb-monitoring-mi
helm push container-cosmosdb-monitoring-mi-0.1.0.tgz oci://${ACR_NAME}.azurecr.io/helm
```

---

## Step 14: Test with Sample Resources (Optional)

Test that each team can only create resources in their assigned subscription.

### Test Team A

Create a resource group in Team A's namespace (will be created in Team A's subscription):

```bash
cat <<EOF | kubectl apply -f -
apiVersion: resources.azure.com/v1api20200601
kind: ResourceGroup
metadata:
  name: team-a-test-rg
  namespace: team-a
spec:
  location: $LOCATION
EOF
```

Check the status:

```bash
kubectl describe resourcegroup/team-a-test-rg -n team-a
```

### Test Team B

Create a resource group in Team B's namespace (will be created in Team B's subscription):

```bash
cat <<EOF | kubectl apply -f -
apiVersion: resources.azure.com/v1api20200601
kind: ResourceGroup
metadata:
  name: team-b-test-rg
  namespace: team-b
spec:
  location: $LOCATION
EOF
```

Check the status:

```bash
kubectl describe resourcegroup/team-b-test-rg -n team-b
```

### Verify Isolation

Confirm the resource groups were created in the correct subscriptions:

```bash
# Check Team A's subscription
az group show --name team-a-test-rg --subscription $TEAM_A_SUBSCRIPTION_ID

# Check Team B's subscription
az group show --name team-b-test-rg --subscription $TEAM_B_SUBSCRIPTION_ID
```

### Clean Up Test Resources

```bash
kubectl delete resourcegroup/team-a-test-rg -n team-a
kubectl delete resourcegroup/team-b-test-rg -n team-b
```

---

## Cleanup

To remove all resources created by this guide:

```bash
# Delete the AKS cluster, VNets, private DNS zones (all in main resource group)
az group delete --name $RESOURCE_GROUP --yes --no-wait

# Delete the managed identities resource group
az group delete --name rg-aso-identities --yes --no-wait

# Delete the team resource groups
az group delete --name rg-team-a --yes --no-wait
az group delete --name rg-team-b --yes --no-wait
```

> **Note:** Deleting these resource groups will remove the AKS cluster, all VNets, VNet peerings, private DNS zones, and the per-team managed identities created in this guide.

---

## Adding New Teams

To onboard a new team, follow these steps:

1. **Set the new team's variables** (defaults to same subscription as AKS if not specified):

```bash
export NEW_TEAM_NAME="team-new"
export NEW_TEAM_SUBSCRIPTION_ID="${NEW_TEAM_SUBSCRIPTION_ID:-$AZURE_SUBSCRIPTION_ID}"
```

2. **Create the new team's Managed Identity**:

```bash
az identity create \
    --name ${NEW_TEAM_NAME}-aso-mi \
    --resource-group rg-aso-identities \
    --location $LOCATION

export NEW_TEAM_CLIENT_ID=$(az identity show \
    --name ${NEW_TEAM_NAME}-aso-mi \
    --resource-group rg-aso-identities \
    --query clientId -o tsv)

export NEW_TEAM_PRINCIPAL_ID=$(az identity show \
    --name ${NEW_TEAM_NAME}-aso-mi \
    --resource-group rg-aso-identities \
    --query principalId -o tsv)
```

3. **Create the team's resource group and grant permissions**:

```bash
# Create the team's resource group
az group create --name rg-${NEW_TEAM_NAME} --location $LOCATION --subscription $NEW_TEAM_SUBSCRIPTION_ID

# Grant Contributor role scoped to the team's resource group
az role assignment create \
    --assignee-object-id $NEW_TEAM_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope /subscriptions/$NEW_TEAM_SUBSCRIPTION_ID/resourceGroups/rg-${NEW_TEAM_NAME}

# Grant Private DNS Zone Contributor access
for DNS_ZONE_ID in $BLOB_DNS_ZONE_ID $KEYVAULT_DNS_ZONE_ID $COSMOSDB_DNS_ZONE_ID $POSTGRESQL_DNS_ZONE_ID; do
    az role assignment create \
        --assignee-object-id $NEW_TEAM_PRINCIPAL_ID \
        --assignee-principal-type ServicePrincipal \
        --role "Private DNS Zone Contributor" \
        --scope $DNS_ZONE_ID
done
```

4. **Create federated credential for the new identity**:

```bash
az identity federated-credential create \
    --name aso-${NEW_TEAM_NAME}-federated-cred \
    --identity-name ${NEW_TEAM_NAME}-aso-mi \
    --resource-group rg-aso-identities \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default \
    --audiences api://AzureADTokenExchange
```

5. **Create the namespace and credential secret**:

```bash
kubectl create namespace $NEW_TEAM_NAME

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aso-credential
  namespace: $NEW_TEAM_NAME
type: Opaque
stringData:
  AZURE_SUBSCRIPTION_ID: "$NEW_TEAM_SUBSCRIPTION_ID"
  AZURE_TENANT_ID: "$AZURE_TENANT_ID"
  AZURE_CLIENT_ID: "$NEW_TEAM_CLIENT_ID"
EOF
```

6. **Create the team's VNet and subnet** (if using private endpoints):

```bash
export NEW_TEAM_VNET_NAME="vnet-$NEW_TEAM_NAME"
export NEW_TEAM_VNET_CIDR="10.X.0.0/16"  # Choose a unique CIDR
export NEW_TEAM_SUBNET_NAME="snet-$NEW_TEAM_NAME-pe"
export NEW_TEAM_SUBNET_CIDR="10.X.0.0/24"  # Choose a unique CIDR

# Create VNet and subnet
az network vnet create \
    --resource-group $RESOURCE_GROUP \
    --name $NEW_TEAM_VNET_NAME \
    --address-prefix $NEW_TEAM_VNET_CIDR \
    --location $LOCATION

az network vnet subnet create \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $NEW_TEAM_VNET_NAME \
    --name $NEW_TEAM_SUBNET_NAME \
    --address-prefix $NEW_TEAM_SUBNET_CIDR

# Get subnet ID
export NEW_TEAM_SUBNET_ID=$(az network vnet subnet show \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $NEW_TEAM_VNET_NAME \
    --name $NEW_TEAM_SUBNET_NAME \
    --query id -o tsv)

# Peer with AKS VNet
az network vnet peering create \
    --resource-group $RESOURCE_GROUP \
    --name aks-to-$NEW_TEAM_NAME \
    --vnet-name $AKS_VNET_NAME \
    --remote-vnet $NEW_TEAM_VNET_NAME \
    --allow-vnet-access

az network vnet peering create \
    --resource-group $RESOURCE_GROUP \
    --name $NEW_TEAM_NAME-to-aks \
    --vnet-name $NEW_TEAM_VNET_NAME \
    --remote-vnet $AKS_VNET_NAME \
    --allow-vnet-access
```

7. **Create the team ConfigMap** for infrastructure auto-discovery:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aso-team-config
  namespace: $NEW_TEAM_NAME
  labels:
    app.kubernetes.io/managed-by: platform-team
    app.kubernetes.io/purpose: aso-infrastructure
data:
  privateEndpointSubnetId: "$NEW_TEAM_SUBNET_ID"
  subscriptionId: "$NEW_TEAM_SUBSCRIPTION_ID"
  vnetId: "/subscriptions/$NEW_TEAM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$NEW_TEAM_VNET_NAME"
EOF
```

8. The new team can now deploy Azure resources in their namespace! Developers only need to specify `appName` and `resourceGroup` in their Helm releases.

---

## Security Hardening (Optional - Defense in Depth)

> **✅ Built-in Isolation:** With the per-team identity architecture described in this guide, teams are already cryptographically isolated. Each team's identity only has access to their own resources, and ASO cannot read secrets across namespaces. The policies below are **optional defense-in-depth measures**.

The per-namespace identity architecture provides strong isolation by default. However, for additional defense-in-depth, you can add policy controls to prevent configuration drift or accidental misconfigurations.

### When You Might Want Additional Policies

- Prevent accidental use of `credential-from` annotations that bypass namespace credentials
- Prevent `armId` owner references that could point to resources outside the team's scope
- Protect `aso-credential` secrets from modification by developers
- Enforce naming conventions for resource groups

### Approach Comparison

| Approach                   | Purpose                              | Complexity | Overhead |
| -------------------------- | ------------------------------------ | ---------- | -------- |
| **Kyverno Policies**       | Defense-in-depth, naming conventions | Low        | Minimal  |
| **Separate ASO Instances** | Regulatory/compliance requirements   | Medium     | High     |

---

### Option 1: Kyverno Policy Enforcement (Defense-in-Depth)

Kyverno is a Kubernetes-native policy engine that can provide additional protection against configuration mistakes or deliberate bypass attempts.

> **📝 Note:** With per-team identities, even if someone bypasses namespace credentials, they would still only have access to resources allowed by that namespace's identity. These policies add an extra layer of protection.

#### Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno \
    --create-namespace \
    --set replicaCount=3
```

Wait for Kyverno to be ready:

```bash
kubectl get pods -n kyverno --watch
```

#### Apply ASO Security Policies

Create policies that block the two main bypass vectors:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: aso-block-credential-override
  annotations:
    policies.kyverno.io/title: Block ASO Credential Override
    policies.kyverno.io/description: >-
      Prevents users from using custom credential-from annotations to bypass
      namespace credential isolation. All ASO resources must use the default
      aso-credential secret in their namespace.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: block-custom-credential-from
    match:
      any:
      - resources:
          kinds:
          - "resources.azure.com/*"
          - "storage.azure.com/*"
          - "keyvault.azure.com/*"
          - "documentdb.azure.com/*"
          - "dbforpostgresql.azure.com/*"
          - "network.azure.com/*"
          - "managedidentity.azure.com/*"
          - "insights.azure.com/*"
          - "operationalinsights.azure.com/*"
    validate:
      message: "Custom credential-from annotations are not allowed. Resources must use the namespace default 'aso-credential' secret."
      deny:
        conditions:
          all:
          - key: "{{ request.object.metadata.annotations.\"serviceoperator.azure.com/credential-from\" || 'aso-credential' }}"
            operator: NotEquals
            value: "aso-credential"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: aso-block-armid-owner
  annotations:
    policies.kyverno.io/title: Block ASO armId Owner References
    policies.kyverno.io/description: >-
      Prevents users from specifying armId in owner references, which could
      be used to target resources in other subscriptions. Resources must use
      name-based owner references within their namespace.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: block-armid-in-owner
    match:
      any:
      - resources:
          kinds:
          - "storage.azure.com/*"
          - "keyvault.azure.com/*"
          - "documentdb.azure.com/*"
          - "dbforpostgresql.azure.com/*"
          - "network.azure.com/*"
          - "managedidentity.azure.com/*"
          - "insights.azure.com/*"
          - "operationalinsights.azure.com/*"
    validate:
      message: "Using armId for owner references is not allowed. Use 'name' to reference resources within the same namespace."
      deny:
        conditions:
          all:
          - key: "{{ request.object.spec.owner.armId || '' }}"
            operator: NotEquals
            value: ""
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: aso-protect-credential-secrets
  annotations:
    policies.kyverno.io/title: Protect ASO Credential Secrets
    policies.kyverno.io/description: >-
      Prevents users from creating, modifying, or deleting secrets named
      'aso-credential'. Only cluster administrators should manage these secrets.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: block-aso-credential-modification
    match:
      any:
      - resources:
          kinds:
          - Secret
          names:
          - "aso-credential"
          operations:
          - CREATE
          - UPDATE
          - DELETE
    exclude:
      any:
      - clusterRoles:
        - cluster-admin
      - subjects:
        - kind: ServiceAccount
          name: admin
          namespace: kube-system
    validate:
      message: "Modification of 'aso-credential' secrets is restricted to cluster administrators."
      deny: {}
EOF
```

#### Test the Policies

Try to bypass the credential (should be blocked):

```bash
# This should be DENIED
cat <<EOF | kubectl apply -f -
apiVersion: resources.azure.com/v1api20200601
kind: ResourceGroup
metadata:
  name: bypass-attempt
  namespace: team-b
  annotations:
    serviceoperator.azure.com/credential-from: "my-custom-creds"
spec:
  location: $LOCATION
EOF
```

Expected output:
```
Error from server: error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 
resource ResourceGroup/team-b/bypass-attempt was blocked due to the following policies:
aso-block-credential-override: block-custom-credential-from: Custom credential-from annotations are not allowed.
```

---

### Option 2: Separate ASO Instances per Namespace

> **📝 When to Use:** This approach is typically only needed for strict regulatory/compliance requirements where you need completely separate ASO controller processes per team. The per-team identity model in this guide already provides cryptographic isolation.

For complete process isolation, deploy a separate ASO controller per team. Each controller only has access to its team's subscription.

#### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ AKS Cluster                                                     │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────┐  ┌─────────────────────────────┐   │
│  │ team-a namespace        │  │ team-b namespace            │   │
│  │ ┌─────────────────────┐ │  │ ┌─────────────────────────┐ │   │
│  │ │ ASO Controller      │ │  │ │ ASO Controller          │ │   │
│  │ │ (team-a-identity)   │ │  │ │ (team-b-identity)       │ │   │
│  │ └─────────────────────┘ │  │ └─────────────────────────┘ │   │
│  │ ┌─────────────────────┐ │  │ ┌─────────────────────────┐ │   │
│  │ │ ASO Resources       │ │  │ │ ASO Resources           │ │   │
│  │ └─────────────────────┘ │  │ └─────────────────────────┘ │   │
│  └─────────────────────────┘  └─────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
           │                              │
           ▼                              ▼
    ┌──────────────┐              ┌──────────────┐
    │ Team A       │              │ Team B       │
    │ Subscription │              │ Subscription │
    └──────────────┘              └──────────────┘
```

#### Prerequisites

Create a separate managed identity for each team:

```bash
# Team A Identity
az identity create \
    --name aso-team-a-identity \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION

export TEAM_A_CLIENT_ID=$(az identity show \
    --name aso-team-a-identity \
    --resource-group $RESOURCE_GROUP \
    --query clientId -o tsv)

export TEAM_A_PRINCIPAL_ID=$(az identity show \
    --name aso-team-a-identity \
    --resource-group $RESOURCE_GROUP \
    --query principalId -o tsv)

# Grant access ONLY to Team A's subscription
az role assignment create \
    --assignee-object-id $TEAM_A_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope /subscriptions/$TEAM_A_SUBSCRIPTION_ID

# Create federated credential for Team A's ASO instance
az identity federated-credential create \
    --name aso-team-a-federated-cred \
    --identity-name aso-team-a-identity \
    --resource-group $RESOURCE_GROUP \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:team-a:azureserviceoperator-default \
    --audiences api://AzureADTokenExchange

# Repeat for Team B with TEAM_B_SUBSCRIPTION_ID...
```

#### Install ASO per Namespace

Install a separate ASO instance for each team, watching only their namespace:

```bash
# Install ASO for Team A
helm upgrade --install aso2-team-a aso2/azure-service-operator \
    --namespace team-a \
    --create-namespace \
    --set azureSubscriptionID=$TEAM_A_SUBSCRIPTION_ID \
    --set azureTenantID=$AZURE_TENANT_ID \
    --set azureClientID=$TEAM_A_CLIENT_ID \
    --set useWorkloadIdentityAuth=true \
    --set multitenant.enable=false \
    --set operatorMode=watchers \
    --set watchNamespace=team-a \
    --set crdPattern='resources.azure.com/*;storage.azure.com/*;keyvault.azure.com/*;network.azure.com/*'

# Install ASO for Team B
helm upgrade --install aso2-team-b aso2/azure-service-operator \
    --namespace team-b \
    --create-namespace \
    --set azureSubscriptionID=$TEAM_B_SUBSCRIPTION_ID \
    --set azureTenantID=$AZURE_TENANT_ID \
    --set azureClientID=$TEAM_B_CLIENT_ID \
    --set useWorkloadIdentityAuth=true \
    --set multitenant.enable=false \
    --set operatorMode=watchers \
    --set watchNamespace=team-b \
    --set crdPattern='resources.azure.com/*;storage.azure.com/*;keyvault.azure.com/*;network.azure.com/*'
```

> **Note:** CRDs are cluster-scoped, so you only need to install them once. Set `--set installCRDs=false` on subsequent installs.

#### Trade-offs

| Pros                                  | Cons                                                         |
| ------------------------------------- | ------------------------------------------------------------ |
| Complete cryptographic isolation      | Higher resource usage (~150-250MB RAM, 0.1-0.2 CPU per team) |
| Each identity has minimal permissions | More complex to manage                                       |
| No policy engine required             | CRD version conflicts possible                               |
| Simple mental model                   | Harder to add new teams                                      |

> **Resource Estimates:** Each ASO controller instance typically consumes:
> - **Memory:** ~150-250 MB RAM at idle, up to 500 MB under heavy reconciliation
> - **CPU:** ~0.1-0.2 vCPU at idle, spikes during resource creation
> - **Pods:** 1 controller pod per team namespace
> 
> For 10 teams, expect approximately **1.5-2.5 GB additional RAM** and **1-2 vCPU** cluster overhead compared to the shared controller approach.

---

### Security Hardening Summary

With the **per-team identity architecture** used in this guide:

| Risk                       | Status                                  | Notes                                    |
| -------------------------- | --------------------------------------- | ---------------------------------------- |
| Cross-team resource access | ✅ **Blocked by default**                | Each identity only has its own RG access |
| Cross-subscription access  | ✅ **Blocked by default**                | Identities scoped to specific subs       |
| `credential-from` bypass   | ⚠️ Limited impact (uses team's identity) | Add Kyverno for defense-in-depth         |
| `armId` owner bypass       | ⚠️ Limited impact (uses team's identity) | Add Kyverno for defense-in-depth         |
| Secret modification        | ⚠️ Requires K8s RBAC                     | Add Kyverno to protect aso-credential    |

**Recommendations:**
- **Default (this guide)**: Per-team identities with RG-scoped permissions → Strong isolation out of the box
- **Defense-in-depth**: Add Kyverno policies (Option 1) to prevent misconfigurations  
- **Strict compliance**: Use separate ASO instances (Option 2) for process-level isolation

---

## Additional Resources

- [Azure Service Operator v2 Documentation](https://azure.github.io/azure-service-operator/)
- [ASO Workload Identity Authentication](https://azure.github.io/azure-service-operator/guide/authentication/credential-format/#azure-workload-identity)
- [Azure Workload Identity Documentation](https://azure.github.io/azure-workload-identity/docs/)
- [Supported Resources](https://azure.github.io/azure-service-operator/reference/)
- [Authentication Options](https://azure.github.io/azure-service-operator/guide/authentication/)
- [AKS Documentation](https://docs.microsoft.com/en-us/azure/aks/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Kyverno Documentation](https://kyverno.io/docs/)

---

## Disclaimer

**This documentation is provided "as is" without warranty of any kind.** The author takes no responsibility for any errors, omissions, or inaccuracies contained herein. This material may contain incorrect or outdated information. Always verify configurations against official Microsoft Azure and Kubernetes documentation before use in production environments. Use at your own risk.

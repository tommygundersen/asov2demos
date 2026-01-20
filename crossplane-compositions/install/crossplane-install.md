# Installing Crossplane as an Abstraction Layer on ASO

This guide shows how to use **Crossplane as an abstraction layer on top of Azure Service Operator**, for organizations building an Internal Developer Platform (IDP) with opinionated APIs and strong guardrails.

> **📍 Positioning:** This guide complements the [ASO installation guide](../../install/aks-and-aso-v2-helm-installation.md), which answers *"How do we safely expose Azure infrastructure to teams using Kubernetes?"* This Crossplane guide answers *"How do we create product-level APIs for infrastructure on top of ASO?"*
>
> **Crossplane is not a replacement for ASO** — it's an optional abstraction layer for organizations that need custom developer-facing APIs with schema validation.

---

## When to Use Crossplane vs ASO Alone

| Scenario                                             | Recommendation                          |
| ---------------------------------------------------- | --------------------------------------- |
| Teams deploy standard Azure resources                | **ASO alone** (simpler, lower overhead) |
| Platform team wants custom APIs (e.g., `StorageApp`) | **Crossplane + ASO**                    |
| Need OpenAPI schema validation at apply time         | **Crossplane + ASO**                    |
| Want automatic connection secret propagation         | **Crossplane + ASO**                    |
| Minimize operational complexity                      | **ASO alone**                           |

---

## Resource Overhead Comparison

Crossplane adds operational overhead compared to ASO alone. Plan accordingly:

| Component                    | Typical Memory | Typical CPU  | Notes                             |
| ---------------------------- | -------------- | ------------ | --------------------------------- |
| **Crossplane core**          | 300–500 MB     | 0.2–0.5 vCPU | Required for all Crossplane usage |
| **provider-azure** (Upbound) | 150–300 MB     | 0.1–0.3 vCPU | Native Azure provider             |
| **provider-kubernetes**      | 100–200 MB     | 0.1–0.2 vCPU | For ASO wrapper approach          |
| **ASO controller**           | 150–250 MB     | 0.1–0.3 vCPU | Required if using Option B        |

> **Total overhead for Crossplane + ASO:** ~600–950 MB RAM, ~0.4–1.0 vCPU additional
>
> On resource-constrained clusters (AKS Free tier, small node pools), this overhead is significant.

---

## Step 1: Install Crossplane

```bash
# Add the Crossplane Helm repository
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

# Install Crossplane
helm install crossplane \
    crossplane-stable/crossplane \
    --namespace crossplane-system \
    --create-namespace \
    --wait
```

Verify the installation:

```bash
kubectl get pods -n crossplane-system
```

## Step 2: Install Crossplane CLI (Optional)

```bash
# Windows (via Go)
go install github.com/crossplane/crossplane/cmd/crank@latest

# macOS
brew install crossplane/tap/crossplane
```

## Step 3: Choose a Provider Strategy

### Option A: Use Upbound Official Azure Provider (Recommended)

The Upbound provider has native Azure support:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-azure
spec:
  package: xpkg.upbound.io/upbound/provider-family-azure:v1.0.0
EOF
```

Wait for the provider to become healthy:

```bash
kubectl get providers -w
```

### Option B: Use Crossplane as an Abstraction Layer on ASO

If you want to use ASO CRDs directly with Crossplane (ASO handles Azure, Crossplane provides the API layer):

```bash
# First ensure ASO v2 is installed (see main installation guide)

# Install provider-kubernetes to manage ASO resources
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.11.0
EOF
```

This approach uses `provider-kubernetes` to create and manage ASO custom resources as Crossplane-managed objects.

> **⚠️ Important: Understand What This Means**
>
> When using Crossplane with ASO via `provider-kubernetes`:
>
> | Responsibility | Handled By |
> |----------------|------------|
> | Developer-facing API (XRD/Claim) | Crossplane |
> | Creating Kubernetes objects | Crossplane (via provider-kubernetes) |
> | **Talking to Azure APIs** | **ASO** (not Crossplane) |
> | **Azure resource lifecycle** | **ASO** (not Crossplane) |
> | **Drift detection & correction** | **ASO** (not Crossplane) |
> | **Deletion & cleanup** | **ASO** (not Crossplane) |
>
> **Crossplane does not "own" Azure resources in this model** — it only manages the Kubernetes objects that ASO then reconciles to Azure. This is fundamentally different from using a native Azure provider.

## Step 4: Configure Azure Credentials

### Using Workload Identity (Recommended)

Create a ProviderConfig that uses workload identity:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: OIDCTokenFile
  subscriptionID: $AZURE_SUBSCRIPTION_ID
  tenantID: $AZURE_TENANT_ID
  clientID: $CROSSPLANE_CLIENT_ID
EOF
```

### Using Service Principal (Alternative)

```bash
# Create a secret with SP credentials
kubectl create secret generic azure-creds \
    -n crossplane-system \
    --from-literal=credentials="{
      \"clientId\": \"$SP_CLIENT_ID\",
      \"clientSecret\": \"$SP_CLIENT_SECRET\",
      \"subscriptionId\": \"$AZURE_SUBSCRIPTION_ID\",
      \"tenantId\": \"$AZURE_TENANT_ID\"
    }"

# Create ProviderConfig
cat <<EOF | kubectl apply -f -
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: azure-creds
      key: credentials
EOF
```

## Step 5: Install XRDs and Compositions

Apply the platform definitions:

```bash
# Install Storage App composition
kubectl apply -f crossplane-compositions/storage-mi/definition.yaml
kubectl apply -f crossplane-compositions/storage-mi/composition.yaml

# Install Cosmos DB App composition
kubectl apply -f crossplane-compositions/cosmosdb-monitoring-mi/definition.yaml
kubectl apply -f crossplane-compositions/cosmosdb-monitoring-mi/composition.yaml
```

## Step 6: Verify Installation

```bash
# Check XRDs are installed
kubectl get xrd

# Check Compositions
kubectl get compositions

# Verify the new APIs are available
kubectl api-resources | grep platform.example.com
```

## Multi-Tenant Configuration

For multi-tenant scenarios, create ProviderConfigs per team:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: team-a
spec:
  credentials:
    source: OIDCTokenFile
  subscriptionID: $TEAM_A_SUBSCRIPTION_ID
  tenantID: $AZURE_TENANT_ID
  clientID: $TEAM_A_CLIENT_ID
---
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: team-b
spec:
  credentials:
    source: OIDCTokenFile
  subscriptionID: $TEAM_B_SUBSCRIPTION_ID
  tenantID: $AZURE_TENANT_ID
  clientID: $TEAM_B_CLIENT_ID
EOF
```

> **⚠️ Multi-Tenant Security Warning: This Differs from the ASO Model**
>
> In the main ASO installation guide, namespace isolation is enforced by:
> - Each namespace having its own `ASO credential secret`
> - ASO controller using the secret from the namespace where the resource is created
>
> **Crossplane's ProviderConfig model is different:**
> - `ProviderConfig` resources are **cluster-scoped**, not namespace-scoped
> - Any Claim in any namespace can reference **any** `providerConfigRef` by name
> - **There is no built-in enforcement** preventing Team B from specifying `providerConfigRef: team-a`
>
> **You MUST add policy enforcement:**
> ```yaml
> # Example Kyverno policy to enforce ProviderConfig by namespace
> apiVersion: kyverno.io/v1
> kind: ClusterPolicy
> metadata:
>   name: restrict-providerconfig-by-namespace
> spec:
>   validatingAdmissionPolicy: true
>   background: false
>   rules:
>   - name: team-a-uses-team-a-config
>     match:
>       resources:
>         kinds:
>         - StorageApp
>         - CosmosDBApp
>         namespaces:
>         - team-a
>     validate:
>       message: "Claims in team-a namespace must use team-a ProviderConfig"
>       pattern:
>         spec:
>           providerConfigRef:
>             name: team-a
> ```
>
> Without Kyverno, Gatekeeper, or similar policy enforcement, Crossplane multi-tenancy relies purely on trust.

### Using Claims with ProviderConfigs

Claims reference the appropriate ProviderConfig. Here's a complete minimal example:

```yaml
apiVersion: platform.example.com/v1alpha1
kind: StorageApp
metadata:
  name: my-storage-app
  namespace: team-a
spec:
  # Multi-tenant configuration - must match team namespace (enforce via Kyverno)
  providerConfigRef:
    name: team-a
  
  # Required parameters
  resourceGroupName: rg-team-a-prod
  location: eastus
  
  # Application-specific configuration
  storageConfig:
    accountName: teamstorage001
    containerName: app-data
    sku: Standard_LRS
  
  # Managed Identity for workload binding
  managedIdentity:
    name: mi-team-a-storage-app
```

Apply with:

```bash
kubectl apply -f claim.yaml

# Watch the claim status
kubectl get storageapp my-storage-app -n team-a -w

# View all composed resources
kubectl get managed -l crossplane.io/claim-name=my-storage-app
```

## Troubleshooting

### Check Provider Status

```bash
kubectl describe provider provider-azure
```

### View Composition Logs

```bash
kubectl logs -n crossplane-system -l app=crossplane -c crossplane
```

### Debug a Claim

```bash
kubectl describe storageapp my-app -n team-a
kubectl get managed -l crossplane.io/claim-name=my-app
```

---

## Disclaimer

**This documentation is provided "as is" without warranty of any kind.** The author takes no responsibility for any errors, omissions, or inaccuracies contained herein. This material may contain incorrect or outdated information. Always verify configurations against official Microsoft Azure and Kubernetes documentation before use in production environments. Use at your own risk.

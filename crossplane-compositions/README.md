# Crossplane Compositions for ASO v2

This directory contains Crossplane Compositions that provide the same functionality as the Helm charts, but using Crossplane's declarative composition model.

## Why Crossplane?

| Feature                  | Helm + ConfigMaps   | Crossplane                                |
| ------------------------ | ------------------- | ----------------------------------------- |
| **Abstraction Level**    | Template-based      | Schema-based API                          |
| **Validation**           | Runtime only        | OpenAPI schema validation                 |
| **Developer Experience** | Familiar YAML       | Custom Kubernetes resources               |
| **Drift Detection**      | Flux reconciliation | Built-in continuous reconciliation        |
| **Secret Handling**      | ConfigMap lookups   | ConnectionDetails with secret propagation |
| **Complexity**           | Lower               | Higher (requires Crossplane + providers)  |

## Structure

```
crossplane-compositions/
├── README.md
├── install/
│   └── crossplane-install.md          # Installation guide
├── storage-mi/
│   ├── definition.yaml                 # XRD: Defines the StorageApp API
│   ├── composition.yaml                # Composition: How to create resources
│   └── examples/
│       └── team-a-claim.yaml           # Example claim
└── cosmosdb-monitoring-mi/
    ├── definition.yaml                 # XRD: Defines the CosmosApp API
    ├── composition.yaml                # Composition: How to create resources
    └── examples/
        └── team-b-claim.yaml           # Example claim
```

## How It Works

### 1. Platform Team Creates XRDs and Compositions

The **CompositeResourceDefinition (XRD)** defines the developer-facing API:
- What parameters developers can set
- What status fields are exposed
- Schema validation

The **Composition** defines how those parameters map to underlying resources:
- ASO resources (StorageAccount, CosmosDB, etc.)
- Kubernetes resources (ServiceAccount, Deployment)
- Patches to transform values

### 2. Developers Create Claims

Developers create a **Claim** (namespaced resource) with minimal configuration:

```yaml
apiVersion: platform.example.com/v1alpha1
kind: StorageApp
metadata:
  name: my-app
  namespace: team-a
spec:
  appName: my-app
  resourceGroup: rg-team-a
```

### 3. Crossplane Reconciles

Crossplane:
1. Validates the claim against the XRD schema
2. Creates a Composite Resource (XR)
3. Creates all child resources defined in the Composition
4. Propagates status and connection details back to the claim

## Prerequisites

1. **Crossplane** installed in the cluster
2. **Upbound Azure Provider** or **Crossplane Provider for ASO** 
3. **ProviderConfig** with Azure credentials

## Comparison with Helm

| Aspect                   | Helm Chart                 | Crossplane Composition          |
| ------------------------ | -------------------------- | ------------------------------- |
| Developer creates        | HelmRelease                | StorageApp/CosmosApp claim      |
| Validation               | Template errors at runtime | Schema validation at apply time |
| Infrastructure discovery | ConfigMap lookups          | Patches with transforms         |
| Connection secrets       | Environment variables      | ConnectionDetails -> K8s Secret |
| Versioning               | Chart versions             | XRD/Composition versions        |

## When to Use Crossplane

✅ **Use Crossplane when:**
- You want strong API contracts with schema validation
- You need automatic connection secret propagation
- You're building a full Internal Developer Platform (IDP)
- Teams want a "platform-as-code" experience

❌ **Use Helm when:**
- Simpler requirements with familiar tooling
- Already invested in Flux/ArgoCD GitOps
- Lower operational overhead preferred

---

## Disclaimer

**This documentation is provided "as is" without warranty of any kind.** The author takes no responsibility for any errors, omissions, or inaccuracies contained herein. This material may contain incorrect or outdated information. Always verify configurations against official Microsoft Azure and Kubernetes documentation before use in production environments. Use at your own risk.

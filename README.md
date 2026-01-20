# Azure Service Operator v2 Multi-Tenant Platform Demos

This repository demonstrates multiple approaches to building a **multi-tenant platform** on Azure Kubernetes Service (AKS) using **Azure Service Operator v2 (ASO)**.

## What is ASO v2?

Azure Service Operator v2 enables you to provision and manage Azure resources directly from Kubernetes using custom resources. As an alternative to Terraform, ARM/Bicep templates, or portal-driven workflows, you define Azure resources as Kubernetes manifests — and ASO reconciles them to Azure.

## The Challenge: Templating for Multi-Tenancy

When multiple teams share an AKS cluster, you need a way to:

- **Abstract infrastructure complexity** — developers shouldn't need to know VNet IDs or DNS zone resource IDs
- **Enforce consistency** — all teams should follow the same patterns (private endpoints, managed identity, etc.)
- **Enable self-service** — teams can provision their own resources within guardrails
- **Maintain security boundaries** — each team's resources are isolated via namespaces and credentials

> **Note:** Namespace-based isolation is logical by default. Enforcement (e.g., Kyverno or Gatekeeper) is required for strict multi-tenant security.

This repo explores **three approaches** to solving this challenge, each with different trade-offs.

---

## Approaches

### 1. Helm Charts + ConfigMaps (Recommended)

**This is the primary approach and recommended starting point.**

Uses Helm charts with platform-provided ConfigMaps to inject infrastructure values. Developers create simple HelmReleases; the platform team maintains charts and ConfigMaps.

| Pros                          | Cons                         |
| ----------------------------- | ---------------------------- |
| Familiar tooling (Helm, Flux) | Requires Helm knowledge      |
| Strong ecosystem support      | Go templating can be complex |
| Easy GitOps integration       | Runtime validation only      |
| Moderate abstraction level    |                              |

📁 **Location:** [`helm-charts/`](helm-charts/)

📖 **Installation Guide:** [`install/aks-and-aso-v2-helm-installation.md`](install/aks-and-aso-v2-helm-installation.md)

*This guide sets up the shared AKS + ASO foundation required by all approaches.*

**Included Charts:**
- [`container-storage-mi`](helm-charts/container-storage-mi/) — Storage Account + Private Endpoint + Managed Identity
- [`container-cosmosdb-monitoring-mi`](helm-charts/container-cosmosdb-monitoring-mi/) — Cosmos DB + App Insights + Managed Identity

---

### 2. Crossplane Compositions

Uses Crossplane as an **abstraction layer on top of ASO**. Platform teams define XRDs (APIs) and Compositions; developers create simple Claims.

| Pros                               | Cons                               |
| ---------------------------------- | ---------------------------------- |
| Schema-validated APIs              | Higher operational complexity      |
| Strong abstraction                 | Additional controllers to manage   |
| Built-in secret propagation        | Steeper learning curve             |
| Product-style developer experience | ~500MB+ additional memory overhead |

📁 **Location:** [`crossplane-compositions/`](crossplane-compositions/)

📖 **Installation Guide:** [`crossplane-compositions/install/crossplane-install.md`](crossplane-compositions/install/crossplane-install.md)

**Included Compositions:**
- `StorageApp` — Storage Account + Private Endpoint + Managed Identity
- `CosmosDBApp` — Cosmos DB + Monitoring + Managed Identity

---

### 3. Kustomize Overlays

Uses Kustomize's patch-based approach with variable substitution. Teams maintain overlays that customize shared base templates.

| Pros                  | Cons                                |
| --------------------- | ----------------------------------- |
| Built into kubectl    | String-based substitution (fragile) |
| No additional tooling | No schema validation                |
| Simple mental model   | Silent failures possible            |
| Low overhead          | Best for infra-savvy teams          |

📁 **Location:** [`kustomize-overlays/`](kustomize-overlays/)

📖 **Guide:** [`kustomize-overlays/README.md`](kustomize-overlays/README.md)

**Included Bases:**
- `storage-mi` — Storage Account + Private Endpoint + Managed Identity
- `cosmosdb-monitoring-mi` — Cosmos DB + Monitoring + Managed Identity

---

## Quick Comparison

| Aspect                   | Helm + ConfigMaps | Crossplane          | Kustomize           |
| ------------------------ | ----------------- | ------------------- | ------------------- |
| **Abstraction Level**    | Medium            | High                | Low                 |
| **Developer Experience** | HelmRelease       | Claim (custom API)  | Overlay directory   |
| **Validation**           | Runtime           | Schema (OpenAPI)    | None (string-based) |
| **Operational Overhead** | Low               | High                | Minimal             |
| **Best For**             | Most teams        | Platform-as-product | Infra-savvy teams   |
| **Learning Curve**       | Medium            | Steep               | Low                 |

## Which Should I Choose?

```
┌─────────────────────────────────────────────────────────────────┐
│                  Start Here                                      │
│                      │                                           │
│         ┌────────────┴────────────┐                              │
│         ▼                         ▼                              │
│   Need strong API        Just need templating                    │
│   contracts & IDP?       for GitOps?                             │
│         │                         │                              │
│         ▼                         ▼                              │
│   ┌─────────────┐         ┌──────────────────┐                   │
│   │ Crossplane  │         │ Team comfortable │                   │
│   │ Compositions│         │ with raw YAML?   │                   │
│   └─────────────┘         └────────┬─────────┘                   │
│                                    │                             │
│                         ┌──────────┴──────────┐                  │
│                         ▼                     ▼                  │
│                   ┌──────────┐          ┌──────────┐             │
│                   │ Kustomize│          │  Helm +  │             │
│                   │ Overlays │          │ ConfigMap│             │
│                   └──────────┘          └──────────┘             │
│                   (infra teams)         (most teams)             │
└─────────────────────────────────────────────────────────────────┘
```

**For most organizations, start with Helm + ConfigMaps.** It provides a good balance of abstraction, familiarity, and ecosystem support. Migrate to Crossplane if you're building a full Internal Developer Platform (IDP) with product-style APIs.

---

## Prerequisites

All approaches require:

1. **AKS Cluster** with:
   - OIDC issuer enabled
   - Workload identity enabled
   - Azure CNI networking

2. **ASO v2** installed with workload identity authentication

3. **Network infrastructure**:
   - Hub/spoke VNets with peering
   - Private DNS zones for Azure services
   - Subnet for private endpoints

See the [main installation guide](install/aks-and-aso-v2-helm-installation.md) for complete setup instructions.

---

## Repository Structure

```
asov2demos/
├── README.md                          # This file
├── LICENSE
├── install/
│   └── aks-and-aso-v2-helm-installation.md   # Main setup guide
├── helm-charts/                       # Approach 1: Helm + ConfigMaps
│   ├── container-storage-mi/
│   └── container-cosmosdb-monitoring-mi/
├── crossplane-compositions/           # Approach 2: Crossplane
│   ├── install/
│   ├── storage-mi/
│   └── cosmosdb-monitoring-mi/
└── kustomize-overlays/                # Approach 3: Kustomize
    ├── base/
    └── overlays/
```

---

## Related Resources

- [Azure Service Operator v2 Documentation](https://azure.github.io/azure-service-operator/)
- [ASO Supported Resources](https://azure.github.io/azure-service-operator/reference/)
- [Crossplane Documentation](https://docs.crossplane.io/)
- [Kustomize Documentation](https://kustomize.io/)
- [Flux CD Documentation](https://fluxcd.io/docs/)

---

## Disclaimer

**This documentation is provided "as is" without warranty of any kind.** The author takes no responsibility for any errors, omissions, or inaccuracies contained herein. This material may contain incorrect or outdated information. Always verify configurations against official Microsoft Azure and Kubernetes documentation before use in production environments. Use at your own risk.

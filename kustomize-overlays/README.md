# Kustomize Overlays for ASO v2

This directory contains Kustomize overlays that provide the same functionality as the Helm charts, using Kustomize's patch-based approach.

## Why Kustomize?

| Feature                 | Helm + ConfigMaps | Kustomize                |
| ----------------------- | ----------------- | ------------------------ |
| **Templating**          | Go templates      | Patches & overlays       |
| **Configuration**       | values.yaml       | kustomization.yaml       |
| **Learning Curve**      | Medium            | Low                      |
| **Built-in to kubectl** | No                | Yes (`kubectl apply -k`) |
| **Secret Generation**   | External          | Built-in generators      |
| **Validation**          | Runtime           | kubectl dry-run          |
| **Complexity**          | Medium            | Low-Medium               |

## Structure

```
kustomize-overlays/
├── README.md
├── base/
│   ├── storage-mi/
│   │   ├── kustomization.yaml
│   │   ├── managed-identity.yaml
│   │   ├── federated-credential.yaml
│   │   ├── storage-account.yaml
│   │   ├── blob-container.yaml
│   │   ├── role-assignment.yaml
│   │   ├── private-endpoint.yaml
│   │   ├── service-account.yaml
│   │   └── deployment.yaml
│   └── cosmosdb-monitoring-mi/
│       ├── kustomization.yaml
│       ├── managed-identity.yaml
│       ├── federated-credential.yaml
│       ├── cosmosdb-account.yaml
│       ├── cosmosdb-database.yaml
│       ├── cosmosdb-container.yaml
│       ├── role-assignment.yaml
│       ├── private-endpoint.yaml
│       ├── log-analytics.yaml
│       ├── application-insights.yaml
│       ├── service-account.yaml
│       └── deployment.yaml
└── overlays/
    ├── team-a/
    │   └── storage-app/
    │       ├── kustomization.yaml
    │       └── config.env
    └── team-b/
        └── cosmosdb-app/
            ├── kustomization.yaml
            └── config.env
```

## Security and Multi-Tenancy

> **⚠️ Critical: Kustomize Provides No Security Boundary**
>
> Kustomize is a build-time tool — it does not provide isolation, authentication, or policy enforcement. Multi-tenant safety relies entirely on:
>
> | Layer | Responsibility |
> |-------|----------------|
> | **Namespace RBAC** | Prevent teams from modifying each other's resources |
> | **ASO credential secrets** | Each namespace uses its own Azure identity |
> | **Admission control** | Kyverno/Gatekeeper policies (as shown in the main ASO guide) |
>
> **Do not grant write access to shared `base/` directories in multi-tenant clusters.** Teams should only modify their own overlays. Platform teams own the bases.

## How It Works

### 1. Base Templates

The `base/` directory contains template YAML files with placeholder values like `$(APP_NAME)`, `$(RESOURCE_GROUP)`, etc.

### 2. Overlays with Substitutions

Each team/app overlay:
- Imports the base
- Provides a `config.env` file with variable values
- Uses `replacements` or `vars` to substitute placeholders
- Can add patches for customization

### 3. Apply with kubectl

```bash
# Preview
kubectl kustomize overlays/team-a/storage-app

# Apply
kubectl apply -k overlays/team-a/storage-app
```

## Comparison with Other Approaches

| Aspect                | Helm             | Crossplane       | Kustomize                                  |
| --------------------- | ---------------- | ---------------- | ------------------------------------------ |
| Developer creates     | HelmRelease      | Claim            | Overlay                                    |
| Variable substitution | Go templates     | Patches          | envsubst/replacements                      |
| Reusable components   | Charts           | Compositions     | Bases                                      |
| Versioning            | Chart versions   | XRD versions     | Git commits/tags (no semantic constraints) |
| GitOps integration    | Flux HelmRelease | Native CRs       | Flux Kustomization                         |
| Dependency management | Chart.yaml       | Composition refs | bases list                                 |

## When to Use Kustomize

✅ **Use Kustomize when:**
- Simple configuration needs (few variables)
- Team is already familiar with kubectl
- Prefer patch-based over template-based
- Want native kubectl integration
- Need quick environment-specific overrides

❌ **Use Helm/Crossplane when:**
- Complex logic or conditionals needed
- Many interdependent variables
- Need strong schema validation
- Building reusable marketplace charts

### How This Fits in a Platform Architecture

Kustomize overlays work best for teams that are comfortable managing infrastructure-level YAML and want minimal abstraction. Unlike Helm or Crossplane, Kustomize does not provide a product-style API or strong upgrade guarantees. In this model:

- **Crossplane Claims** ≈ Product API (developer self-service)
- **Helm Charts** ≈ Platform contract (versioned, validated)
- **Kustomize Overlays** ≈ Infrastructure ownership (direct YAML management)

ASO remains the system of record for Azure state, while Kustomize is simply a **build-time YAML assembler** — it has no runtime presence or reconciliation logic.

## Variable Substitution Strategy

This setup uses **envsubst-style variables** with Kustomize's `replacements` feature:

1. **Base files** use placeholders: `$(APP_NAME)`, `$(RESOURCE_GROUP)`
2. **Overlays** define a ConfigMap with actual values
3. **Kustomize replacements** substitute values at build time

> **⚠️ Important: Variable Substitution Limitations**
>
> Kustomize substitutions are **string-based** and **not schema-aware**:
>
> - Mistyped variable names produce no error at build time
> - Refactoring base files can silently break overlays
> - Invalid YAML only fails at ASO reconciliation time (not `kubectl apply`)
> - No type checking (a string `"true"` vs boolean `true`)
>
> For large platforms or long-lived APIs, consider Helm (with schema validation) or Crossplane (with typed XRD specs) for stronger safety guarantees.
>
> **Mitigation:** Use `kubectl apply --dry-run=server` and ASO's `--validate` flags in CI pipelines.

Example flow:
```yaml
# base/storage-mi/managed-identity.yaml
metadata:
  name: $(APP_NAME)-identity

# overlays/team-a/storage-app/kustomization.yaml
replacements:
  - source:
      kind: ConfigMap
      name: app-config
      fieldPath: data.APP_NAME
    targets:
      - select:
          kind: UserAssignedIdentity
        fieldPaths:
          - metadata.name
        options:
          delimiter: '-'
          index: 0
```

## Infrastructure Values

Similar to Helm's ConfigMap lookups, infrastructure values come from:

1. **Platform-provided ConfigMap** (in kube-public namespace)
2. **Overlay-specific config.env** file

For GitOps, use Flux `Kustomization` with `postBuild.substituteFrom` to inject values:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: team-a-storage-app
  namespace: flux-system
spec:
  path: ./kustomize-overlays/overlays/team-a/storage-app
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: aso-platform-config
      - kind: ConfigMap
        name: aso-team-config
```

---

## Disclaimer

**This documentation is provided "as is" without warranty of any kind.** The author takes no responsibility for any errors, omissions, or inaccuracies contained herein. This material may contain incorrect or outdated information. Always verify configurations against official Microsoft Azure and Kubernetes documentation before use in production environments. Use at your own risk.

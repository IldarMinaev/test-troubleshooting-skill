# Kubernetes Context Verification

Before running any troubleshooting skill, verify you are targeting the correct cluster and namespace.

## Step 1: Verify Current Context

```bash
kubectl config current-context
```

## Step 2: Verify Namespace

```bash
kubectl get namespace postgres
```

If the namespace is different, the user must specify it. Common namespace patterns:
- `postgres` (default for pgskipper-operator)
- `postgres-<env>` (e.g., `postgres-prod`, `postgres-staging`)
- Custom namespace as specified by the user

## Step 3: Quick Cluster Sanity Check

```bash
# Verify cluster is reachable and user has permissions
kubectl auth can-i get pods -n postgres
kubectl auth can-i exec pods -n postgres
```

## Step 4: Verify pgskipper-operator is Deployed

```bash
kubectl get crd patronicores.netcracker.com
kubectl get crd patroniservices.netcracker.com
```

If CRDs are not found, pgskipper-operator is not installed. See the README for installation instructions.

## Step 5: Detect Deployment Model (Helm vs ArgoCD)

```bash
# Check if ArgoCD is present and managing PGSkipper operator releases
kubectl get applications --all-namespaces 2>/dev/null | grep -iE 'patroni|postgres'

```

**Interpret**:
- If ArgoCD Applications are found managing the PostgreSQL Helm releases → **all remediation must go through Git + ArgoCD**, not `helm upgrade`. Note this and apply throughout all subsequent remediation steps.
- If no ArgoCD found → standard direct Helm remediation applies.

## Common Issues

- **Context not set**: Run `kubectl config use-context <context-name>`
- **No permissions**: Contact cluster admin for RBAC grants
- **Namespace not found**: The PostgreSQL installation may be in a different namespace — ask the user

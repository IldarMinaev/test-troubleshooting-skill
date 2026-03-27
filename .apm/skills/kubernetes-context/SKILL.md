---
name: kubernetes-context
description: Verify Kubernetes cluster context, namespace, and basic access permissions before running any troubleshooting skill
---

# Kubernetes Context Verification

Run this skill at the start of every troubleshooting session, before executing any `kubectl` or `helm` commands.

## Resolve the Target Namespace

Before running any steps, determine `<NAMESPACE>`:
1. If the user has specified a namespace, use that.
2. Otherwise, try to discover the namespace and ask the user to confirm.

All commands below use `<NAMESPACE>` — substitute the resolved value throughout.

## Step 1: Verify Current Context

```bash
kubectl config current-context
```

Confirm with the user that this is the intended cluster before proceeding.

## Step 2: Verify Namespace

```bash
kubectl get namespace <NAMESPACE>
```

If the namespace is not found, ask the user to confirm the correct one.

## Step 3: Quick Cluster Sanity Check

```bash
kubectl auth can-i get pods -n <NAMESPACE>
kubectl auth can-i exec pods -n <NAMESPACE>
```

If either returns `no`, stop and report the missing permission to the user.

## Output

After completing all steps, report:

1. **Cluster**: the context name
2. **Namespace**: the resolved `<NAMESPACE>`
3. **Permissions**: `get pods` and `exec pods` — allowed or blocked

Example summary:
> Context: `prod-cluster`, namespace: `postgres-prod`, permissions: OK.

## Common Issues

- **Context not set**: Run `kubectl config use-context <context-name>`
- **No permissions**: Contact cluster admin for RBAC grants
- **Namespace not found**: Ask the user for the correct namespace
- **kubectl fails in sandbox**: Ask the user to run the command locally and paste the output — do not attempt direct API connections as a workaround

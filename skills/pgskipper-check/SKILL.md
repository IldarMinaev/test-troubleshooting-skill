---
name: pgskipper-check
description: Check pgskipper-operator health — CRDs, Helm releases, CR statuses, operator deployments, logs, and events
---

# pgskipper-operator Health Check

## Purpose

Diagnose the health of pgskipper-operator infrastructure: CRDs, Helm releases, Custom Resource statuses, operator deployments, pods, and Kubernetes events.

## Prerequisites

- `kubectl` with access to the target cluster
- `helm` 3.x
- Namespace where pgskipper-operator is deployed (default: `postgres`)

**Read** [pgskipper-architecture.md](../_common/pgskipper-architecture.md) using the Read tool before proceeding — it contains operator component names, CRD names, and deployment conventions used in the steps below. Also see [kubernetes-context.md](../_common/kubernetes-context.md) for broader context.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access

```bash
kubectl config current-context
kubectl get namespace <NAMESPACE>
```

Ask the user for the namespace if not known. Default is `postgres`.

## Step 1: Check CRDs

```bash
kubectl get crd patronicores.netcracker.com
kubectl get crd patroniservices.netcracker.com
```

**Interpret**: Both CRDs must exist and show `ESTABLISHED`. If missing, pgskipper-operator was never installed or CRDs were deleted.

**Remediation**: Reinstall the operator via Helm chart.

## Step 2: Check Helm Releases

```bash
helm list -n <NAMESPACE> --filter 'patroni'
```

**Interpret**: Expect two releases: `patroni-core` and `patroni-services`, both with STATUS `deployed`.

| Status | Meaning |
|--------|---------|
| `deployed` | Healthy |
| `failed` | Last upgrade/install failed |
| `pending-install` | Stuck during install |
| `pending-upgrade` | Stuck during upgrade |

**Before proposing any remediation**, check whether these releases are managed by ArgoCD:
```bash
kubectl get applications --all-namespaces 2>/dev/null | grep -iE 'patroni|postgres'
```

**Remediation** for failed releases (direct Helm — no ArgoCD):
```bash
helm history -n <NAMESPACE> <release-name>
```

If a previous successful revision exists, suggest user to roll back to it:
```bash
helm rollback -n <NAMESPACE> <release-name> <revision>
```

**Remediation** for failed releases (ArgoCD-managed):
> ⚠️ Do not run or suggest to run `helm rollback` or `helm upgrade` — ArgoCD will revert any out-of-band Helm change on the next sync. Identify the ArgoCD Application and fix values in the Git source, then sync:
> ```bash
> argocd app sync <app-name> -n argocd
> ```

> ⚠️ **Do not patch CR or owned resources directly** — all parameter changes must go through the deployment tool (Helm or ArgoCD). See the Remediation Policy in [AGENTS.md](../../AGENTS.md).

## Step 3: Check Custom Resources

```bash
kubectl get patronicores -n <NAMESPACE> -o wide
kubectl get patroniservices -n <NAMESPACE> -o wide
```

Get detailed status:
```bash
kubectl get patronicores -n <NAMESPACE> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status}{"\n"}{end}'
kubectl get patroniservices -n <NAMESPACE> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status}{"\n"}{end}'
```

**Interpret**: Status should be `Successful`. Values: `In progress`, `Failed`, `Successful`.

**Remediation** for `Failed`:
```bash
kubectl describe patronicores -n <NAMESPACE> <name>
# Check events and conditions for failure reason
```

## Step 4: Check Operator Deployments

```bash
kubectl get deployments -n <NAMESPACE> | grep -E 'operator|patroni-core|postgres-operator'
```

Check pod status:
```bash
kubectl get pods -n <NAMESPACE> -l app.kubernetes.io/component=operator
```

**Interpret**: Operator pods must be `Running` with all containers ready (e.g., `1/1`).

**Remediation** for `CrashLoopBackOff`:
```bash
kubectl logs -n <NAMESPACE> <operator-pod> --previous --tail=50
kubectl describe pod -n <NAMESPACE> <operator-pod>
```

## Step 5: Check Operator Logs for Errors

```bash
# patroni-core-operator logs (last 50 lines, errors only)
kubectl logs -n <NAMESPACE> -l app.kubernetes.io/name=patroni-core-operator --tail=50 | grep -iE 'error|fatal|panic|fail'

# postgres-operator logs
kubectl logs -n <NAMESPACE> -l app.kubernetes.io/name=postgres-operator --tail=50 | grep -iE 'error|fatal|panic|fail'
```

**Interpret**: No errors is healthy. Recurring errors indicate reconciliation issues.

## Step 6: Check Kubernetes Events

```bash
kubectl get events -n <NAMESPACE> --sort-by='.lastTimestamp' --field-selector type=Warning | tail -20
```

For CR-specific events:
```bash
kubectl get events -n <NAMESPACE> --field-selector involvedObject.kind=PatroniCore
kubectl get events -n <NAMESPACE> --field-selector involvedObject.kind=PatroniServices
```

**Interpret**: Warning events may indicate scheduling failures, resource limits, image pull errors, or operator reconciliation issues.

## Step 7: Check StatefulSets

```bash
kubectl get statefulsets -n <NAMESPACE> -l app=patroni
```

**Interpret**:
- READY matches REPLICAS (e.g., `2/2`) = healthy
- READY < REPLICAS = **CRITICAL** — pods are failing to start. Check pod events and PVC binding.
- `0/0` replicas = **WARNING** — StatefulSet scaled down, no HA. If only the leader node is running, automatic failover is not possible. Verify whether this is intentional (dev/test) or accidental.

## Summary Report

Present findings as a table:

| Check | Status | Details |
|-------|--------|---------|
| CRD: patronicores | OK/MISSING | Established / Not found |
| CRD: patroniservices | OK/MISSING | Established / Not found |
| Helm: patroni-core | OK/WARNING/CRITICAL | deployed / failed / missing |
| Helm: patroni-services | OK/WARNING/CRITICAL | deployed / failed / missing |
| CR: PatroniCore | OK/WARNING/CRITICAL | Successful / In progress / Failed |
| CR: PatroniServices | OK/WARNING/CRITICAL | Successful / In progress / Failed |
| Operator pods | OK/CRITICAL | Running / CrashLoopBackOff / Missing |
| Operator logs | OK/WARNING | Clean / Errors found |
| Events | OK/WARNING | No warnings / Warnings present |
| StatefulSets | OK/CRITICAL | Ready / Not ready |

## Common Issues and Remediation

> Before suggesting any fix, run `kubectl get applications --all-namespaces 2>/dev/null | grep -iE 'patroni|postgres'` to determine whether releases are **direct Helm** or **ArgoCD-managed**. The fix path differs — see the Remediation Policy in [AGENTS.md](../../AGENTS.md).

1. **CRD not found**: Operator never installed
   - Direct Helm: `helm install patroni-core`
   - ArgoCD: create/sync the ArgoCD Application for `patroni-core`

2. **Helm release failed**: Check `helm history -n <NAMESPACE> <release-name>`
   - Direct Helm: roll back with `helm rollback`
   - ArgoCD: fix values in Git and run `argocd app sync`

3. **CR stuck "In progress"**: Check operator logs for reconciliation errors
   - Direct Helm: fix root cause via `helm upgrade` with corrected values (e.g., wrong `pgNodeQty`, missing config section)
   - ArgoCD: update values in Git and sync

4. **Operator CrashLoopBackOff**: Check previous logs, describe pod for resource/image issues
   - Direct Helm: fix resource limits or image via `helm upgrade`
   - ArgoCD: update values in Git and sync

5. **StatefulSet not ready**: Check pod events, PVC binding, node scheduling
   - Direct Helm: fix replica count or resource configuration via `helm upgrade`
   - ArgoCD: update values in Git and sync

6. **StatefulSet scaled to 0**: No HA
   - Direct Helm: restore replica count via `helm upgrade <release> -n <NAMESPACE> <chart> --reuse-values --set <replicaCountKey>=<N>`
   - ArgoCD: update replica count in Git values and sync
   - `kubectl scale statefulset` is acceptable **only if the StatefulSet was manually scaled** (not managed by the operator for that replica count)

> ⚠️ **Remediation policy**: Never use `kubectl patch`, `kubectl edit`, `kubectl scale`, or `kubectl delete` on operator-managed resources. All fixes must go through the deployment tool (Helm or ArgoCD). See [AGENTS.md](../../AGENTS.md) for the full policy.

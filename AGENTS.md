# PostgreSQL Troubleshooting Skills — Agent Guide

The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AgentMD file to help prevent future agents from having the same issue.

This repository contains AI-agent-agnostic skills for troubleshooting PostgreSQL databases managed by [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator) in Kubernetes, see <https://context7.com/netcracker/pgskipper-operator> for context. Applications connect to PostgreSQL via [DBAAS service](https://github.com/Netcracker/qubership-dbaas), see <https://context7.com/netcracker/qubership-dbaas> for context.

Each skill is a `SKILL.md` file that any AI agent reads and executes directly. No wrapper scripts, no test harnesses — the agent IS the execution engine.

---

## Default Cluster Assumptions

**Unless the user says otherwise, always assume:**

1. **PostgreSQL is managed by pgskipper-operator** — clusters are represented as `PatroniCore` and `PatroniServices` custom resources; all configuration flows through Helm charts `patroni-core` and `patroni-services`, applied either via direct `helm upgrade` or via an ArgoCD Application that manages the Helm release. Always detect PostgreSQL clusters first before asking questions about namespace or scope.
2. **Applications connect via DBAAS** — logical databases are provisioned through the DBAAS aggregator and adapter; microservices do not connect to PostgreSQL directly.
3. **Backups are via pgBackRest** managed by `postgres-backup-daemon`.

Cluster discovery must use **pgskipper-aware commands**, not generic pod listing:

```bash
# Discover PostgreSQL clusters
kubectl get patronicores --all-namespaces
kubectl get patroniservices --all-namespaces

# Discover Patroni pods (after namespace is known)
kubectl get pods -n <ns> -l app=patroni
kubectl get pods -n <ns> -l pgtype=master    # primary only

# Discover Helm releases
helm list -n <ns> --filter 'patroni'
```

See `skills/_common/pgskipper-architecture.md` and `skills/_common/dbaas-architecture.md` for full component reference.

**Anti-pattern**: Do NOT run `kubectl get pods -n <ns>` without a label selector to discover PostgreSQL pods — this produces noisy output and ignores the operator's resource model. Use CRD queries and label selectors instead.

---

## How to Use Skills

1. If the problem is vague, unclear, or spans multiple areas, start with `common-troubleshooting`
2. When the user describes a problem, identify which skill(s) match using the routing table below
3. Read the relevant `SKILL.md` file and follow its steps
4. Reference `skills/_common/` docs and `skills/_sql/` scripts as needed
5. If the issue spans multiple areas, combine skills (e.g., health-check + storage-check)

See `skills/_common/troubleshooting-decision-tree.md` for skills selection.
See `skills/_common/SECURITY.md` for the full credential security guide.

---

## When to Ask for More Information

Before running any commands, evaluate what the user has provided:

- **Sufficient** (symptom + scope + timeline) — proceed directly to the matching skill
- **Partial** (e.g., "the database is slow" with no context) — ask: Which namespace/cluster? When did it start? What changed? Which application?
- **Vague or multi-symptom** — use `common-troubleshooting` for structured intake

Never start investigating without knowing **what** is broken, **where** it is, and **since when**.

---

## Remediation Policy

**All configuration changes to operator-managed resources MUST go through the deployment tool (Helm or ArgoCD) — never via direct kubectl manipulation.**

pgskipper-operator manages PatroniCore and PatroniServices CRs (and the Kubernetes resources they own) declaratively through Helm charts. Bypassing the deployment tool creates drift, may be reverted on the next reconciliation or ArgoCD sync cycle, and removes rollback capability. Detect the deployment model before suggest changes.

### When kubectl is acceptable

Use `kubectl` for **read-only investigation** (get, describe, logs, exec for diagnostics) and for resources that are **not** Helm/operator-managed (e.g., manually created ConfigMaps, one-off jobs, namespace-level objects outside operator scope).

### How to propose a configuration fix

When a CR parameter needs correcting, first identify the deployment model, then suggest user steps to fix via detected deployment model. To find supported configuration parameters use context7 MCP or common architecture skills in this repo.

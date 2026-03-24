# PostgreSQL Troubleshooting Skills — Agent Instructions

This repository contains AI-agent-agnostic skills for troubleshooting PostgreSQL databases managed by [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator) in Kubernetes. Applications connect to PostgreSQL via [DBAAS service](https://github.com/Netcracker/qubership-dbaas).

Each skill is a `SKILL.md` file that any AI agent reads and executes directly. No wrapper scripts, no test harnesses — the agent IS the execution engine.

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

**Anti-pattern**: Do NOT run `kubectl get pods -n <ns>` without a label selector to discover PostgreSQL pods — use CRD queries and label selectors instead.

## How to Use Skills

1. If the problem is vague or spans multiple areas, start with `common-troubleshooting`
2. When the user describes a problem, identify which skill(s) match using the routing table in `skills/_common/troubleshooting-decision-tree.md`
3. Read the relevant `SKILL.md` file and follow its steps
4. Reference `skills/_common/` docs and `skills/_sql/` scripts as needed

## When to Ask for More Information

Before running any commands, evaluate what the user has provided:

- **Sufficient** (symptom + scope + timeline) — proceed directly to the matching skill
- **Partial** — ask: Which namespace/cluster? When did it start? What changed? Which application?
- **Vague or multi-symptom** — use `common-troubleshooting` for structured intake

## Remediation Policy

**All configuration changes to operator-managed resources MUST go through the deployment tool (Helm or ArgoCD) — never via direct kubectl manipulation.**

Use `kubectl` for **read-only investigation** only (get, describe, logs, exec for diagnostics).

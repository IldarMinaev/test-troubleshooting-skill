---
name: postgresql-troubleshooting-common
description: Shared reference documentation for PostgreSQL troubleshooting skills — security guide, credential handling, architecture references, patroni reference, Kubernetes context, and troubleshooting decision tree
---

# PostgreSQL Troubleshooting — Common References

Shared reference documentation used by all skills in the `qubership-postgresql-troubleshooting` package.
Install alongside any individual skill to make relative path references work correctly.

## Contents

| File | Purpose |
|------|---------|
| [SECURITY.md](SECURITY.md) | Credential security rules — inline retrieval patterns, never-do anti-patterns |
| [credential-handling.md](credential-handling.md) | Detailed credential handling patterns for DBAAS and PostgreSQL |
| [patroni-reference.md](patroni-reference.md) | Patroni configuration paths, data directory locations, command reference |
| [pgskipper-architecture.md](pgskipper-architecture.md) | pgskipper-operator component names, CRD names, deployment conventions |
| [dbaas-architecture.md](dbaas-architecture.md) | DBAAS service API endpoints, component names, namespace conventions |
| [kubernetes-context.md](kubernetes-context.md) | Kubernetes access patterns, context switching, label selectors |
| [troubleshooting-decision-tree.md](troubleshooting-decision-tree.md) | Symptom-to-skill quick lookup table |

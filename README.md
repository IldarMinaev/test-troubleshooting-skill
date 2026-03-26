# Common Troubleshooting Skills

Common troubleshooting methodology and shared reference documentation for Kubernetes-managed databases.

## Overview

Each skill is a **markdown prompt file** (`SKILL.md`) located in [skills](skills/) directory that any AI agent reads and executes directly. No wrapper scripts, no test harnesses — the AI agent IS the execution engine.

## Product-Specific Skills

Product-specific troubleshooting skills have been moved to their respective repositories:

- **PostgreSQL/pgskipper-operator**: [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator) — health checks, performance, storage, backups, connections, logs, monitoring
- **DBAAS**: [qubership-dbaas](https://github.com/Netcracker/qubership-dbaas) — aggregator health, API helper, architecture reference

## What Remains Here

- `common-troubleshooting` — Systematic hypothesis-driven investigation methodology
- Shared references — Security guide, Kubernetes context, troubleshooting decision tree

## Prerequisites

- `kubectl` configured with cluster access
- `helm` 3.x (for Helm release checks)
- `jq`, `curl`, `rg` (ripgrep), `stern`, `gron`

## References

- [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator)
- [qubership-dbaas](https://github.com/Netcracker/qubership-dbaas)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)

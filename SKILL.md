---
name: common-troubleshooting-skills
description: Common troubleshooting methodology and shared references — systematic hypothesis-driven investigation for Kubernetes-managed databases
---

# Common Troubleshooting Skills

A collection of common troubleshooting skills and shared reference documentation for systematically troubleshooting databases in Kubernetes.

Each skill is an executable markdown prompt that an AI agent reads and follows step-by-step.
No wrapper scripts — the agent IS the execution engine.

## Prerequisites

- `kubectl` configured with cluster access and exec permissions
- `helm` 3.x (for Helm release checks)
- `jq`, `curl`, `rg` (ripgrep), `stern`, `gron`

## Available Skills

| Skill | Description |
|-------|-------------|
| [`common-troubleshooting`](skills/common-troubleshooting/SKILL.md) | Systematic hypothesis-driven troubleshooting — problem definition, investigation, root cause analysis, verified resolution |

## Shared Resources

- [`skills/_common/`](skills/_common/) — Security guide, Kubernetes context guide, troubleshooting decision tree

## Product-Specific Skills

PostgreSQL/pgskipper-operator troubleshooting skills have been moved to their respective product repositories:

| Repository | Skills |
|-----------|--------|
| [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator) | `pgskipper-check`, `postgresql-health-check`, `postgresql-performance-check`, `postgresql-storage-check`, `postgresql-backup-check`, `postgresql-connection-check`, `postgresql-log-analyzer`, `postgresql-sql-runner`, `monitoring-check` |
| [qubership-dbaas](https://github.com/Netcracker/qubership-dbaas) | `dbaas-check`, `dbaas-api-helper` |

## Security

All credential handling follows the inline retrieval pattern from [`skills/_common/SECURITY.md`](skills/_common/SECURITY.md).
Passwords are never stored in variables or exposed in command output.

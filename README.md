# PostgreSQL Troubleshooting AI Skills

AI-agent-agnostic skills for troubleshooting PostgreSQL databases managed by [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator) in Kubernetes, see <https://context7.com/netcracker/pgskipper-operator> for context. Applications connect to PostgreSQL via [DBAAS service](https://github.com/Netcracker/qubership-dbaas), see <https://context7.com/netcracker/qubership-dbaas> for context.

## Overview

Each skill is a **markdown prompt file** (`SKILL.md`) located in [skills](skills/) directory that any AI agent reads and executes directly. No wrapper scripts, no test harnesses — the AI agent IS the execution engine.

## Prerequisites

- Kubernetes cluster with pgskipper-operator deployed
- `kubectl` configured with cluster access
- `kubectl krew` plugin manager for kubectl
- `kubectl ctx` fast context and namespace switching.
- `helm` 3.x (for Helm release checks)
- `jq`
- `curl`
- ripgrep (`rg`)
- `stern` kubectl plugin to get logs from multiple pods at once
- `gron` gron transforms JSON into discrete assignments to make it easier to grep for what you want and see the absolute 'path' to it.
- `docker` to run MCP servers.

## References

- [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)

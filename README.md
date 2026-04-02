# Common Troubleshooting Skills

Common troubleshooting methodology and shared reference documentation for Kubernetes-managed platform components.

## Overview

Each skill is a **markdown prompt file** (`SKILL.md`) that any AI agent reads and executes directly. No wrapper scripts, no test harnesses — the AI agent IS the execution engine.

## APM

[APM](https://github.com/microsoft/apm/) used to manage AI artifacts packages (skills, promts, instruction, MCPs, etc).

## What Remains Here

- `common-troubleshooting` — Systematic hypothesis-driven investigation methodology
- Shared references — Security guide, Kubernetes context, troubleshooting decision tree

## Prerequisites

- `kubectl` configured with cluster access
- `helm` 3.x (for Helm release checks)
- `jq`, `curl`, `rg` (ripgrep), `stern`, `gron`


# Common Troubleshooting Skills — Agent Guide

The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project.

This repository contains a common troubleshooting methodology and shared reference documentation. Product-specific skills have been moved to their respective repositories:

- **PostgreSQL/pgskipper-operator skills** → [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator)
- **DBAAS skills** → [qubership-dbaas](https://github.com/Netcracker/qubership-dbaas)

---

## How to Use Skills

1. If the problem is vague, unclear, or spans multiple areas, start with `common-troubleshooting`
2. When the user describes a problem, identify which skill(s) match using `skills/_common/troubleshooting-decision-tree.md`
3. Read the relevant `SKILL.md` file and follow its steps
4. Skills for specific products are in the product repositories listed above

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

### When kubectl is acceptable

Use `kubectl` for **read-only investigation** (get, describe, logs, exec for diagnostics) and for resources that are **not** Helm/operator-managed.

### How to propose a configuration fix

When a CR parameter needs correcting, first identify the deployment model, then suggest user steps to fix via detected deployment model.

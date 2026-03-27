---
name: common-troubleshooting
description: Systematic hypothesis-driven troubleshooting — problem definition, investigation, root cause analysis, verified resolution
---

# Common Troubleshooting Methodology

## Purpose

A structured, hypothesis-driven investigation process for PostgreSQL/Kubernetes problems. This is a **meta-skill** — it contains no kubectl or psql commands. Instead, it defines a 7-step methodology that delegates all data collection to existing skills.

Use this skill when:
- The problem is vague ("something is wrong", "the database is slow sometimes")
- The issue spans multiple areas (connections + storage + performance)
- Initial skill runs didn't reveal a clear root cause
- You want a documented investigation trail with root cause analysis

## Prerequisites

Before starting any investigation:

1. Run the [`kubernetes-context`](../kubernetes-context/SKILL.md) skill to verify cluster access and resolve the target namespace.
2. Ensure the user is available to answer clarifying questions throughout the session.

See the [`troubleshooting-triage`](../../prompts/troubleshooting-triage.prompt.md) prompt for quick symptom-to-skill lookup when the problem is already clear.

## Step 1: Problem Intake

Gather structured information from the user before forming any hypothesis.

### 1.1 Ask these questions

1. **What is the symptom?** — What exactly is failing or degraded? (error messages, timeouts, slow responses)
2. **When did it start?** — Exact time or approximate window. Is it ongoing or intermittent?
3. **What is the scope?** — One database, one namespace, one cluster, or multiple? Which application(s) affected?
4. **What changed recently?** — Deployments, config changes, scaling events, infrastructure maintenance, traffic spikes
5. **What has already been tried?** — Any troubleshooting already done, restarts performed, changes reverted

### 1.2 Formulate the problem statement

Synthesize the answers into a single sentence:

> **Problem statement**: [Symptom] affecting [scope] since [time], with [relevant context/changes].

Example: "Intermittent connection timeouts affecting service-X in namespace `prod-pg` since 14:00 UTC, following a Helm upgrade of the patroni chart at 13:45."

### 1.3 Confirm with user (mandatory checkpoint)

Present the problem statement to the user and ask:
- "Does this accurately capture the issue?"
- "Is there anything else I should know before investigating?"

**Do not proceed until the user confirms.**

## Step 2: Symptom Classification

Map the confirmed problem to an investigation path and form the first hypothesis.

### 2.1 Symptom routing table

| Symptom Category | Primary Skill | Secondary Skills |
|------------------|---------------|------------------|
| Connection failures / timeouts | postgresql-connection-check | postgresql-health-check, pgskipper-check |
| Slow queries / high latency | postgresql-performance-check | postgresql-connection-check, postgresql-storage-check |
| Replication lag / replica issues | postgresql-health-check | postgresql-storage-check, postgresql-log-analyzer |
| Disk space / storage alerts | postgresql-storage-check | postgresql-backup-check, postgresql-performance-check |
| Backup failures | postgresql-backup-check | pgskipper-check |
| Pod crashes / restarts | postgresql-health-check | postgresql-log-analyzer, pgskipper-check |
| Operator errors / CR stuck | pgskipper-check | postgresql-log-analyzer |
| Missing metrics / monitoring gaps | monitoring-check | postgresql-health-check |
| DBAAS API errors / missing DBs | dbaas-check | dbaas-api-helper |
| Unknown / vague symptoms | postgresql-health-check | pgskipper-check, postgresql-log-analyzer |

> **Note**: PostgreSQL skills (`pgskipper-check`, `postgresql-*`, `monitoring-check`) are located in the [pgskipper-operator](https://github.com/Netcracker/pgskipper-operator) repository. DBAAS skills (`dbaas-check`, `dbaas-api-helper`) are located in the [qubership-dbaas](https://github.com/Netcracker/qubership-dbaas) repository.

### 2.2 Form the first hypothesis

State an explicit, falsifiable hypothesis:

> **Hypothesis 1**: [Proposed cause] is causing [observed symptom] because [reasoning].
>
> **Expected evidence**: If this hypothesis is correct, [skill] should show [specific expected finding].
>
> **Refutation**: If [skill] shows [alternative finding], this hypothesis is wrong.

Example:
> **Hypothesis 1**: PgBouncer pool exhaustion is causing connection timeouts because the Helm upgrade may have changed pool_size settings.
>
> **Expected evidence**: postgresql-connection-check should show pool utilization near 100% or `cl_waiting` > 0.
>
> **Refutation**: If pool utilization is low and no clients are waiting, the problem is elsewhere.

## Step 3: Focused Investigation

Run the minimum necessary checks to evaluate the current hypothesis.

### 3.1 Execute one skill at a time

Run the **primary skill** identified in Step 2. Do not run multiple skills speculatively — each round should test one hypothesis.

### 3.2 Evaluate findings against hypothesis

After the skill completes, answer:
- Does the evidence **support** or **refute** the hypothesis?
- Are there **unexpected findings** that suggest a different cause?
- Is more data needed from a **secondary skill**?

### 3.3 Record findings

Keep a running log:

> **Round 1**: Ran `postgresql-connection-check`.
> - Finding: Pool utilization at 30%, no waiting clients.
> - Verdict: **Hypothesis 1 refuted** — PgBouncer is not the bottleneck.
> - New clue: Noticed 15 `idle in transaction` connections from service-Y.

### 3.4 Checkpoint with user (mandatory)

After each investigation round, summarize:
1. What was checked
2. What was found
3. Whether the hypothesis was supported or refuted
4. What the next step is

Ask: "Should I continue with [next action], or do you have additional context based on these findings?"

## Step 4: Hypothesis Refinement

When a hypothesis is refuted, form a better one using the accumulated evidence.

### 4.1 Layer-walking technique

If the cause isn't obvious, walk the stack systematically:

1. **Application layer** — Is the app sending bad queries, leaking connections, or misconfigured?
2. **Connection pooler** — Is PgBouncer healthy, correctly configured, and not saturated?
3. **PostgreSQL** — Are there internal issues (locks, bloat, autovacuum, config)?
4. **Patroni** — Is the cluster stable, replication healthy, no recent failovers?
5. **Kubernetes** — Are pods healthy, resources sufficient, nodes stable?
6. **Operator** — Is pgskipper-operator healthy, CRs in expected state?
7. **Storage** — Are PVCs healthy, disk space sufficient, I/O not saturated?

### 4.2 Timeline correlation

When multiple clues exist, correlate them with the problem timeline:
- What changed at or just before the symptom started?
- Do the findings explain the timing?
- Are there periodic patterns (cron jobs, batch processing, backup windows)?

### 4.3 Form the next hypothesis

Use the same format as Step 2.2, incorporating evidence from previous rounds.

### 4.4 Escalation guard (mandatory checkpoint)

**After 3 hypothesis rounds**, stop and re-engage the user. A round counts as completed when:
- **Refuted** — evidence clearly contradicts the hypothesis
- **Inconclusive** — the skill ran but results neither confirm nor refute (e.g., all values look normal)

Both count toward the limit. Only a **confirmed** hypothesis (evidence matches prediction) exits this loop.

> "I've tested 3 hypotheses without finding the root cause. Here's what I've ruled out:
> 1. [Hypothesis 1] — refuted because [reason]
> 2. [Hypothesis 2] — refuted because [reason]
> 3. [Hypothesis 3] — refuted because [reason]
>
> I'd like your input before continuing. Are there any details about the environment or recent changes that might point me in a new direction?"

Do not continue beyond 3 failed hypotheses without fresh user input.

## Step 5: Root Cause Confirmation

Once a hypothesis is supported by evidence, verify it is the **root cause**, not another symptom.

### 5.1 Apply the 5 Whys

Ask "why" iteratively to drill past symptoms to the root:

1. **Why** are connections timing out? — Because PgBouncer has no available connections.
2. **Why** are there no available connections? — Because 95% are held by `idle in transaction` sessions.
3. **Why** are sessions idle in transaction? — Because service-Y opens a transaction but doesn't commit during HTTP timeouts.
4. **Why** doesn't service-Y commit during timeouts? — Because it lacks a transaction timeout and the downstream API is slow.
5. **Root cause**: Service-Y has no transaction timeout, causing connection leaks when downstream APIs are slow.

### 5.2 Verify completeness

Confirm the root cause explains **all** observed symptoms:
- Does it explain the timing? (when it started)
- Does it explain the scope? (which services/databases are affected)
- Does it explain intermittent behavior? (if applicable)

If the root cause doesn't explain all symptoms, there may be multiple contributing causes — investigate further.

## Step 6: Solution & Verification

### 6.1 Propose solution (mandatory checkpoint)

Present the solution with:

| Aspect | Detail |
|--------|--------|
| **Root cause** | [One sentence] |
| **Proposed fix** | [Specific action(s)] |
| **Risk** | [What could go wrong] |
| **Downtime** | [Expected impact: none / brief / extended] |
| **Reversibility** | [How to roll back if it doesn't work] |

**Wait for explicit user approval before making any changes.**

### 6.2 Apply the fix

Execute the approved fix, using the appropriate skill(s) for any commands needed.

> **Remediation policy — deploy-tool first, always**: For any fix that changes a configuration parameter of an operator-managed resource (for example, PatroniCore, PatroniServices, or any resource owned by Helm), the fix **must** go through the deployment tool — `helm upgrade` for direct-Helm installs, or a Git value update + `argocd app sync` for ArgoCD-managed installs. Never use `kubectl patch`, `kubectl edit`, `kubectl scale`, or `kubectl delete` on operator-managed resources — these bypass deployment-tool state tracking, may be reverted on the next reconciliation or sync cycle, and lose rollback capability.

### 6.3 Verify resolution

After applying the fix:
1. Re-run the skill that originally revealed the problem
2. Confirm the symptom is resolved
3. Check for side effects using related skills

### 6.4 Rollback path

If the fix doesn't resolve the issue or causes new problems:
1. Execute the rollback steps defined in 6.1
2. Return to Step 4 to form a new hypothesis

## Step 7: Prevention & Report

### 7.1 Prevention recommendations

Suggest improvements to prevent recurrence, categorized by type:

- **Monitoring** — New alerts, dashboards, or metrics to catch this earlier
- **Configuration** — Settings to change (timeouts, limits, pool sizes)
- **Process** — Runbook updates, change management improvements
- **Architecture** — Structural changes to eliminate the failure mode

### 7.2 Investigation report

Produce a structured RCA report:

```markdown
## Root Cause Analysis

**Problem**: [Problem statement from Step 1]
**Root cause**: [Root cause from Step 5]
**Resolution**: [Fix applied in Step 6]
**Duration**: [Time from symptom start to resolution]

### Timeline
| Time | Event |
|------|-------|
| HH:MM | [Symptom first reported] |
| HH:MM | [Investigation started] |
| HH:MM | [Key finding] |
| HH:MM | [Fix applied] |
| HH:MM | [Resolution confirmed] |

### Investigation Path
1. **Hypothesis 1**: [description] — [supported/refuted] — [evidence]
2. **Hypothesis 2**: [description] — [supported/refuted] — [evidence]
...

### Prevention
- [Recommendation 1]
- [Recommendation 2]
```

## Anti-Patterns

Avoid these common troubleshooting mistakes:

| Anti-Pattern | Description | Instead |
|-------------|-------------|---------|
| **Shotgun debugging** | Running every skill hoping something shows up | Form a hypothesis first, then run one targeted skill |
| **Symptom chasing** | Fixing what you see without asking "why" | Use the 5 Whys to find the root cause |
| **Tunnel vision** | Fixating on one theory despite contradicting evidence | If evidence refutes the hypothesis, let it go and form a new one |
| **Skipping the user** | Investigating in isolation without checkpoints | Share findings after each round — the user often has context you don't |
| **Premature fixing** | Applying a fix before confirming the root cause | Confirm the cause explains all symptoms before acting |
| **Ignoring the timeline** | Not correlating findings with when the problem started | Always ask "does this explain the timing?" |
| **Direct kubectl patching** | Using `kubectl patch`, `kubectl edit`, `kubectl scale`, or `kubectl delete` on operator-managed resources | Fix via `helm upgrade` (direct Helm) or Git + `argocd app sync` (ArgoCD-managed) — the deployment tool is the source of truth |
| **Manual pod deletion** | Deleting a stuck operator-managed pod hoping it resolves the issue | Find the root cause (misconfiguration, test failure, etc.) and fix via the deployment tool; the operator will re-create the pod correctly |
| **helm upgrade in ArgoCD environment** | Running `helm upgrade` when releases are managed by ArgoCD | ArgoCD will revert the change on next sync — update values in Git and use `argocd app sync` instead |

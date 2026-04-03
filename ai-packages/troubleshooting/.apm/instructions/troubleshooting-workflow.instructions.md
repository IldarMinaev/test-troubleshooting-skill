---
applyTo: "**"
---

## Troubleshooting: MUST follow the skill chain

MANDATORY SEQUENCE for any k8s/PostgreSQL issue:
1. `troubleshooting-triage` — maps symptom to skill sequence
2. `kubernetes-context` — verify cluster/namespace/RBAC
3. Follow triage-recommended skills
4. Only use raw kubectl/psql for gaps the skills don't cover

The FIRST tool call after kubernetes-context should be a Skill invocation, not a kubectl command. If you catch yourself running raw psql/kubectl for investigation (not targeted follow-up), STOP and invoke the appropriate skill instead. Treat the skill chain as mandatory dispatch, not a suggestion.

### Skill usage

Raw kubectl/psql is ONLY for targeted follow-up after a skill has identified a specific area needing deeper inspection.

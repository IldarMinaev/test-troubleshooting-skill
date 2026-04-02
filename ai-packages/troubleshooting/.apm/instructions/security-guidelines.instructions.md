---
applyTo: "**"
---

# Security Guidelines for Skills

These rules apply to all skills that access any secret (like application credentials, PostgreSQL connection strings with creds, Kubernetes secrets, credentials, etc). They are non-negotiable and must be followed without exception.

---

## Credential Exposure Prevention

### The Golden Rule

**NEVER expose passwords or secrets in command output, logs, or tool results.**

### ✅ CORRECT Patterns

**Pattern 1: Inline subshell (PREFERRED)**
```bash
kubectl exec -n <NAMESPACE> <POD> -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -c "SELECT 1"
```
✅ Password is retrieved inline and never appears in output

**Pattern 2: Chained commands with &&**
```bash
PGPASS=$(kubectl get secret -n postgres postgres-credentials -o jsonpath='{.data.password}' | base64 -d) && \
kubectl exec -n postgres pg-master-0 -- env PGPASSWORD="$PGPASS" psql -U postgres -c "SELECT 1"
```
✅ Variable is set and used in one command chain

**Pattern 3: Multiple commands in one exec session**
```bash
kubectl exec -n <NAMESPACE> <POD> \
  -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials \
       -o jsonpath='{.data.password}' | base64 -d)" \
  bash -c 'psql -U postgres -c "SELECT 1"; psql -U postgres -c "SELECT 2"'
```
✅ Single outer shell expansion; password never stored or printed

---

### ❌ FORBIDDEN Patterns

**❌ NEVER: Separate credential retrieval command**
```bash
# THIS WILL EXPOSE THE PASSWORD IN OUTPUT!
kubectl get secret -n postgres postgres-credentials -o jsonpath='{.data.password}' | base64 -d
# Output: MYrootPWD  ← EXPOSED!
```

**❌ NEVER: Hardcode passwords**
```bash
# DO NOT hardcode passwords from previous retrieval
env PGPASSWORD="MYrootPWD" psql ...
```

**❌ NEVER: Echo or display secrets**
```bash
echo $PGPASSWORD
kubectl get secret postgres-credentials -o yaml  # Shows base64 password
```

**❌ NEVER: Store passwords in files**
```bash
kubectl get secret ... > /tmp/password.txt  # Insecure!
```

---

## Why This Matters

When you execute a command that outputs a password:

1. **Tool results** capture the password in plain text
2. **Logs** may contain the command output
3. **Conversation history** stores the exposed credential
4. **Shell history** records the literal password
5. **Audit trails** show the security violation

In production environments, this can lead to:
- Security breaches
- Compliance violations (SOC2, PCI-DSS, HIPAA)
- Credential compromise
- Audit failures

---

## Pre-Execution Checklist

Before running ANY command that uses credentials:

- [ ] Am I using inline password retrieval (subshell pattern)?
- [ ] Have I confirmed the password will NOT appear in command output?
- [ ] Am I using chained commands (&&) or a single command?
- [ ] Have I avoided separate `kubectl get secret` commands?

**If you answer "NO" to any of these, DO NOT PROCEED.**

---

## LLM-Specific Guidance

### When Using the Bash Tool

**CORRECT approach:**
1. Chain credential retrieval with usage using `&&`
2. Use inline subshells `$(...)`
3. Never split into multiple Bash tool calls

```bash
# ✅ Single Bash tool call, no exposure
PGPASS=$(kubectl get secret -n postgres postgres-credentials -o jsonpath='{.data.password}' | base64 -d) && \
kubectl exec -n postgres pg-master-0 -- env PGPASSWORD="$PGPASS" psql -U postgres -c "SELECT 1"
```

**WRONG approach:**
```bash
# ❌ First Bash call - exposes password
kubectl get secret -n postgres postgres-credentials -o jsonpath='{.data.password}' | base64 -d

# ❌ Second Bash call - uses hardcoded password
kubectl exec -n postgres pg-master-0 -- env PGPASSWORD="MYrootPWD" psql -U postgres -c "SELECT 1"
```

### When Reading Skill Files

1. If a skill shows `PGPASSWORD=$(...)` in a "Context" section, this is documentation of the variable name, NOT a command to run separately
2. Always look for the actual command execution pattern that uses the inline retrieval
3. Adapt the pattern to use inline subshells or chained commands

---

## Additional Security Rules

1. **Read-only by default**: Use SELECT/SHOW queries only
2. **Never run DDL/DML** (CREATE, DROP, UPDATE, DELETE) without explicit user approval
3. **Set statement_timeout**: Prevent runaway queries
4. **Use LIMIT**: Prevent excessive result sets
5. **Verify context**: Always check Kubernetes context before execution
6. **Audit trail**: Log what you're checking, but never log credentials

---

## Quick Reference

| Scenario | Pattern |
|----------|---------|
| Single SQL query | `kubectl exec ... -- env PGPASSWORD="$(kubectl get secret ... \| base64 -d)" psql -c "..."` |
| Multiple queries | Chain with `&&` or use bash wrapper |
| SQL from file | Same pattern, use `-f /dev/stdin < file.sql` |
| Variable needed multiple times | Set with `&&` chain: `VAR=$(...) && use $VAR && use $VAR` |


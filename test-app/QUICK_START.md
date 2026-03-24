# Trouble Generator - Quick Start Guide

## 🚀 5-Minute Start

```bash
# 1. Build
cd test-app && ./build.sh my-business-app:latest

# 2. Deploy trouble scenario
cd scenarios
NAMESPACE=test ./deploy-scenario.sh deploy slow-queries

# 3. Wait 3 minutes, then test AI
claude-code "Check database performance in namespace test"

# 4. Stop
./deploy-scenario.sh stop slow-queries
```

## 📦 Available Scenarios

| Scenario | Detects | Time | Intensity |
|----------|---------|------|-----------|
| `slow-queries` | Long-running queries | 2-3 min | high |
| `pool-exhaustion` | Connection saturation | 1-2 min | high |
| `disk-fill` | Storage consumption | 5-10 min | medium |
| `lock-contention` | Lock conflicts | 2-3 min | medium |
| `idle-in-transaction` | Stuck connections | 2-3 min | medium |
| `vacuum-issues` | Table bloat | 10-15 min | medium |
| `wal-accumulation` | WAL growth | 5-10 min | low |
| `compound-issue` | Multiple problems | 5-7 min | medium |

## 🎯 Common Commands

```bash
# List scenarios
./deploy-scenario.sh list

# Deploy
./deploy-scenario.sh deploy <scenario>

# Check status
./deploy-scenario.sh status <scenario>

# View logs
./deploy-scenario.sh logs <scenario>

# Stop
./deploy-scenario.sh stop <scenario>

# Stop all
./deploy-scenario.sh stop-all
```

## 🧪 Test Workflows

### Test Performance Skill
```bash
./deploy-scenario.sh test slow-queries
# Wait 3 minutes
claude-code "Database is slow in namespace test"
```

### Test Connection Skill
```bash
./deploy-scenario.sh test pool-exhaustion
# Wait 2 minutes
claude-code "Getting connection timeouts"
```

### Test Compound Investigation
```bash
./deploy-scenario.sh test compound-issue
# Wait 5 minutes
claude-code "Something's wrong with the database"
```

## 🎮 Runtime Control API

```bash
# Port-forward
kubectl port-forward svc/trouble-slow-queries 8080:8080 &

# List active
curl http://localhost:8080/api/troubles/active | jq .

# Enable scenario
curl -X POST http://localhost:8080/api/troubles/enable \
  -H "Content-Type: application/json" \
  -d '{"scenario":"lock-contention","intensity":"high"}'

# Emergency stop
curl -X POST http://localhost:8080/api/emergency-stop
```

## ⚙️ Configuration

Set via environment variables or ConfigMap:

```yaml
MODE: trouble                           # Enable trouble mode
TROUBLE_SCENARIOS: slow-queries         # Or comma-separated list
TROUBLE_INTENSITY: medium               # low|medium|high|extreme
TROUBLE_DURATION: 1800                  # Seconds (0=infinite)
CONTROL_API_ENABLED: true               # Enable HTTP API
```

## 🎬 Demo Script (5 min)

```bash
# === Setup (30 sec) ===
./deploy-scenario.sh deploy slow-queries

# === Wait (3 min) ===
echo "Waiting for slow queries to appear..."
sleep 180

# === Demo (1 min) ===
echo "User reports: Application is slow"
claude-code "The database seems slow, investigate"

# AI should identify:
# - Long-running cross-join queries
# - High CPU usage
# - pg_stat_activity evidence

# === Cleanup (30 sec) ===
./deploy-scenario.sh stop slow-queries
```

## 🔧 Troubleshooting

### Scenario not starting?
```bash
# Check logs
kubectl logs -l app=trouble-generator

# Common fixes:
# - Verify DBAAS credentials
# - Check resource limits
# - Ensure namespace exists
```

### Issue not manifesting?
```bash
# Wait longer (5-10 min for some scenarios)
# Try higher intensity
# Check database has data (run workload first)
```

### Emergency cleanup?
```bash
# Stop all scenarios
./deploy-scenario.sh stop-all

# Delete stuck resources
kubectl delete pods,deployments,services,configmaps \
  -l app=trouble-generator -n <namespace>
```

## 📚 Documentation

- **README.md** - Full usage guide
- **TROUBLE_GENERATOR.md** - Architecture details
- **TROUBLE_GENERATOR_PROPOSAL.md** - Design proposal

## 💡 Tips

- Start with `slow-queries` - fastest to manifest
- Use `medium` intensity for demos (predictable, visible)
- Enable Control API for live demos (`CONTROL_API_ENABLED=true`)
- Test in isolated namespace first
- Always check logs if scenario doesn't work
- `compound-issue` requires 5+ min ramp-up

## 🎯 Expected AI Behavior

| Scenario | AI Skill Used | Key Findings |
|----------|---------------|--------------|
| slow-queries | postgresql-performance-check | Cross-join queries, high duration |
| pool-exhaustion | postgresql-connection-check | Pool 95%+ full, queue backlog |
| disk-fill | postgresql-storage-check | Disk >80%, large table growth |
| compound-issue | common-troubleshooting | Multiple issues, prioritized list |

---

**Need help?** Check logs: `./deploy-scenario.sh logs <scenario>`

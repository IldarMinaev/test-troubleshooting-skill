# Test Application & Trouble Generator

This application serves two purposes:

1. **Workload Mode**: Generate realistic database workload for load testing
2. **Trouble Mode**: Generate specific PostgreSQL issues for testing AI troubleshooting skills

## Quick Start

### Build the Image

```bash
cd test-app
./build.sh my-business-app:v1.0.0
```

### Deploy in Workload Mode

Generate normal database load:

```bash
helm install test-app ./helm/test-app \
  --set image.tag=v1.0.0 \
  --set dbaas.url="http://dbaas-aggregator:8080" \
  --set dbaas.user="dba_client" \
  --set dbaas.password="your-password"
```

### Deploy in Trouble Mode

Generate specific issues for AI testing:

```bash
# Option 1: Using the helper script (recommended)
cd scenarios
NAMESPACE=my-namespace ./deploy-scenario.sh deploy slow-queries

# Option 2: Direct kubectl apply
kubectl apply -f scenarios/slow-queries.yaml -n my-namespace

# Option 3: Using Helm with custom values
cat > trouble-values.yaml <<EOF
image:
  tag: v1.0.0
mode: trouble
troubleScenarios:
  enabled:
    - slow-queries
    - pool-exhaustion
  intensity: high
  duration: 3600
dbaas:
  url: http://dbaas-aggregator:8080
  user: dba_client
  password: your-password
EOF

helm install trouble-gen ./helm/test-app -f trouble-values.yaml
```

## Available Trouble Scenarios

| Scenario | Description | Detectable By | Intensity Levels |
|----------|-------------|---------------|------------------|
| **slow-queries** | Long-running cross-join queries | postgresql-performance-check | low, medium, high, extreme |
| **missing-indexes** | Full table scans on unindexed columns | postgresql-performance-check | low, medium, high, extreme |
| **lock-contention** | Row-level lock competition | postgresql-performance-check | low, medium, high, extreme |
| **vacuum-issues** | Table bloat from prevented autovacuum | postgresql-performance-check, postgresql-storage-check | low, medium, high, extreme |
| **pool-exhaustion** | PgBouncer pool saturation | postgresql-connection-check | low, medium, high, extreme |
| **idle-in-transaction** | Connections stuck idle | postgresql-connection-check | low, medium, high, extreme |
| **disk-fill** | Rapid disk consumption | postgresql-storage-check | low, medium, high, extreme |
| **wal-accumulation** | WAL files not cleaned up | postgresql-storage-check | low, medium, high, extreme |

## Usage Examples

### Example 1: Test Performance Troubleshooting Skill

```bash
# 1. Deploy slow queries scenario
cd scenarios
./deploy-scenario.sh deploy slow-queries

# 2. Wait for issue to manifest (2-5 minutes)
./deploy-scenario.sh logs slow-queries

# 3. Test AI skill
claude-code "The database in namespace default seems slow, can you investigate?"

# Expected: AI uses postgresql-performance-check and identifies slow queries

# 4. Cleanup
./deploy-scenario.sh stop slow-queries
```

### Example 2: Test Connection Troubleshooting Skill

```bash
# 1. Deploy pool exhaustion scenario
./deploy-scenario.sh deploy pool-exhaustion

# 2. Wait for pool to fill
sleep 120

# 3. Test AI skill
claude-code "Users are getting connection timeout errors"

# Expected: AI uses postgresql-connection-check and identifies pool exhaustion

# 4. Cleanup
./deploy-scenario.sh stop pool-exhaustion
```

### Example 3: Test Compound Issue Resolution

```bash
# 1. Deploy compound issue (multiple problems)
./deploy-scenario.sh deploy compound-issue

# 2. Wait for ramp-up (5 minutes)
./deploy-scenario.sh logs compound-issue

# 3. Test AI with vague symptom
claude-code "Something is wrong with the database, help me figure out what"

# Expected: AI uses common-troubleshooting for systematic investigation
# Should identify: slow queries, pool exhaustion, and disk fill

# 4. Cleanup
./deploy-scenario.sh stop compound-issue
```

## Runtime Control via API

When `CONTROL_API_ENABLED=true`, you can control scenarios at runtime:

```bash
# Port-forward to the control API
kubectl port-forward -n default svc/trouble-slow-queries 8080:8080 &

# List available scenarios
curl http://localhost:8080/api/troubles/catalog | jq .

# List active scenarios
curl http://localhost:8080/api/troubles/active | jq .

# Enable a new scenario at runtime
curl -X POST http://localhost:8080/api/troubles/enable \
  -H "Content-Type: application/json" \
  -d '{"scenario": "lock-contention", "intensity": "high"}' | jq .

# Disable a scenario
curl -X POST http://localhost:8080/api/troubles/disable \
  -H "Content-Type: application/json" \
  -d '{"scenario": "slow-queries"}' | jq .

# Emergency stop all scenarios
curl -X POST http://localhost:8080/api/emergency-stop | jq .
```

## Configuration

### Environment Variables (Trouble Mode)

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DBAAS_URL` | DBAAS aggregator URL | - | Yes |
| `DBAAS_USER` | DBAAS username | - | Yes |
| `DBAAS_PASSWORD` | DBAAS password | - | Yes |
| `APP_NAMESPACE` | Kubernetes namespace | - | Yes |
| `MODE` | Application mode | workload | No |
| `TROUBLE_SCENARIOS` | Comma-separated scenario list | - | Yes (trouble mode) |
| `TROUBLE_INTENSITY` | Intensity level | medium | No |
| `TROUBLE_DURATION` | Duration in seconds (0=infinite) | 0 | No |
| `TROUBLE_RAMP_UP` | Ramp-up time in seconds | 0 | No |
| `CLEANUP_ON_EXIT` | Clean up on shutdown | true | No |
| `CONTROL_API_ENABLED` | Enable HTTP control API | false | No |

### Intensity Levels

Each scenario supports four intensity levels:

- **low**: Minimal impact, suitable for CI testing
- **medium**: Moderate impact, good for demos
- **high**: Significant impact, tests AI under pressure
- **extreme**: Maximum impact, stress testing

## Helper Scripts

### scenarios/deploy-scenario.sh

Comprehensive scenario management:

```bash
# List available scenarios
./deploy-scenario.sh list

# Deploy a scenario
./deploy-scenario.sh deploy slow-queries

# Check status
./deploy-scenario.sh status slow-queries

# View logs
./deploy-scenario.sh logs slow-queries

# Get API endpoint info
./deploy-scenario.sh api slow-queries

# Stop a scenario
./deploy-scenario.sh stop slow-queries

# Stop all scenarios
./deploy-scenario.sh stop-all

# Full test workflow (deploy + instructions)
./deploy-scenario.sh test slow-queries
```

## Architecture

```
┌─────────────────────────────────────────┐
│  Application Container                   │
│  ┌────────────┐    ┌─────────────────┐  │
│  │ launcher.sh│───▶│ workload_main.py│  │
│  │            │    │ (workload mode) │  │
│  └────────────┘    └─────────────────┘  │
│       │                                  │
│       └──────────▶┌─────────────────┐   │
│                   │ trouble_main.py │   │
│                   │ (trouble mode)  │   │
│                   └────────┬────────┘   │
│                            │             │
│                   ┌────────▼────────┐   │
│                   │ TroubleManager  │   │
│                   └────────┬────────┘   │
│                            │             │
│              ┌─────────────┼────────┐   │
│              ▼             ▼        ▼   │
│         SlowQueries  PoolExhaust  Disk  │
│         Scenario     Scenario     Fill   │
│                                          │
└──────────────┬───────────────────────────┘
               │ via DBAAS
               ▼
       ┌──────────────────┐
       │ PostgreSQL       │
       │ (PgSkipper)      │
       └──────────────────┘
```

## Development

### Adding New Scenarios

1. Create scenario class in `trouble_generator.py`:

```python
class MyNewScenario(TroubleScenario):
    def __init__(self):
        super().__init__(
            name="my-scenario",
            description="What this scenario does",
            skills=["skill-that-detects-this"]
        )

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        # Implementation
        pass

    def cleanup(self):
        # Cleanup logic
        pass
```

2. Register in `SCENARIO_REGISTRY`:

```python
SCENARIO_REGISTRY = {
    # ...
    "my-scenario": MyNewScenario,
}
```

3. Create deployment YAML in `scenarios/my-scenario.yaml`

4. Test it:

```bash
./scenarios/deploy-scenario.sh deploy my-scenario
```

### Testing Locally

Run in Docker without Kubernetes:

```bash
# Build image
docker build -t my-business-app:test .

# Run in trouble mode
docker run --rm \
  -e MODE=trouble \
  -e DBAAS_URL=http://dbaas:8080 \
  -e DBAAS_USER=dba_client \
  -e DBAAS_PASSWORD=password \
  -e APP_NAMESPACE=test \
  -e TROUBLE_SCENARIOS=slow-queries \
  -e TROUBLE_INTENSITY=low \
  -e TROUBLE_DURATION=300 \
  my-business-app:test
```

## Troubleshooting

### Scenario Not Starting

Check logs:
```bash
kubectl logs -l app=trouble-generator -n <namespace>
```

Common issues:
- DBAAS credentials incorrect
- Database provisioning failed
- Insufficient resources (CPU/memory)
- Network connectivity to DBAAS

### Scenario Not Creating Issues

- Wait longer (some scenarios need 5+ minutes to manifest)
- Check intensity level (try "high" or "extreme")
- Verify database has enough data (initial schema may be too small)
- Check pod resources (scenarios may be throttled)

### Control API Not Working

- Verify `CONTROL_API_ENABLED=true`
- Check Flask is installed (`pip install flask`)
- Port-forward to the correct service
- Check pod logs for API errors

## Demo Workflows

### Demo 1: Performance Investigation (5 minutes)

**Setup:**
```bash
./scenarios/deploy-scenario.sh test slow-queries
```

**Demo Script:**
1. "Let me show you how our AI agent troubleshoots database performance issues"
2. Wait 3 minutes for slow queries to appear
3. "A user reports the application is slow"
4. Run: `claude-code "The database seems slow, can you investigate?"`
5. AI should:
   - Use postgresql-performance-check skill
   - Identify slow cross-join queries
   - Show pg_stat_activity evidence
   - Suggest remediation (add indexes, optimize queries)

**Cleanup:**
```bash
./scenarios/deploy-scenario.sh stop slow-queries
```

### Demo 2: Mystery Issue Resolution (15 minutes)

**Setup:**
```bash
./scenarios/deploy-scenario.sh deploy compound-issue
```

**Demo Script:**
1. "This demonstrates systematic troubleshooting of complex issues"
2. Wait 5 minutes for all issues to ramp up
3. "Multiple users report various problems, unclear what's wrong"
4. Run: `claude-code "Something is wrong with our database, help me figure out what"`
5. AI should:
   - Use common-troubleshooting skill for structured investigation
   - Check health, performance, connections, storage systematically
   - Identify all three issues: slow queries, pool exhaustion, disk fill
   - Prioritize by severity
   - Suggest remediation for each

**Cleanup:**
```bash
./scenarios/deploy-scenario.sh stop compound-issue
```

## See Also

- [TROUBLE_GENERATOR.md](TROUBLE_GENERATOR.md) - Detailed architecture and design
- [../skills/README.md](../skills/README.md) - AI troubleshooting skills
- [../CLAUDE.md](../CLAUDE.md) - Project instructions for AI agent

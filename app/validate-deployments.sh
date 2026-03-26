#!/bin/bash
# Automated scenario validation script
# Tests each scenario to ensure it manifests correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"
NAMESPACE="${NAMESPACE:-inventory-validation}"
LOG_DIR="${LOG_DIR:-/tmp/inventory-validation-logs}"
RESULTS_FILE="$LOG_DIR/test-results.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

mkdir -p "$LOG_DIR"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

usage() {
    cat <<EOF
Usage: $0 [command] [options]

Commands:
  validate-all          Run validation for all scenarios
  validate <scenario>   Run validation for specific scenario
  report               Generate test report
  cleanup              Clean up test namespace

Options:
  --namespace <ns>     Kubernetes namespace (default: inventory-validation)
  --wait-time <sec>    Time to wait for manifestation (default: 300)
  --quick              Use shorter wait times for quick validation

Examples:
  # Validate all scenarios
  $0 validate-all

  # Quick validation (shorter wait times)
  $0 validate-all --quick

  # Validate single scenario
  $0 validate report-generation

  # Generate report
  $0 report

  # Cleanup
  $0 cleanup
EOF
}

# Test configuration
declare -A SCENARIO_CONFIG=(
    [report-generation]="300:report-generation:report.*generation|aggregat"
    [parallel-import]="180:parallel-import:parallel.*import|bulk.*insert"
    [month-end-processing]="600:month-end-processing:month.*end|data-migration"
)

parse_config() {
    local scenario=$1
    local config="${SCENARIO_CONFIG[$scenario]}"

    if [ -z "$config" ]; then
        echo "0:unknown:unknown"
        return
    fi

    echo "$config"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    # Check namespace
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "Namespace $NAMESPACE does not exist. Creating..."
        kubectl create namespace "$NAMESPACE"
    fi

    # Check DBAAS credentials
    if [ -z "$DBAAS_URL" ] || [ -z "$DBAAS_USER" ] || [ -z "$DBAAS_PASSWORD" ]; then
        log_warn "DBAAS credentials not set. Scenarios may fail to provision database."
        log_warn "Set DBAAS_URL, DBAAS_USER, DBAAS_PASSWORD environment variables."
    fi

    log_info "Prerequisites OK"
}

deploy_scenario() {
    local scenario=$1
    local wait_time=${2:-300}

    log_info "Deploying scenario: $scenario"

    cd "$SCENARIOS_DIR"
    NAMESPACE="$NAMESPACE" ./manage-deployment.sh deploy "$scenario" >> "$LOG_DIR/${scenario}-deploy.log" 2>&1

    if [ $? -ne 0 ]; then
        log_error "Failed to deploy $scenario"
        return 1
    fi

    log_info "Waiting for pod to be ready..."
    if ! kubectl wait --for=condition=ready pod -l "scenario=${scenario}" -n "$NAMESPACE" --timeout=180s; then
        log_error "Pod did not become ready"
        kubectl get pods -l "scenario=${scenario}" -n "$NAMESPACE"
        return 1
    fi

    log_info "Pod ready. Waiting ${wait_time}s for issue to manifest..."
    sleep "$wait_time"

    return 0
}

check_manifestation() {
    local scenario=$1
    local pod_name=$2

    log_info "Checking if issue manifested for: $scenario"

    # Get pod logs
    local logs=$(kubectl logs -n "$NAMESPACE" "$pod_name" --tail=100)

    # Parse expected indicators from config
    local config=$(parse_config "$scenario")
    IFS=':' read -r wait_time expected_skill indicators <<< "$config"

    # Check for scenario activity in logs
    if echo "$logs" | grep -qiE "scenario.*$scenario|job.*$scenario|batch.*$scenario"; then
        log_info "✓ Scenario $scenario is active in logs"
    else
        log_warn "✗ Scenario $scenario not found in logs"
        return 1
    fi

    # Check for expected operations
    local found=false
    IFS='|' read -ra PATTERNS <<< "$indicators"
    for pattern in "${PATTERNS[@]}"; do
        if echo "$logs" | grep -qiE "$pattern"; then
            log_info "✓ Found expected pattern: $pattern"
            found=true
            break
        fi
    done

    if [ "$found" = false ]; then
        log_warn "✗ Expected indicators not found in logs"
        log_warn "  Looked for: $indicators"
        return 1
    fi

    return 0
}

validate_scenario() {
    local scenario=$1
    local wait_time=${2:-300}
    local result_file="$LOG_DIR/${scenario}-result.txt"

    log_info "=========================================="
    log_info "Validating scenario: $scenario"
    log_info "=========================================="

    # Deploy
    if ! deploy_scenario "$scenario" "$wait_time"; then
        echo "FAIL:$scenario:deployment_failed" >> "$RESULTS_FILE"
        return 1
    fi

    # Get pod name
    local pod_name=$(kubectl get pods -l "scenario=${scenario}" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$pod_name" ]; then
        log_error "Could not find pod for scenario: $scenario"
        echo "FAIL:$scenario:pod_not_found" >> "$RESULTS_FILE"
        return 1
    fi

    # Check manifestation
    if check_manifestation "$scenario" "$pod_name"; then
        log_info "✓ Scenario $scenario: PASS"
        echo "PASS:$scenario:issue_manifested" >> "$RESULTS_FILE"

        # Save logs for reference
        kubectl logs -n "$NAMESPACE" "$pod_name" > "$LOG_DIR/${scenario}-success.log"

        result=0
    else
        log_error "✗ Scenario $scenario: FAIL (issue did not manifest)"
        echo "FAIL:$scenario:manifestation_failed" >> "$RESULTS_FILE"

        # Save logs for debugging
        kubectl logs -n "$NAMESPACE" "$pod_name" > "$LOG_DIR/${scenario}-failure.log"

        result=1
    fi

    # Cleanup
    log_info "Cleaning up scenario: $scenario"
    cd "$SCENARIOS_DIR"
    NAMESPACE="$NAMESPACE" ./manage-deployment.sh stop "$scenario" >> "$LOG_DIR/${scenario}-cleanup.log" 2>&1

    # Wait a bit before next scenario
    sleep 30

    return $result
}

validate_all() {
    local quick=${1:-false}

    log_info "=========================================="
    log_info "Starting validation of all scenarios"
    log_info "=========================================="

    > "$RESULTS_FILE"  # Clear results file

    local scenarios=(
        "report-generation"
        "parallel-import"
    )

    # Include month-end processing in full mode only (longer duration)
    if [ "$quick" = false ]; then
        scenarios+=("month-end-processing")
    fi

    local total=${#scenarios[@]}
    local passed=0
    local failed=0

    for scenario in "${scenarios[@]}"; do
        # Get wait time from config
        local config=$(parse_config "$scenario")
        IFS=':' read -r wait_time _ _ <<< "$config"

        # Reduce wait time in quick mode
        if [ "$quick" = true ]; then
            wait_time=$((wait_time / 2))
        fi

        if validate_scenario "$scenario" "$wait_time"; then
            ((passed++))
        else
            ((failed++))
        fi

        log_info "Progress: $((passed + failed))/$total (✓ $passed, ✗ $failed)"
        echo ""
    done

    log_info "=========================================="
    log_info "Validation complete"
    log_info "Total: $total | Passed: $passed | Failed: $failed"
    log_info "=========================================="

    if [ $failed -gt 0 ]; then
        log_warn "Some scenarios failed. Check logs in: $LOG_DIR"
        return 1
    fi

    return 0
}

generate_report() {
    log_info "Generating test report..."

    if [ ! -f "$RESULTS_FILE" ]; then
        log_error "No results file found. Run validation first."
        return 1
    fi

    local report_file="$LOG_DIR/test-report.md"

    cat > "$report_file" <<EOF
# Inventory Service Deployment Validation Report

**Date**: $(date)
**Namespace**: $NAMESPACE

## Summary

EOF

    local total=$(wc -l < "$RESULTS_FILE")
    local passed=$(grep -c "^PASS" "$RESULTS_FILE" || true)
    local failed=$(grep -c "^FAIL" "$RESULTS_FILE" || true)

    cat >> "$report_file" <<EOF
- **Total Scenarios**: $total
- **Passed**: $passed
- **Failed**: $failed
- **Success Rate**: $(echo "scale=1; $passed * 100 / $total" | bc)%

## Detailed Results

| Scenario | Status | Notes |
|----------|--------|-------|
EOF

    while IFS=':' read -r status scenario reason; do
        local emoji="✅"
        if [ "$status" = "FAIL" ]; then
            emoji="❌"
        fi
        echo "| $scenario | $emoji $status | $reason |" >> "$report_file"
    done < "$RESULTS_FILE"

    cat >> "$report_file" <<EOF

## Logs

Individual scenario logs available in: \`$LOG_DIR\`

- Deployment logs: \`*-deploy.log\`
- Success logs: \`*-success.log\`
- Failure logs: \`*-failure.log\`
- Cleanup logs: \`*-cleanup.log\`

## Recommendations

EOF

    if [ $failed -gt 0 ]; then
        cat >> "$report_file" <<EOF
### Failed Scenarios

Review the failure logs to diagnose issues:

\`\`\`bash
# View failure logs
ls -la $LOG_DIR/*-failure.log

# Check specific scenario
cat $LOG_DIR/<scenario>-failure.log
\`\`\`

Common failure reasons:
- **deployment_failed**: Check DBAAS connectivity, credentials, resources
- **pod_not_found**: Check Kubernetes cluster state, namespace
- **manifestation_failed**: Increase wait time, check database has data, verify intensity
EOF
    else
        cat >> "$report_file" <<EOF
### All Scenarios Passed ✅

All batch scenarios are deploying correctly and jobs are active as expected.
The system is ready for:
- AI skill testing
- Demo presentations
- Automated validation in CI/CD
EOF
    fi

    log_info "Report generated: $report_file"
    cat "$report_file"

    return 0
}

cleanup_test_namespace() {
    log_info "Cleaning up test namespace: $NAMESPACE"

    cd "$SCENARIOS_DIR"
    NAMESPACE="$NAMESPACE" ./manage-deployment.sh stop-all

    log_info "Waiting for resources to terminate..."
    sleep 10

    log_info "Cleanup complete"
}

# Main execution
case "${1:-}" in
    validate-all)
        check_prerequisites
        shift
        quick=false
        if [ "${1:-}" = "--quick" ]; then
            quick=true
        fi
        validate_all "$quick"
        ;;
    validate)
        if [ -z "${2:-}" ]; then
            log_error "Missing scenario name"
            usage
            exit 1
        fi
        check_prerequisites
        validate_scenario "$2" "${3:-300}"
        ;;
    report)
        generate_report
        ;;
    cleanup)
        cleanup_test_namespace
        ;;
    *)
        usage
        ;;
esac

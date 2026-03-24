#!/bin/bash
# Helper script to deploy trouble scenarios for testing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-default}"

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  list                    List available scenarios
  deploy <scenario>       Deploy a scenario
  status <scenario>       Check scenario deployment status
  logs <scenario>         Show scenario logs
  api <scenario>          Get API endpoint for scenario control
  stop <scenario>         Stop and remove a scenario
  stop-all               Stop all running scenarios
  test <scenario>         Deploy scenario and wait for it to manifest

Available scenarios:
  slow-queries           Slow-running queries (postgresql-performance-check)
  pool-exhaustion        Connection pool saturation (postgresql-connection-check)
  compound-issue         Multiple issues combined (common-troubleshooting)

Environment variables:
  NAMESPACE              Kubernetes namespace (default: default)
  DBAAS_URL             DBAAS aggregator URL
  DBAAS_USER            DBAAS username
  DBAAS_PASSWORD        DBAAS password

Examples:
  # Deploy slow queries scenario
  $0 deploy slow-queries

  # Check status
  $0 status slow-queries

  # View logs
  $0 logs slow-queries

  # Stop scenario
  $0 stop slow-queries

  # Test with AI skill
  $0 test slow-queries
  # Then run: claude-code "Check database performance in namespace $NAMESPACE"
EOF
}

list_scenarios() {
    echo "Available scenarios:"
    ls -1 "$SCRIPT_DIR"/*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | grep -v deploy
}

deploy_scenario() {
    local scenario=$1
    local yaml_file="$SCRIPT_DIR/${scenario}.yaml"

    if [ ! -f "$yaml_file" ]; then
        echo "Error: Scenario file not found: $yaml_file"
        echo "Available scenarios:"
        list_scenarios
        exit 1
    fi

    echo "Deploying scenario: $scenario to namespace: $NAMESPACE"

    # Replace DBAAS credentials if provided
    local temp_yaml=$(mktemp)
    cp "$yaml_file" "$temp_yaml"

    if [ -n "$DBAAS_URL" ]; then
        sed -i "s|http://dbaas-aggregator:8080|${DBAAS_URL}|g" "$temp_yaml"
    fi
    if [ -n "$DBAAS_USER" ]; then
        sed -i "s|dba_client|${DBAAS_USER}|g" "$temp_yaml"
    fi
    if [ -n "$DBAAS_PASSWORD" ]; then
        sed -i "s|your-password-here|${DBAAS_PASSWORD}|g" "$temp_yaml"
    fi

    kubectl apply -f "$temp_yaml" -n "$NAMESPACE"
    rm "$temp_yaml"

    echo ""
    echo "Scenario deployed successfully!"
    echo "Wait 2-5 minutes for the issue to manifest, then test with AI skills."
    echo ""
    echo "Useful commands:"
    echo "  Check status:  $0 status $scenario"
    echo "  View logs:     $0 logs $scenario"
    echo "  Get API:       $0 api $scenario"
    echo "  Stop:          $0 stop $scenario"
}

status_scenario() {
    local scenario=$1
    local deployment_name="trouble-${scenario}"

    echo "=== Deployment Status ==="
    kubectl get deployment "$deployment_name" -n "$NAMESPACE" 2>/dev/null || echo "Deployment not found"

    echo ""
    echo "=== Pod Status ==="
    kubectl get pods -l "scenario=${scenario}" -n "$NAMESPACE"

    echo ""
    echo "=== ConfigMap ==="
    kubectl get configmap "trouble-${scenario}" -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A10 "^data:" || echo "ConfigMap not found"
}

logs_scenario() {
    local scenario=$1
    local pod=$(kubectl get pods -l "scenario=${scenario}" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$pod" ]; then
        echo "Error: No pod found for scenario: $scenario"
        exit 1
    fi

    echo "Following logs for pod: $pod"
    kubectl logs -f "$pod" -n "$NAMESPACE"
}

api_scenario() {
    local scenario=$1
    local service="trouble-${scenario}"

    echo "Control API for scenario: $scenario"
    echo ""
    echo "Port-forward command:"
    echo "  kubectl port-forward -n $NAMESPACE svc/$service 8080:8080"
    echo ""
    echo "API endpoints (after port-forward):"
    echo "  GET  http://localhost:8080/api/troubles/catalog       - List all scenarios"
    echo "  GET  http://localhost:8080/api/troubles/active        - List active scenarios"
    echo "  POST http://localhost:8080/api/troubles/enable        - Enable scenario"
    echo "  POST http://localhost:8080/api/troubles/disable       - Disable scenario"
    echo "  POST http://localhost:8080/api/emergency-stop         - Emergency stop"
    echo ""
    echo "Example:"
    echo '  curl http://localhost:8080/api/troubles/active | jq .'
}

stop_scenario() {
    local scenario=$1
    local yaml_file="$SCRIPT_DIR/${scenario}.yaml"

    if [ ! -f "$yaml_file" ]; then
        echo "Error: Scenario file not found: $yaml_file"
        exit 1
    fi

    echo "Stopping scenario: $scenario"
    kubectl delete -f "$yaml_file" -n "$NAMESPACE"
    echo "Scenario stopped"
}

stop_all() {
    echo "Stopping all trouble scenarios in namespace: $NAMESPACE"
    kubectl delete deployment -l "app=trouble-generator" -n "$NAMESPACE"
    kubectl delete configmap -l "app=trouble-generator" -n "$NAMESPACE"
    kubectl delete service -l "app=trouble-generator" -n "$NAMESPACE"
    echo "All scenarios stopped"
}

test_scenario() {
    local scenario=$1

    echo "=== Test Workflow for $scenario ==="
    echo ""
    echo "1. Deploying scenario..."
    deploy_scenario "$scenario"

    echo ""
    echo "2. Waiting for pod to be ready..."
    kubectl wait --for=condition=ready pod -l "scenario=${scenario}" -n "$NAMESPACE" --timeout=120s

    echo ""
    echo "3. Scenario is running. Wait 2-5 minutes for issue to manifest."
    echo ""
    echo "4. Test with AI troubleshooting:"
    echo "   claude-code \"Check database issues in namespace $NAMESPACE\""
    echo ""
    echo "5. When done testing, stop the scenario:"
    echo "   $0 stop $scenario"
    echo ""
    echo "Monitoring commands:"
    echo "  Logs:   $0 logs $scenario"
    echo "  Status: $0 status $scenario"
}

# Main
case "${1:-}" in
    list)
        list_scenarios
        ;;
    deploy)
        if [ -z "${2:-}" ]; then
            echo "Error: Missing scenario name"
            usage
            exit 1
        fi
        deploy_scenario "$2"
        ;;
    status)
        if [ -z "${2:-}" ]; then
            echo "Error: Missing scenario name"
            usage
            exit 1
        fi
        status_scenario "$2"
        ;;
    logs)
        if [ -z "${2:-}" ]; then
            echo "Error: Missing scenario name"
            usage
            exit 1
        fi
        logs_scenario "$2"
        ;;
    api)
        if [ -z "${2:-}" ]; then
            echo "Error: Missing scenario name"
            usage
            exit 1
        fi
        api_scenario "$2"
        ;;
    stop)
        if [ -z "${2:-}" ]; then
            echo "Error: Missing scenario name"
            usage
            exit 1
        fi
        stop_scenario "$2"
        ;;
    stop-all)
        stop_all
        ;;
    test)
        if [ -z "${2:-}" ]; then
            echo "Error: Missing scenario name"
            usage
            exit 1
        fi
        test_scenario "$2"
        ;;
    *)
        usage
        ;;
esac

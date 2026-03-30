#!/bin/bash
# Helper script to manage inventory-service batch processing deployments

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-${APP_NAMESPACE:-inventory}}"

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

replace_in_file() {
    local pattern=$1
    local replacement=$2
    local file=$3

    sed -i.bak -e "s|${pattern}|$(escape_sed_replacement "$replacement")|g" "$file"
    rm -f "${file}.bak"
}

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  list                    List available scenarios
  deploy <scenario>       Deploy a scenario
  status <scenario>       Check scenario deployment status
  logs <scenario>         Show scenario logs
  api <scenario>          Get management API endpoint for scenario
  stop <scenario>         Stop and remove a scenario
  stop-all               Stop all running scenarios
  run <scenario>          Deploy scenario and wait for it to be ready

Available scenarios:
  report-generation      Single report generation job (high load, 30 min)
  parallel-import        Parallel data import job (high load, 30 min)
  month-end-processing   Combined month-end jobs (medium load, 1 hour)

Environment variables:
  NAMESPACE              Kubernetes namespace (default: inventory)
  APP_NAMESPACE          Fallback namespace alias if NAMESPACE is unset
  DBAAS_URL             DBAAS aggregator URL
  DBAAS_USER            DBAAS username
  DBAAS_PASSWORD        DBAAS password

Examples:
  # Deploy report generation scenario
  $0 deploy report-generation

  # Check status
  $0 status report-generation

  # View logs
  $0 logs report-generation

  # Get management API access
  $0 api report-generation

  # Stop scenario
  $0 stop report-generation

  # Full run with AI skill validation
  $0 run report-generation
  # Then run: claude-code "Check database performance in namespace $NAMESPACE"
EOF
}

list_scenarios() {
    echo "Available scenarios:"
    ls -1 "$SCRIPT_DIR"/*.yaml | xargs -n1 basename | sed 's/\.yaml$//'
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
        replace_in_file "http://dbaas-aggregator:8080" "$DBAAS_URL" "$temp_yaml"
    fi
    if [ -n "$DBAAS_USER" ]; then
        replace_in_file "dba_client" "$DBAAS_USER" "$temp_yaml"
    fi
    if [ -n "$DBAAS_PASSWORD" ]; then
        replace_in_file "your-password-here" "$DBAAS_PASSWORD" "$temp_yaml"
    fi

    kubectl apply -f "$temp_yaml" -n "$NAMESPACE"
    rm "$temp_yaml"

    echo ""
    echo "Scenario deployed successfully!"
    echo "Wait 1-2 minutes for the batch jobs to start, then monitor with AI skills."
    echo ""
    echo "Useful commands:"
    echo "  Check status:  $0 status $scenario"
    echo "  View logs:     $0 logs $scenario"
    echo "  Get API:       $0 api $scenario"
    echo "  Stop:          $0 stop $scenario"
}

status_scenario() {
    local scenario=$1
    local deployment_name="inventory-${scenario//processing/}"
    deployment_name="${deployment_name%-}"

    # Determine the actual resource name from the yaml
    local yaml_file="$SCRIPT_DIR/${scenario}.yaml"
    if [ -f "$yaml_file" ]; then
        local resource_name
        resource_name=$(grep -m1 "^  name: inventory-" "$yaml_file" | awk '{print $2}')
        deployment_name="${resource_name:-inventory-${scenario}}"
    fi

    echo "=== Deployment Status ==="
    kubectl get deployment "$deployment_name" -n "$NAMESPACE" 2>/dev/null || echo "Deployment not found"

    echo ""
    echo "=== Pod Status ==="
    kubectl get pods -l "scenario=${scenario}" -n "$NAMESPACE"

    echo ""
    echo "=== ConfigMap ==="
    kubectl get configmap "$deployment_name" -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A15 "^data:" || echo "ConfigMap not found"
}

logs_scenario() {
    local scenario=$1
    local pod
    pod=$(kubectl get pods -l "scenario=${scenario}" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$pod" ]; then
        echo "Error: No pod found for scenario: $scenario"
        exit 1
    fi

    echo "Following logs for pod: $pod"
    kubectl logs -f "$pod" -n "$NAMESPACE"
}

api_scenario() {
    local scenario=$1
    local yaml_file="$SCRIPT_DIR/${scenario}.yaml"
    local service_name
    service_name=$(grep -m1 "^  name: inventory-" "$yaml_file" 2>/dev/null | awk '{print $2}' | tail -1)
    service_name="${service_name:-inventory-${scenario}}"

    echo "Management API for scenario: $scenario"
    echo ""
    echo "Port-forward command:"
    echo "  kubectl port-forward -n $NAMESPACE svc/$service_name 8080:8080"
    echo ""
    echo "API endpoints (after port-forward):"
    echo "  GET  http://localhost:8080/api/jobs/catalog        - List all available jobs"
    echo "  GET  http://localhost:8080/api/jobs/active         - List active jobs"
    echo "  POST http://localhost:8080/api/jobs/enable         - Enable a job"
    echo "  POST http://localhost:8080/api/jobs/disable        - Disable a job"
    echo "  POST http://localhost:8080/api/emergency-stop      - Emergency stop all jobs"
    echo ""
    echo "Example:"
    echo '  curl http://localhost:8080/api/jobs/active | jq .'
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
    echo "Stopping all inventory-service batch scenarios in namespace: $NAMESPACE"
    kubectl delete deployment -l "app=inventory-service" -n "$NAMESPACE"
    kubectl delete configmap -l "app=inventory-service" -n "$NAMESPACE"
    kubectl delete service -l "app=inventory-service" -n "$NAMESPACE"
    echo "All scenarios stopped"
}

run_scenario() {
    local scenario=$1

    echo "=== Running scenario: $scenario ==="
    echo ""
    echo "1. Deploying scenario..."
    deploy_scenario "$scenario"

    echo ""
    echo "2. Waiting for pod to be ready..."
    kubectl wait --for=condition=ready pod -l "scenario=${scenario}" -n "$NAMESPACE" --timeout=120s

    echo ""
    echo "3. Scenario is running. Batch jobs are now active."
    echo ""
    echo "4. Test with AI skill:"
    echo "   claude-code \"Check database performance in namespace $NAMESPACE\""
    echo ""
    echo "5. When done, stop the scenario:"
    echo "   $0 stop $scenario"
    echo ""
    echo "Monitoring commands:"
    echo "  Logs:   $0 logs $scenario"
    echo "  Status: $0 status $scenario"
    echo "  API:    $0 api $scenario"
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
    run)
        if [ -z "${2:-}" ]; then
            echo "Error: Missing scenario name"
            usage
            exit 1
        fi
        run_scenario "$2"
        ;;
    *)
        usage
        ;;
esac

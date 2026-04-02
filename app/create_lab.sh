#!/bin/bash
# create_lab.sh — Create, update, or destroy the troubleshooting lab.
#
# Usage:
#   ./create_lab.sh [apply|destroy|diff|status] [OPTIONS]   (default command: apply)
#
# The script:
#   1. Clones or updates pgskipper-operator and qubership-dbaas repos
#   2. Checks out their latest git tags
#   3. Detects the default Kubernetes storage class
#   4. Exports environment variables consumed by helmfile.yaml
#   5. Runs helmfile apply / destroy / diff / status
#
# Use --local-pgskipper / --local-dbaas / --local to deploy with locally built images
# (built and pushed via build-dependencies.sh).
#
# Prerequisites: git, helm, helmfile, kubectl, jq

set -euo pipefail

# ── Configurable variables ────────────────────────────────────────────────────

# Repo clone destinations
PGSKIPPER_DIR="${PGSKIPPER_DIR:-/tmp/pgskipper-operator}"
DBAAS_DIR="${DBAAS_DIR:-/tmp/qubership-dbaas}"

# Repo URLs
PGSKIPPER_REPO="${PGSKIPPER_REPO:-git@github.com:Netcracker/pgskipper-operator.git}"
DBAAS_REPO="${DBAAS_REPO:-git@github.com:Netcracker/qubership-dbaas.git}"

# Image settings
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/netcracker/}"
PG_VERSION="${PG_VERSION:-17}"

# Namespaces
PG_NAMESPACE="${PG_NAMESPACE:-postgres}"
DBAAS_NAMESPACE="${DBAAS_NAMESPACE:-dbaas}"
DBAAS_SERVICE_NAME="${DBAAS_SERVICE_NAME:-dbaas-aggregator}"

# Passwords
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-MYrootPWD}"
REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD:-replicatorPWD}"
DBA_PASSWORD="${DBA_PASSWORD:-password}"

# Patroni sizing
PATRONI_REPLICAS="${PATRONI_REPLICAS:-2}"
PATRONI_STORAGE_SIZE="${PATRONI_STORAGE_SIZE:-2Gi}"

# Local build flags (can also be set via env vars)
USE_LOCAL_PGSKIPPER="${USE_LOCAL_PGSKIPPER:-false}"
USE_LOCAL_DBAAS="${USE_LOCAL_DBAAS:-false}"
LOCAL_REGISTRY="${LOCAL_REGISTRY:-}"   # auto-detected if empty
LOCAL_TAG="${LOCAL_TAG:-local}"

# ── Helpers ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

require_cmd() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
}

# Return the latest semver tag in a local repo directory.
latest_tag() {
    local dir="$1"
    git -C "$dir" describe --tags "$(git -C "$dir" rev-list --tags --max-count=1)"
}

# Detect a running local container registry. Checks kind (localhost:5001) then
# rancher-desktop (localhost:5000). Returns the first reachable one, or empty.
detect_local_registry() {
    for candidate in "localhost:5001" "localhost:5000"; do
        if curl -s --connect-timeout 2 "http://${candidate}/v2/" > /dev/null 2>&1; then
            echo "$candidate"
            return
        fi
    done
}

usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  apply    Deploy or update the lab (default)
  destroy  Uninstall all helm releases and delete namespaces
  diff     Show pending changes without applying them
  status   Show current release status

Options:
  --local-pgskipper   Use locally built pgskipper-operator images (see build-dependencies.sh)
  --local-dbaas       Use locally built qubership-dbaas images (see build-dependencies.sh)
  --local             Shorthand for --local-pgskipper --local-dbaas
  --registry <addr>   Local registry address (default: auto-detected, e.g. localhost:5001)
  --local-tag <tag>   Tag used for locally built images (default: local)
  --help, -h          Show this help

Environment variables (all optional — sensible defaults provided):
  PGSKIPPER_DIR, DBAAS_DIR        Paths to cloned repos (default: /tmp/...)
  PGSKIPPER_REPO, DBAAS_REPO      Git URLs (default: github.com/Netcracker/...)
  PGSKIPPER_IMAGE_TAG             Override pgskipper image tag (default: latest git tag)
  DBAAS_IMAGE_TAG                 Override dbaas image tag (default: latest git tag)
  IMAGE_PREFIX                    Container registry prefix (default: ghcr.io/netcracker/)
  PG_VERSION                      PostgreSQL major version (default: 17)
  PG_NAMESPACE                    Postgres namespace (default: postgres)
  DBAAS_NAMESPACE                 DBaaS namespace (default: dbaas)
  DBAAS_SERVICE_NAME              DBaaS service name (default: dbaas-aggregator)
  POSTGRES_PASSWORD               Postgres superuser password (default: MYrootPWD)
  REPLICATOR_PASSWORD             Postgres replication password (default: replicatorPWD)
  DBA_PASSWORD                    DBaaS cluster-dba password (default: password)
  PATRONI_REPLICAS                Number of Patroni replicas (default: 2)
  PATRONI_STORAGE_SIZE            Patroni PV size (default: 2Gi)
  STORAGE_CLASS                   Kubernetes storage class (default: auto-detected)
  USE_LOCAL_PGSKIPPER             true/false — same as --local-pgskipper
  USE_LOCAL_DBAAS                 true/false — same as --local-dbaas
  LOCAL_REGISTRY                  Same as --registry
  LOCAL_TAG                       Same as --local-tag
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

COMMAND="${1:-apply}"
# Shift command if it's a known command word; otherwise default to apply
case "$COMMAND" in
    apply|destroy|diff|status) shift ;;
    --*|-h) COMMAND="apply" ;;  # no command given, only flags
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-pgskipper) USE_LOCAL_PGSKIPPER=true; shift ;;
        --local-dbaas)     USE_LOCAL_DBAAS=true;     shift ;;
        --local)           USE_LOCAL_PGSKIPPER=true; USE_LOCAL_DBAAS=true; shift ;;
        --registry)        LOCAL_REGISTRY="$2";      shift 2 ;;
        --local-tag)       LOCAL_TAG="$2";           shift 2 ;;
        --help|-h)         usage; exit 0 ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check prerequisites
require_cmd git helm helmfile kubectl jq

log_info "========================================"
log_info "Troubleshooting Lab — helmfile $COMMAND"
log_info "========================================"

# ── Step 1: Clone / update repos ─────────────────────────────────────────────

# Clone if absent, or fetch tags if already present
if [ -d "$PGSKIPPER_DIR/.git" ]; then
    log_info "pgskipper-operator repo exists at $PGSKIPPER_DIR — fetching tags"
    git -C "$PGSKIPPER_DIR" fetch --tags --quiet
else
    log_info "Cloning pgskipper-operator -> $PGSKIPPER_DIR"
    git clone "$PGSKIPPER_REPO" "$PGSKIPPER_DIR"
fi

if [ -z "${PGSKIPPER_IMAGE_TAG:-}" ]; then
    PGSKIPPER_IMAGE_TAG="$(latest_tag "$PGSKIPPER_DIR")"
fi
log_info "pgskipper-operator tag: $PGSKIPPER_IMAGE_TAG"
git -C "$PGSKIPPER_DIR" checkout --quiet "$PGSKIPPER_IMAGE_TAG"

if [ -d "$DBAAS_DIR/.git" ]; then
    log_info "qubership-dbaas repo exists at $DBAAS_DIR — fetching tags"
    git -C "$DBAAS_DIR" fetch --tags --quiet
else
    log_info "Cloning qubership-dbaas -> $DBAAS_DIR"
    git clone "$DBAAS_REPO" "$DBAAS_DIR"
fi

if [ -z "${DBAAS_IMAGE_TAG:-}" ]; then
    DBAAS_IMAGE_TAG="$(latest_tag "$DBAAS_DIR")"
fi
log_info "qubership-dbaas tag: $DBAAS_IMAGE_TAG"
git -C "$DBAAS_DIR" checkout --quiet "$DBAAS_IMAGE_TAG"

# ── Step 2: Detect storage class ─────────────────────────────────────────────

if [ -z "${STORAGE_CLASS:-}" ]; then
    STORAGE_CLASS="$(kubectl get storageclass \
        -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
        2>/dev/null || true)"
    if [ -z "$STORAGE_CLASS" ]; then
        log_warn "Could not detect default storage class — STORAGE_CLASS will be empty"
        STORAGE_CLASS=""
    else
        log_info "Storage class: $STORAGE_CLASS"
    fi
fi

# ── Step 3: Resolve local registry (when using local builds) ─────────────────

if [[ "$USE_LOCAL_PGSKIPPER" == "true" || "$USE_LOCAL_DBAAS" == "true" ]]; then
    if [ -z "$LOCAL_REGISTRY" ]; then
        LOCAL_REGISTRY="$(detect_local_registry)"
        if [ -z "$LOCAL_REGISTRY" ]; then
            log_error "No local registry detected. Start kind (localhost:5001) or set LOCAL_REGISTRY."
            log_error "You can start a kind registry with: kind create cluster --config kind-config.yaml"
            exit 1
        fi
        log_info "Local registry detected: $LOCAL_REGISTRY"
    else
        log_info "Local registry: $LOCAL_REGISTRY"
    fi
    log_info "Local tag     : $LOCAL_TAG"
    [[ "$USE_LOCAL_PGSKIPPER" == "true" ]] && log_info "pgskipper images: $LOCAL_REGISTRY/pgskipper-operator:$LOCAL_TAG"
    [[ "$USE_LOCAL_DBAAS"     == "true" ]] && log_info "dbaas images    : $LOCAL_REGISTRY/qubership-dbaas:$LOCAL_TAG"
fi

# ── Step 4: Export variables for helmfile ─────────────────────────────────────

export PGSKIPPER_DIR
export DBAAS_DIR
export IMAGE_PREFIX
export PG_VERSION
export PG_NAMESPACE
export DBAAS_NAMESPACE
export DBAAS_SERVICE_NAME
export POSTGRES_PASSWORD
export REPLICATOR_PASSWORD
export DBA_PASSWORD
export PATRONI_REPLICAS
export PATRONI_STORAGE_SIZE
export STORAGE_CLASS
export PGSKIPPER_IMAGE_TAG
export DBAAS_IMAGE_TAG
export USE_LOCAL_PGSKIPPER
export USE_LOCAL_DBAAS
export LOCAL_REGISTRY
export LOCAL_TAG

log_info "pgskipper image tag : $PGSKIPPER_IMAGE_TAG"
log_info "dbaas image tag     : $DBAAS_IMAGE_TAG"
log_info "storage class       : ${STORAGE_CLASS:-(cluster default)}"
log_info "postgres namespace  : $PG_NAMESPACE"
log_info "dbaas namespace     : $DBAAS_NAMESPACE"

# ── Step 5: Run helmfile ──────────────────────────────────────────────────────

case "$COMMAND" in
    apply)
        log_info "Deploying lab..."
        # helmfile sync runs helm upgrade --install for every release (no helm-diff plugin needed)
        helmfile sync
        log_info "========================================"
        log_info "Lab deployed successfully."
        log_info ""
        log_info "Quick checks:"
        log_info "  kubectl get patronicores    -n $PG_NAMESPACE patroni-core     -o jsonpath='{.status}' | jq ."
        log_info "  kubectl get patroniservices -n $PG_NAMESPACE patroni-services -o jsonpath='{.status}' | jq ."
        log_info "  kubectl get pods -n $PG_NAMESPACE"
        log_info "  kubectl get pods -n $DBAAS_NAMESPACE"
        log_info "  kubectl get pods -n inventory"
        log_info "========================================"
        ;;
    destroy)
        log_warn "This will uninstall all lab releases and delete namespaces: $PG_NAMESPACE, $DBAAS_NAMESPACE, inventory"
        read -r -p "Confirm destroy? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            log_info "Aborted."
            exit 0
        fi
        helmfile destroy
        log_info "Deleting namespaces..."
        kubectl delete namespace "$PG_NAMESPACE"    --ignore-not-found
        kubectl delete namespace "$DBAAS_NAMESPACE" --ignore-not-found
        kubectl delete namespace inventory           --ignore-not-found
        log_info "Lab destroyed."
        ;;
    diff)
        # Requires helm-diff plugin: helm plugin install https://github.com/databus23/helm-diff
        if ! helm plugin list 2>/dev/null | grep -q '^diff'; then
            log_error "helm-diff plugin is not installed."
            log_error "Install it with: helm plugin install https://github.com/databus23/helm-diff"
            exit 1
        fi
        helmfile diff
        ;;
    status)
        helmfile status
        ;;
esac

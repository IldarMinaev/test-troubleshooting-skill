#!/bin/bash
# build-dependencies.sh — Build pgskipper-operator and/or qubership-dbaas images
# from local source and push them to a local container registry.
#
# Usage:
#   ./build-dependencies.sh [OPTIONS]
#
# By default builds both. Use --pgskipper or --dbaas to build only one.
#
# After building, deploy the lab with local images:
#   ./create_lab.sh apply --local-pgskipper   # use locally built pgskipper
#   ./create_lab.sh apply --local-dbaas       # use locally built dbaas
#   ./create_lab.sh apply --local             # use both
#
# Prerequisites: git, docker, make (for pgskipper), mvn (for dbaas)

set -euo pipefail

# ── Configurable variables ────────────────────────────────────────────────────

PGSKIPPER_DIR="${PGSKIPPER_DIR:-/tmp/pgskipper-operator}"
DBAAS_DIR="${DBAAS_DIR:-/tmp/qubership-dbaas}"

LOCAL_REGISTRY="${LOCAL_REGISTRY:-}"   # auto-detected if empty
LOCAL_TAG="${LOCAL_TAG:-local}"

BUILD_PGSKIPPER=false
BUILD_DBAAS=false

# ── Helpers ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

require_cmd() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
}

# Detect a running local container registry (kind or rancher-desktop).
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
Usage: $0 [OPTIONS]

Options:
  --pgskipper         Build pgskipper-operator images only
  --dbaas             Build qubership-dbaas images only
  (no flag)           Build both pgskipper-operator and qubership-dbaas images
  --registry <addr>   Local registry to push to (default: auto-detected)
  --tag <tag>         Image tag for locally built images (default: local)
  --pgskipper-dir <d> Path to pgskipper-operator repo (default: /tmp/pgskipper-operator)
  --dbaas-dir <d>     Path to qubership-dbaas repo (default: /tmp/qubership-dbaas)
  --help, -h          Show this help

Environment variables:
  PGSKIPPER_DIR       Same as --pgskipper-dir
  DBAAS_DIR           Same as --dbaas-dir
  LOCAL_REGISTRY      Same as --registry
  LOCAL_TAG           Same as --tag

Built images (pushed to LOCAL_REGISTRY):
  pgskipper-operator:
    <registry>/pgskipper-operator:<tag>
    <registry>/pgskipper-docker-patroni-<PG_VERSION>:<tag>   (if services/patroni/Dockerfile exists)

  qubership-dbaas:
    <registry>/qubership-dbaas:<tag>
    <registry>/qubership-dbaas-validation-image:<tag>

After building, deploy with:
  ./create_lab.sh apply --local            # both
  ./create_lab.sh apply --local-pgskipper  # pgskipper only
  ./create_lab.sh apply --local-dbaas      # dbaas only
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────

EXPLICIT_TARGET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pgskipper)     BUILD_PGSKIPPER=true; EXPLICIT_TARGET=true; shift ;;
        --dbaas)         BUILD_DBAAS=true;     EXPLICIT_TARGET=true; shift ;;
        --registry)      LOCAL_REGISTRY="$2";  shift 2 ;;
        --tag)           LOCAL_TAG="$2";        shift 2 ;;
        --pgskipper-dir) PGSKIPPER_DIR="$2";   shift 2 ;;
        --dbaas-dir)     DBAAS_DIR="$2";       shift 2 ;;
        --help|-h)       usage; exit 0 ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Default: build both when no explicit target given
if [[ "$EXPLICIT_TARGET" == "false" ]]; then
    BUILD_PGSKIPPER=true
    BUILD_DBAAS=true
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────

require_cmd docker

if [[ "$BUILD_PGSKIPPER" == "true" ]]; then
    require_cmd make
    if [ ! -d "$PGSKIPPER_DIR/.git" ]; then
        log_error "pgskipper-operator repo not found at $PGSKIPPER_DIR"
        log_error "Clone it first: git clone git@github.com:Netcracker/pgskipper-operator.git $PGSKIPPER_DIR"
        exit 1
    fi
fi

if [[ "$BUILD_DBAAS" == "true" ]]; then
    require_cmd mvn
    if [ ! -d "$DBAAS_DIR/.git" ]; then
        log_error "qubership-dbaas repo not found at $DBAAS_DIR"
        log_error "Clone it first: git clone git@github.com:Netcracker/qubership-dbaas.git $DBAAS_DIR"
        exit 1
    fi
fi

# ── Detect local registry ─────────────────────────────────────────────────────

if [ -z "$LOCAL_REGISTRY" ]; then
    LOCAL_REGISTRY="$(detect_local_registry)"
    if [ -z "$LOCAL_REGISTRY" ]; then
        log_error "No local container registry detected (tried localhost:5001, localhost:5000)."
        log_error "Start a local registry or set LOCAL_REGISTRY=<host:port>."
        exit 1
    fi
fi

log_info "========================================"
log_info "Building local images"
log_info "========================================"
log_info "Registry : $LOCAL_REGISTRY"
log_info "Tag      : $LOCAL_TAG"
[[ "$BUILD_PGSKIPPER" == "true" ]] && log_info "Building : pgskipper-operator"
[[ "$BUILD_DBAAS"     == "true" ]] && log_info "Building : qubership-dbaas"
log_info "========================================"

# ── Build pgskipper-operator ──────────────────────────────────────────────────

if [[ "$BUILD_PGSKIPPER" == "true" ]]; then
    log_step "Building pgskipper-operator..."

    OPERATOR_IMAGE="${LOCAL_REGISTRY}/pgskipper-operator:${LOCAL_TAG}"

    # The operator Makefile lives in operator/ and uses DOCKER_NAMES / TAG_ENV
    # to control the image name. We override DOCKER_NAMES to target the local registry.
    (
        cd "$PGSKIPPER_DIR/operator"
        log_info "Running: make DOCKER_NAMES=\"$OPERATOR_IMAGE\" docker-build"
        make DOCKER_NAMES="$OPERATOR_IMAGE" docker-build
        log_info "Pushing $OPERATOR_IMAGE"
        docker push "$OPERATOR_IMAGE"
    )
    log_info "pgskipper-operator image ready: $OPERATOR_IMAGE"

    # Build patroni image if services/patroni/Dockerfile exists
    PATRONI_DOCKERFILE="${PGSKIPPER_DIR}/services/patroni/Dockerfile"
    if [ -f "$PATRONI_DOCKERFILE" ]; then
        PG_VERSION="${PG_VERSION:-17}"
        PATRONI_IMAGE="${LOCAL_REGISTRY}/pgskipper-docker-patroni-${PG_VERSION}:${LOCAL_TAG}"
        log_step "Building patroni image (PG ${PG_VERSION})..."
        docker build \
            -f "$PATRONI_DOCKERFILE" \
            -t "$PATRONI_IMAGE" \
            "$PGSKIPPER_DIR/services/patroni"
        docker push "$PATRONI_IMAGE"
        log_info "Patroni image ready: $PATRONI_IMAGE"
    else
        log_warn "services/patroni/Dockerfile not found — skipping patroni image build."
        log_warn "patroni.dockerImage will use the official image from the release tag."
    fi
fi

# ── Build qubership-dbaas ─────────────────────────────────────────────────────

if [[ "$BUILD_DBAAS" == "true" ]]; then
    log_step "Building qubership-dbaas (Maven)..."

    DBAAS_IMAGE="${LOCAL_REGISTRY}/qubership-dbaas:${LOCAL_TAG}"
    DBAAS_HOOK_IMAGE="${LOCAL_REGISTRY}/qubership-dbaas-validation-image:${LOCAL_TAG}"

    # Maven build: compile and package the dbaas-aggregator module
    (
        cd "$DBAAS_DIR"
        log_info "Running: mvn package -DskipTests -f dbaas/pom.xml"
        mvn package -DskipTests -f dbaas/pom.xml
    )

    # Build main dbaas image (Dockerfile context is dbaas/)
    log_step "Building dbaas Docker image..."
    docker build \
        -f "${DBAAS_DIR}/dbaas/Dockerfile" \
        -t "$DBAAS_IMAGE" \
        "${DBAAS_DIR}/dbaas"
    docker push "$DBAAS_IMAGE"
    log_info "DBaaS image ready: $DBAAS_IMAGE"

    # Build validation / hook image
    if [ -f "${DBAAS_DIR}/validation-image/Dockerfile" ]; then
        log_step "Building dbaas validation image..."
        docker build \
            -f "${DBAAS_DIR}/validation-image/Dockerfile" \
            -t "$DBAAS_HOOK_IMAGE" \
            "${DBAAS_DIR}/validation-image"
        docker push "$DBAAS_HOOK_IMAGE"
        log_info "DBaaS hook image ready: $DBAAS_HOOK_IMAGE"
    else
        log_warn "validation-image/Dockerfile not found — skipping hook image build."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

log_info "========================================"
log_info "Build complete."
log_info ""
log_info "Deploy the lab with local images:"
if [[ "$BUILD_PGSKIPPER" == "true" && "$BUILD_DBAAS" == "true" ]]; then
    log_info "  ./create_lab.sh apply --local --registry ${LOCAL_REGISTRY} --local-tag ${LOCAL_TAG}"
elif [[ "$BUILD_PGSKIPPER" == "true" ]]; then
    log_info "  ./create_lab.sh apply --local-pgskipper --registry ${LOCAL_REGISTRY} --local-tag ${LOCAL_TAG}"
else
    log_info "  ./create_lab.sh apply --local-dbaas --registry ${LOCAL_REGISTRY} --local-tag ${LOCAL_TAG}"
fi
log_info "========================================"

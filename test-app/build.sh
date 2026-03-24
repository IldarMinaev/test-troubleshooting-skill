#!/bin/bash
# Build script for trouble generator / workload generator
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default configuration
IMAGE_NAME="${IMAGE_NAME:-my-business-app}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REGISTRY="${REGISTRY:-}"  # Empty = local only
PUSH="${PUSH:-false}"
PLATFORM="${PLATFORM:-linux/amd64}"  # or linux/amd64,linux/arm64 for multi-arch

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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
Usage: $0 [image:tag] [options]

Arguments:
  image:tag         Image name and tag (default: my-business-app:latest)

Options:
  --push            Push to registry after build
  --registry <reg>  Registry to push to (e.g., docker.io/myuser)
  --platform <plat> Target platform(s) (default: linux/amd64)
  --no-cache        Build without cache
  --help            Show this help

Environment Variables:
  IMAGE_NAME        Image name (default: my-business-app)
  IMAGE_TAG         Image tag (default: latest)
  REGISTRY          Container registry URL
  PUSH              Push to registry (true/false)
  PLATFORM          Build platform(s)

Examples:
  # Build locally
  $0

  # Build with specific tag
  $0 my-business-app:v1.0.0

  # Build and push to Docker Hub
  $0 myuser/trouble-gen:v1.0.0 --push

  # Build for multiple platforms
  $0 --platform linux/amd64,linux/arm64

  # Build with custom registry
  REGISTRY=quay.io/myorg $0 --push
EOF
}

# Parse arguments
NO_CACHE=""
if [ -n "${1:-}" ] && [ "$1" != "--"* ]; then
    # Parse image:tag
    if [[ "$1" == *":"* ]]; then
        IMAGE_NAME="${1%:*}"
        IMAGE_TAG="${1#*:}"
    else
        IMAGE_NAME="$1"
    fi
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --push)
            PUSH=true
            shift
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Construct full image name
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
    FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
fi

log_info "========================================"
log_info "Building Trouble Generator Image"
log_info "========================================"
log_info "Image: $FULL_IMAGE"
log_info "Platform: $PLATFORM"
log_info "Push: $PUSH"
log_info "========================================"

# Check Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker not found. Please install Docker."
    exit 1
fi

# Validate Dockerfile exists
if [ ! -f "Dockerfile" ]; then
    log_error "Dockerfile not found in $SCRIPT_DIR"
    exit 1
fi

# Build image
log_info "Building Docker image..."
if docker build $NO_CACHE \
    --platform "$PLATFORM" \
    -t "$FULL_IMAGE" \
    -t "${IMAGE_NAME}:latest" \
    .; then
    log_info "✓ Build successful: $FULL_IMAGE"
else
    log_error "✗ Build failed"
    exit 1
fi

# Tag with additional tags if version tag
if [ "$IMAGE_TAG" != "latest" ] && [[ "$IMAGE_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # Extract major.minor
    MAJOR_MINOR=$(echo "$IMAGE_TAG" | sed -E 's/^v?([0-9]+\.[0-9]+)\.[0-9]+$/\1/')
    log_info "Tagging additional versions: $MAJOR_MINOR"
    docker tag "$FULL_IMAGE" "${IMAGE_NAME}:${MAJOR_MINOR}"
    if [ -n "$REGISTRY" ]; then
        docker tag "$FULL_IMAGE" "${REGISTRY}/${IMAGE_NAME}:${MAJOR_MINOR}"
    fi
fi

# Validate image
log_info "Validating image..."
if docker run --rm --entrypoint python "$FULL_IMAGE" --version; then
    log_info "✓ Image validated"
else
    log_warn "Image validation failed (non-critical)"
fi

# Show image info
log_info "Image details:"
docker images "$FULL_IMAGE" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# Push if requested
if [ "$PUSH" = true ]; then
    if [ -z "$REGISTRY" ]; then
        log_error "Cannot push: REGISTRY not specified"
        log_info "Set REGISTRY environment variable or use --registry flag"
        exit 1
    fi

    log_info "Pushing to registry: $REGISTRY"

    # Push main tag
    if docker push "$FULL_IMAGE"; then
        log_info "✓ Pushed: $FULL_IMAGE"
    else
        log_error "✗ Push failed"
        exit 1
    fi

    # Push additional tags if they exist
    if [ "$IMAGE_TAG" != "latest" ] && [[ "$IMAGE_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        MAJOR_MINOR=$(echo "$IMAGE_TAG" | sed -E 's/^v?([0-9]+\.[0-9]+)\.[0-9]+$/\1/')
        docker push "${REGISTRY}/${IMAGE_NAME}:${MAJOR_MINOR}" || true
    fi

    # Push latest tag
    if [ "$IMAGE_TAG" == "latest" ] || [ "$IMAGE_TAG" != "latest" ]; then
        log_info "Pushing latest tag..."
        docker push "${REGISTRY}/${IMAGE_NAME}:latest" || log_warn "Latest tag push failed (non-critical)"
    fi

    log_info "✓ Push complete"
fi

log_info "========================================"
log_info "Build Complete!"
log_info "========================================"
log_info "Image: $FULL_IMAGE"
log_info ""
log_info "Next steps:"
if [ "$PUSH" = true ]; then
    log_info "  Deploy with: kubectl apply -f scenarios/<scenario>.yaml"
    log_info "  Or via Helm: helm install trouble-gen ./helm/test-app -f values-trouble-demo.yaml"
else
    log_info "  Test locally: docker run --rm -e MODE=trouble -e TROUBLE_SCENARIOS=slow-queries ... $FULL_IMAGE"
    log_info "  Push to registry: $0 $FULL_IMAGE --push --registry <registry>"
fi
log_info "========================================"

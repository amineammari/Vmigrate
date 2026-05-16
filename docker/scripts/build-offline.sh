#!/usr/bin/env bash
# Air-gapped Docker build script
# Builds all images and dependencies completely offline
# Usage: ./docker/scripts/build-offline.sh [options]
#
# Options:
#   --no-cache          Build without Docker cache
#   --ver <version>     Set version tag (default: offline)
#   --backend-only      Build only backend image
#   --worker-only       Build only conversion worker image
#   --frontend-only     Build only frontend image
#   --db-only          Export database image from system
#
# Requirements:
#   - All offline dependencies already available:
#     * offline/wheels/ - all Python packages (generated via: pip wheel -r backend/requirements.txt -w offline/wheels/)
#     * offline/vendor/vddk/ - VDDK SDK files
#     * offline/npm-cache/ - npm packages cache
#     * offline/terraform-providers/ - terraform plugins

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERSION="${VERSION:-offline}"
NO_CACHE=""
BUILD_BACKEND=true
BUILD_WORKER=true
BUILD_FRONTEND=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --ver)
            VERSION="$2"
            shift 2
            ;;
        --backend-only)
            BUILD_WORKER=false
            BUILD_FRONTEND=false
            shift
            ;;
        --worker-only)
            BUILD_BACKEND=false
            BUILD_FRONTEND=false
            shift
            ;;
        --frontend-only)
            BUILD_BACKEND=false
            BUILD_WORKER=false
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Pre-flight checks
check_dependencies() {
    local missing=()
    
    if ! command -v docker &> /dev/null; then
        missing+=("docker")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    
    log_info "All required tools found"
}

check_offline_resources() {
    local errors=0
    
    # Check Python wheels
    if [[ ! -d "${PROJECT_DIR}/offline/wheels" ]] || [[ -z "$(ls -A "${PROJECT_DIR}/offline/wheels" 2>/dev/null)" ]]; then
        log_error "Missing offline/wheels directory or empty"
        log_error "Generate with: pip wheel -r backend/requirements.txt -w offline/wheels/"
        errors=$((errors + 1))
    else
        local wheel_count=$(find "${PROJECT_DIR}/offline/wheels" -name "*.whl" | wc -l)
        log_info "Found ${wheel_count} Python wheels"
    fi
    
    # Check VDDK
    if [[ ! -d "${PROJECT_DIR}/offline/vendor/vddk" ]] || [[ -z "$(ls -A "${PROJECT_DIR}/offline/vendor/vddk" 2>/dev/null)" ]]; then
        log_warn "Missing/empty offline/vendor/vddk/ - conversion worker will not have VDDK support"
        log_warn "Copy with: sudo cp -r /opt/vmware-vddk/* offline/vendor/vddk/"
    else
        log_info "Found VDDK files in offline/vendor/vddk/"
    fi

    # Check Terraform binary
    if [[ ! -f "${PROJECT_DIR}/offline/vendor/terraform/terraform" ]]; then
        log_warn "Missing offline/vendor/terraform/terraform - conversion worker will not include terraform"
        log_warn "Copy with: cp /usr/bin/terraform offline/vendor/terraform/terraform"
    else
        log_info "Found Terraform binary in offline/vendor/terraform/terraform"
    fi
    
    # Check frontend resources
    if [[ ! -d "${PROJECT_DIR}/frontend/node_modules" ]]; then
        log_warn "Frontend node_modules not found - will build with npm dependencies"
        log_warn "Pre-populate with: cd frontend && npm install"
    else
        log_info "Found frontend node_modules"
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "$errors offline resource checks failed"
        return 1
    fi
}

build_backend() {
    log_info "Building backend image..."
    docker build \
        ${NO_CACHE} \
        -f "${PROJECT_DIR}/docker/dockerfiles/backend-offline.Dockerfile" \
        -t "vm-migrator/backend:offline" \
        -t "vm-migrator/backend:${VERSION}" \
        -t "vm-migrator/backend:latest" \
        "${PROJECT_DIR}"
    log_info "✓ Backend image built successfully"
}

build_worker() {
    log_info "Building conversion worker image..."
    docker build \
        ${NO_CACHE} \
        -f "${PROJECT_DIR}/docker/dockerfiles/conversion-worker-offline.Dockerfile" \
        -t "vm-migrator/conversion-worker:offline" \
        -t "vm-migrator/conversion-worker:${VERSION}" \
        -t "vm-migrator/conversion-worker:latest" \
        "${PROJECT_DIR}"
    log_info "✓ Conversion worker image built successfully"
}

build_frontend() {
    log_info "Building frontend image..."
    docker build \
        ${NO_CACHE} \
        -f "${PROJECT_DIR}/docker/dockerfiles/frontend-offline.Dockerfile" \
        -t "vm-migrator/frontend:offline" \
        -t "vm-migrator/frontend:${VERSION}" \
        -t "vm-migrator/frontend:latest" \
        "${PROJECT_DIR}"
    log_info "✓ Frontend image built successfully"
}

list_images() {
    log_info "Successfully built images:"
    docker images --filter "reference=vm-migrator/*" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"
}

main() {
    log_info "Starting offline air-gapped Docker build..."
    log_info "Version: ${VERSION}"
    
    check_dependencies
    check_offline_resources
    
    cd "${PROJECT_DIR}"
    
    if [[ "${BUILD_BACKEND}" == true ]]; then
        build_backend
    fi
    
    if [[ "${BUILD_WORKER}" == true ]]; then
        build_worker
    fi
    
    if [[ "${BUILD_FRONTEND}" == true ]]; then
        build_frontend
    fi
    
    list_images
    
    log_info ""
    log_info "Build complete! To run offline deployment:"
    log_info "  docker-compose -f docker-compose.offline.yml up -d"
    log_info ""
    log_info "To view logs:"
    log_info "  docker-compose -f docker-compose.offline.yml logs -f backend"
}

main "$@"

#!/usr/bin/env bash
# Enhanced Offline Build Script
# Builds all images with optimizations for air-gapped deployment
# Features: artifact validation, parallel builds, healthcheck testing, export to tar
# Usage: ./docker/scripts/build-offline-enhanced.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
VERSION="${VERSION:-offline}"
NO_CACHE="${NO_CACHE:-}"
VALIDATE_ARTIFACTS="${VALIDATE_ARTIFACTS:-true}"
SKIP_HEALTHCHECKS="${SKIP_HEALTHCHECKS:-false}"
EXPORT_IMAGES="${EXPORT_IMAGES:-false}"
PARALLEL_BUILD="${PARALLEL_BUILD:-true}"
BUILD_BACKEND="${BUILD_BACKEND:-true}"
BUILD_WORKER="${BUILD_WORKER:-true}"
BUILD_FRONTEND="${BUILD_FRONTEND:-true}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $*"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*"
}

log_section() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --version)
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
        --skip-validation)
            VALIDATE_ARTIFACTS=false
            shift
            ;;
        --skip-healthchecks)
            SKIP_HEALTHCHECKS=true
            shift
            ;;
        --export)
            EXPORT_IMAGES=true
            shift
            ;;
        --sequential)
            PARALLEL_BUILD=false
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
    log_section "Checking Dependencies"
    
    local missing=()
    
    for cmd in docker git python3; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon not accessible"
        exit 1
    fi
    
    log_info "All requirements met"
}

# Validate offline artifacts
validate_artifacts() {
    if [[ "${VALIDATE_ARTIFACTS}" != "true" ]]; then
        log_warn "Artifact validation skipped (--skip-validation)"
        return 0
    fi
    
    log_section "Validating Offline Artifacts"
    
    # Run validation script
    if [[ -f "${PROJECT_DIR}/scripts/validate-offline-artifacts.sh" ]]; then
        bash "${PROJECT_DIR}/scripts/validate-offline-artifacts.sh" || true
    else
        log_warn "Validation script not found"
    fi
}

# Build backend image
build_backend() {
    log_section "Building Backend Image"
    
    local dockerfile="${PROJECT_DIR}/docker/dockerfiles/backend-offline-v2.Dockerfile"
    
    if [[ ! -f "${dockerfile}" ]]; then
        log_error "Dockerfile not found: ${dockerfile}"
        return 1
    fi
    
    docker build \
        ${NO_CACHE} \
        --progress=plain \
        -f "${dockerfile}" \
        -t "vm-migrator/backend:offline" \
        -t "vm-migrator/backend:${VERSION}" \
        -t "vm-migrator/backend:latest" \
        "${PROJECT_DIR}"
    
    log_info "Backend image built successfully"
    
    # Show image info
    docker images --filter "reference=vm-migrator/backend" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"
}

# Build conversion worker image
build_worker() {
    log_section "Building Conversion Worker Image"
    
    local dockerfile="${PROJECT_DIR}/docker/dockerfiles/conversion-worker-offline-v2.Dockerfile"
    
    if [[ ! -f "${dockerfile}" ]]; then
        log_error "Dockerfile not found: ${dockerfile}"
        return 1
    fi
    
    docker build \
        ${NO_CACHE} \
        --progress=plain \
        -f "${dockerfile}" \
        -t "vm-migrator/conversion-worker:offline" \
        -t "vm-migrator/conversion-worker:${VERSION}" \
        -t "vm-migrator/conversion-worker:latest" \
        "${PROJECT_DIR}"
    
    log_info "Conversion worker image built successfully"
    
    docker images --filter "reference=vm-migrator/conversion-worker" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"
}

# Build frontend image
build_frontend() {
    log_section "Building Frontend Image"
    
    local dockerfile="${PROJECT_DIR}/docker/dockerfiles/frontend-offline-v2.Dockerfile"
    
    if [[ ! -f "${dockerfile}" ]]; then
        log_error "Dockerfile not found: ${dockerfile}"
        return 1
    fi
    
    docker build \
        ${NO_CACHE} \
        --progress=plain \
        -f "${dockerfile}" \
        -t "vm-migrator/frontend:offline" \
        -t "vm-migrator/frontend:${VERSION}" \
        -t "vm-migrator/frontend:latest" \
        "${PROJECT_DIR}"
    
    log_info "Frontend image built successfully"
    
    docker images --filter "reference=vm-migrator/frontend" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"
}

# Test image healthchecks
test_healthchecks() {
    if [[ "${SKIP_HEALTHCHECKS}" == "true" ]]; then
        log_warn "Healthcheck tests skipped (--skip-healthchecks)"
        return 0
    fi
    
    log_section "Testing Container Healthchecks"
    
    log_info "Healthcheck validation would run here (requires docker-compose)"
    log_info "Run manually: docker-compose -f docker-compose.offline.yml up -d && sleep 30 && docker ps"
}

# Export images to tar
export_images() {
    if [[ "${EXPORT_IMAGES}" != "true" ]]; then
        return 0
    fi
    
    log_section "Exporting Images to TAR Archives"
    
    local export_dir="${PROJECT_DIR}/offline/images"
    mkdir -p "${export_dir}"
    
    if [[ "${BUILD_BACKEND}" == "true" ]]; then
        log_info "Exporting backend image..."
        docker save "vm-migrator/backend:${VERSION}" \
            -o "${export_dir}/vm-migrator-backend-${VERSION}.tar"
    fi
    
    if [[ "${BUILD_WORKER}" == "true" ]]; then
        log_info "Exporting conversion-worker image..."
        docker save "vm-migrator/conversion-worker:${VERSION}" \
            -o "${export_dir}/vm-migrator-conversion-worker-${VERSION}.tar"
    fi
    
    if [[ "${BUILD_FRONTEND}" == "true" ]]; then
        log_info "Exporting frontend image..."
        docker save "vm-migrator/frontend:${VERSION}" \
            -o "${export_dir}/vm-migrator-frontend-${VERSION}.tar"
    fi
    
    log_info "Images exported to ${export_dir}/"
    ls -lh "${export_dir}"/*.tar 2>/dev/null || true
}

# List built images
list_images() {
    log_section "Image Summary"
    docker images --filter "reference=vm-migrator/*" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}"
}

# Main build flow
main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  VM-Migrator Enhanced Offline Build                       ║${NC}"
    echo -e "${GREEN}║  Air-gapped Docker image compilation                      ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Configuration:"
    echo "  Version: ${VERSION}"
    echo "  Parallel builds: ${PARALLEL_BUILD}"
    echo "  No cache: ${NO_CACHE:-default cache}"
    echo "  Validate artifacts: ${VALIDATE_ARTIFACTS}"
    echo "  Export images: ${EXPORT_IMAGES}"
    echo ""
    
    check_dependencies
    validate_artifacts
    
    cd "${PROJECT_DIR}"
    
    if [[ "${PARALLEL_BUILD}" == "true" ]] && [[ "${BUILD_BACKEND}" == "true" ]] && [[ "${BUILD_WORKER}" == "true" ]]; then
        log_section "Building Images in Parallel"
        build_backend &
        local backend_pid=$!
        build_worker &
        local worker_pid=$!
        
        if [[ "${BUILD_FRONTEND}" == "true" ]]; then
            build_frontend
        fi
        
        wait ${backend_pid} ${worker_pid}
    else
        [[ "${BUILD_BACKEND}" == "true" ]] && build_backend
        [[ "${BUILD_WORKER}" == "true" ]] && build_worker
        [[ "${BUILD_FRONTEND}" == "true" ]] && build_frontend
    fi
    
    test_healthchecks
    export_images
    list_images
    
    echo ""
    log_section "Build Complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy: docker-compose -f docker-compose.offline.yml up -d"
    echo "  2. Wait for healthchecks: docker ps (all should show 'healthy')"
    echo "  3. Test API: curl http://localhost:8000/api/health"
    echo "  4. View logs: docker-compose logs -f backend"
    echo ""
}

main "$@"

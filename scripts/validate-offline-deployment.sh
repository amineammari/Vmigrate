#!/usr/bin/env bash
# Offline Deployment Validator
# Run on target (offline) system after deploying with docker-compose
# Validates all services are running, healthy, and functional
# Usage: ./scripts/validate-offline-deployment.sh [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERBOSE="${1:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

tests_passed=0
tests_failed=0

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    tests_passed=$((tests_passed + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    tests_failed=$((tests_failed + 1))
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_section() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

# Validate Docker installed and running
test_docker_available() {
    log_section "Test 1: Docker Daemon"
    
    if ! command -v docker &>/dev/null; then
        log_fail "Docker is not installed"
        return 1
    fi
    
    if ! docker ps >/dev/null 2>&1; then
        log_fail "Docker daemon is not running"
        return 1
    fi
    
    log_pass "Docker daemon is running"
}

# Check all required containers are present
test_containers_exist() {
    log_section "Test 2: Container Existence"
    
    local required_containers=(
        "vmigrate-db-offline"
        "vmigrate-redis-offline"
        "vmigrate-backend-offline"
        "vmigrate-frontend-offline"
        "vmigrate-celery-beat-offline"
        "vmigrate-conversion-worker-offline"
    )
    
    for container in "${required_containers[@]}"; do
        if docker ps -a --filter "name=${container}" --format "{{.Names}}" | grep -q "^${container}$"; then
            log_pass "Container exists: ${container}"
        else
            log_fail "Container not found: ${container}"
        fi
    done
}

# Verify containers are running
test_containers_running() {
    log_section "Test 3: Container Status (Running)"
    
    local running_containers=$(docker ps --filter "status=running" --format "{{.Names}}")
    
    for container in vmigrate-{db,redis,backend,frontend,celery-beat,conversion-worker}-offline; do
        if echo "${running_containers}" | grep -q "^${container}$"; then
            log_pass "Container running: ${container}"
        else
            log_fail "Container not running: ${container}"
        fi
    done
}

# Verify container healthchecks
test_container_health() {
    log_section "Test 4: Container Health Checks"
    
    local containers_to_check=(
        "vmigrate-db-offline"
        "vmigrate-redis-offline"
        "vmigrate-backend-offline"
        "vmigrate-frontend-offline"
        "vmigrate-celery-beat-offline"
        "vmigrate-conversion-worker-offline"
    )
    
    for container in "${containers_to_check[@]}"; do
        local health=$(docker inspect "${container}" --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
        
        case "${health}" in
            "healthy")
                log_pass "Container healthy: ${container}"
                ;;
            "starting")
                log_info "Container starting (wait 30s): ${container}"
                ;;
            "unhealthy")
                log_fail "Container unhealthy: ${container}"
                if [[ "${VERBOSE}" == "--verbose" ]]; then
                    docker logs --tail 50 "${container}" 2>/dev/null || true
                fi
                ;;
            "none")
                log_info "No healthcheck configured: ${container}"
                ;;
            *)
                log_fail "Unknown health status for ${container}: ${health}"
                ;;
        esac
    done
}

# Test API endpoints
test_api_endpoints() {
    log_section "Test 5: API Endpoints"
    
    # Test backend health endpoint
    if curl -s -f http://localhost:8000/api/health >/dev/null 2>&1; then
        log_pass "Backend health endpoint responds"
    else
        log_fail "Backend health endpoint unreachable"
    fi
    
    # Test frontend HTTP
    if curl -s -f http://localhost:3000/ >/dev/null 2>&1; then
        log_pass "Frontend serves HTTP 200"
    else
        log_fail "Frontend not responding"
    fi
    
    # Test database connectivity
    if timeout 5 docker exec vmigrate-db-offline \
        mariadb-admin ping -h 127.0.0.1 -uroot -p"${DB_ROOT_PASSWORD:-rootpassword}" --silent 2>/dev/null; then
        log_pass "Database responds to ping"
    else
        log_fail "Database not responding"
    fi
    
    # Test Redis connectivity
    if timeout 5 docker exec vmigrate-redis-offline redis-cli ping 2>/dev/null | grep -q "PONG"; then
        log_pass "Redis responds to ping"
    else
        log_fail "Redis not responding"
    fi
}

# Test network isolation (no external calls)
test_network_isolation() {
    log_section "Test 6: Network Isolation (No External Calls)"
    
    log_info "Checking if containers have internet access..."
    
    # This is informational only (may not detect all external calls)
    local has_external_route=false
    
    if docker exec vmigrate-backend-offline ip route show | grep -qE "default via|0.0.0.0"; then
        log_info "Container has default route (not purely air-gapped)"
    else
        log_pass "No default route detected (air-gapped)"
    fi
    
    # Try to reach external service (should fail in truly air-gapped)
    if timeout 3 docker exec vmigrate-backend-offline \
        wget -q -O /dev/null http://8.8.8.8 2>/dev/null; then
        log_fail "Container can reach external services (not fully air-gapped)"
    else
        log_pass "External DNS/HTTP unreachable (air-gapped confirmed)"
    fi
}

# Check disk space
test_disk_space() {
    log_section "Test 7: Disk Space"
    
    local required_gb=10
    local available_gb=$(df -BG ${PROJECT_DIR} | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if ((available_gb >= required_gb)); then
        log_pass "Sufficient disk space: ${available_gb}GB available"
    else
        log_fail "Low disk space: ${available_gb}GB available (need ${required_gb}GB)"
    fi
}

# Check logs for errors
test_container_logs() {
    log_section "Test 8: Container Logs (No Critical Errors)"
    
    local containers=("backend" "frontend" "celery-beat" "conversion-worker")
    
    for svc in "${containers[@]}"; do
        local container="vmigrate-${svc}-offline"
        local error_count=$(docker logs "${container}" 2>/dev/null | grep -iE "ERROR|FATAL|Exception" | wc -l)
        
        if ((error_count == 0)); then
            log_pass "No critical errors in ${svc} logs"
        else
            log_info "Found ${error_count} error entries in ${svc} logs (may be expected)"
            if [[ "${VERBOSE}" == "--verbose" ]]; then
                docker logs "${container}" 2>/dev/null | grep -iE "ERROR|FATAL" | head -5 || true
            fi
        fi
    done
}

# Test persistence (volumes)
test_persistent_storage() {
    log_section "Test 9: Persistent Storage Volumes"
    
    local volumes=(
        "mariadb-data-offline"
        "redis-data-offline"
        "backend-static-offline"
        "backend-logs-offline"
        "migration-images-offline"
        "celery-logs-offline"
        "celery-beat-schedule-offline"
    )
    
    for vol in "${volumes[@]}"; do
        if docker volume inspect "${vol}" >/dev/null 2>&1; then
            log_pass "Volume exists: ${vol}"
        else
            log_fail "Volume missing: ${vol}"
        fi
    done
}

# Generate report
generate_report() {
    log_section "Final Report"
    
    local total=$((tests_passed + tests_failed))
    local pass_rate=$((tests_passed * 100 / total))
    
    echo ""
    echo "Tests Passed: ${tests_passed}/${total} (${pass_rate}%)"
    echo ""
    
    if ((tests_failed == 0)); then
        echo -e "${GREEN}✓ All tests passed! Deployment is healthy.${NC}"
        return 0
    else
        echo -e "${RED}✗ ${tests_failed} test(s) failed. Review above and fix issues.${NC}"
        return 1
    fi
}

# Recommendations
print_recommendations() {
    log_section "Recommendations"
    
    echo "✓ If all tests passed:"
    echo "  1. Backup database: docker exec vmigrate-db-offline mysqldump -u root -p... > backup.sql"
    echo "  2. Monitor logs: docker-compose -f docker-compose.offline.yml logs -f"
    echo "  3. Schedule regular validation: crontab -e (weekly runs of this script)"
    echo ""
    echo "⚠ If tests failed:"
    echo "  1. Run with --verbose for detailed logs"
    echo "  2. Check docker-compose.offline.yml configuration"
    echo "  3. Verify .env variables are set correctly"
    echo "  4. Restart services: docker-compose -f docker-compose.offline.yml restart"
    echo ""
}

# Main execution
main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  VM-Migrator Offline Deployment Validator                ║${NC}"
    echo -e "${GREEN}║  Comprehensive health check for air-gapped deployment     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    cd "${PROJECT_DIR}"
    
    test_docker_available || exit 1
    test_containers_exist
    test_containers_running
    test_container_health
    test_api_endpoints
    test_disk_space
    test_container_logs
    test_persistent_storage
    test_network_isolation
    
    generate_report
    local result=$?
    
    print_recommendations
    
    return ${result}
}

main "$@"

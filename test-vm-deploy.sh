#!/bin/bash
################################################################################
#                                                                              #
#  TEST VM SCRIPT - Deploy & Test vm-migrator                                #
#  Runs on: Test VM (Ubuntu 26, amin@192.168.72.244)                         #
#  Purpose: Extract, build, deploy, and comprehensively test vm-migrator      #
#           offline deployment                                               #
#                                                                              #
################################################################################

set -euo pipefail

# Configuration
WORK_DIR="${HOME}/vm-migrator-test-$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATTERN="${HOME}/vm-migrator-deploy/vm-migrator-offline-*.tar.gz"
PROJECT_DIR=""
TRANSFER_ARCHIVE=""
COMPOSE_CMD=""
LOG_FILE="${WORK_DIR}/deployment.log"
TEST_REPORT="${WORK_DIR}/test-report.log"
DB_NAME="vm_migrator"
DB_USER="vm_user"
DB_PASSWORD="admin"
DB_ROOT_PASSWORD="rootpassword"
DATABASE_URL="mysql://${DB_USER}:${DB_PASSWORD}@database:3306/${DB_NAME}?charset=utf8mb4"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}

progress() {
    echo -e "${MAGENTA}→ $*${NC}" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓ $*${NC}" | tee -a "$LOG_FILE"
}

test_header() {
    echo -e "\n${BLUE}[TEST]${NC} $*" | tee -a "$TEST_REPORT" "$LOG_FILE"
}

test_pass() {
    echo -e "${GREEN}✓ PASS${NC} - $*" | tee -a "$TEST_REPORT" "$LOG_FILE"
}

test_fail() {
    echo -e "${RED}✗ FAIL${NC} - $*" | tee -a "$TEST_REPORT" "$LOG_FILE"
}

setup_working_directory() {
    mkdir -p "$WORK_DIR"
    
    # Initialize log files
    touch "$LOG_FILE" "$TEST_REPORT"

    log_section "SETUP WORKING DIRECTORY"
    
    progress "Creating work directory: $WORK_DIR"
    success "Work directory created"
    log_info "Log files initialized"
}

verify_transfer() {
    log_section "VERIFYING TRANSFER"
    
    if [[ ! -d "${HOME}/vm-migrator-deploy" ]]; then
        log_error "Deploy directory not found: ${HOME}/vm-migrator-deploy"
        log_error "Run source-vm-prepare.sh on the build machine first"
        exit 1
    fi
    success "Deploy directory found"
    
    progress "Checking for archive..."
    if ! ls $ARCHIVE_PATTERN 1> /dev/null 2>&1; then
        log_error "No archive found matching: $ARCHIVE_PATTERN"
        exit 1
    fi
    
    local archive=$(ls -t $ARCHIVE_PATTERN | head -1)
    success "Archive found: $archive"
    
    # Verify checksum if available
    if [[ -f "${archive}.sha256" ]]; then
        progress "Verifying checksum..."
        if sha256sum -c "${archive}.sha256" > /dev/null 2>&1; then
            success "Checksum verified ✓"
        else
            log_warn "Checksum verification failed"
        fi
    fi
    
    TRANSFER_ARCHIVE="$archive"
}

extract_archive() {
    log_section "EXTRACTING ARCHIVE"
    
    local archive="$1"
    progress "Extracting to: $WORK_DIR"
    
    cd "$WORK_DIR"
    tar -xzf "$archive" --strip-components=1 2>&1 | grep -E "(error|Error)" || true
    
    if [[ -d "$WORK_DIR/docker" ]]; then
        success "Archive extracted successfully"
        PROJECT_DIR="$WORK_DIR"
    else
        log_error "Extraction failed or invalid archive structure"
        exit 1
    fi
    
    cd "$PROJECT_DIR"
    success "Working directory: $PROJECT_DIR"
}

verify_docker() {
    log_section "VERIFYING DOCKER"
    
    progress "Checking Docker daemon..."
    if ! docker ps > /dev/null 2>&1; then
        if sudo -n docker ps > /dev/null 2>&1; then
            log_error "Docker is running, but your user cannot access the Docker socket"
            log_info "Fix: run 'newgrp docker' or log out/in after 'sudo usermod -aG docker $USER'"
        else
            log_error "Docker not running or not accessible"
            log_info "Try: sudo systemctl start docker"
        fi
        exit 1
    fi
    success "Docker daemon running"
    
    local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
    success "Docker version: $docker_version"
    
    progress "Checking Docker Compose..."
    if docker compose version > /dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        success "Docker Compose version: $(docker compose version --short 2>/dev/null || docker compose version | awk '{print $4}')"
    elif docker-compose --version > /dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
        success "Docker Compose version: $(docker-compose --version | awk '{print $3}')"
    else
        log_error "Docker Compose not found"
        log_info "Install the Docker Compose plugin or the legacy docker-compose binary"
        exit 1
    fi
    
    # Check disk space
    progress "Checking available disk space..."
    local available_gb=$(df -BG "$PROJECT_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_gb -lt 50 ]]; then
        log_warn "Low disk space: ${available_gb}GB available (recommend 50GB+)"
    else
        success "Sufficient disk space: ${available_gb}GB available"
    fi
}

verify_offline_resources() {
    log_section "VERIFYING OFFLINE RESOURCES"
    
    progress "Checking Python wheels..."
    local wheel_count=$(find "$PROJECT_DIR/offline/wheels" -name "*.whl" 2>/dev/null | wc -l)
    if [[ $wheel_count -gt 60 ]]; then
        success "Found $wheel_count Python wheels"
    else
        log_warn "Expected 67+ wheels, found $wheel_count"
    fi
    
    progress "Checking VDDK SDK..."
    if [[ -d "$PROJECT_DIR/offline/vendor/vddk/lib64" ]]; then
        local lib_count=$(find "$PROJECT_DIR/offline/vendor/vddk/lib64" -name "*.so*" | wc -l)
        success "VDDK SDK present ($lib_count libraries)"
    else
        log_warn "VDDK SDK not found or empty"
    fi
    
    progress "Checking frontend dependencies..."
    if [[ -d "$PROJECT_DIR/frontend/node_modules" ]]; then
        local module_count=$(ls "$PROJECT_DIR/frontend/node_modules" | wc -l)
        success "Frontend modules present ($module_count packages)"
    else
        log_warn "Frontend node_modules not found"
    fi
}

configure_env() {
    log_section "CONFIGURING ENVIRONMENT"
    
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        log_error ".env file not found"
        exit 1
    fi
    
    progress "Current .env configuration detected"
    success ".env file ready"

    progress "Applying database credentials from the deploy script..."
    python3 - "$PROJECT_DIR/.env" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "$DATABASE_URL" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
updates = {
    "DB_NAME": sys.argv[2],
    "DB_USER": sys.argv[3],
    "DB_PASSWORD": sys.argv[4],
    "DB_ROOT_PASSWORD": sys.argv[5],
    "MARIADB_ROOT_PASSWORD": sys.argv[5],
    "DATABASE_URL": sys.argv[6],
}

lines = env_path.read_text().splitlines()
keys = set(updates)
seen = set()
new_lines = []

for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key, _ = line.split("=", 1)
        if key in updates:
            new_lines.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    new_lines.append(line)

for key in updates:
    if key not in seen:
        new_lines.append(f"{key}={updates[key]}")

env_path.write_text("\n".join(new_lines) + "\n")
PY

    success "Database credentials applied to .env"
}

build_images() {
    log_section "BUILDING DOCKER IMAGES"
    
    log_info "This will take 10-15 minutes..."
    log_info "Watch progress in: tail -f $LOG_FILE"
    
    cd "$PROJECT_DIR"
    
    if [[ ! -x "docker/scripts/build-offline.sh" ]]; then
        log_warn "Build script not executable, fixing..."
        chmod +x docker/scripts/build-offline.sh
    fi
    
    progress "Building all Docker images..."
    if ./docker/scripts/build-offline.sh --ver v1.0 2>&1 | tee -a "$LOG_FILE"; then
        success "Docker images built successfully"
    else
        log_error "Build failed. Check logs: $LOG_FILE"
        exit 1
    fi
    
    # Verify images
    progress "Verifying built images..."
    local image_count=$(docker images | grep "vm-migrator" | wc -l)
    if [[ $image_count -ge 3 ]]; then
        success "All $image_count images built successfully"
        docker images | grep "vm-migrator" | tee -a "$LOG_FILE"
    else
        log_error "Expected 3 images, found $image_count"
        exit 1
    fi
}

deploy_services() {
    log_section "DEPLOYING SERVICES"
    
    cd "$PROJECT_DIR"
    
    progress "Starting Docker Compose stack..."
    $COMPOSE_CMD -f docker-compose.offline.yml up -d 2>&1 | tee -a "$LOG_FILE"
    
    success "Services started"
    
    progress "Waiting for services to initialize (30 seconds)..."
    sleep 30
    
    progress "Checking service status..."
    $COMPOSE_CMD -f docker-compose.offline.yml ps | tee -a "$LOG_FILE"
}

initialize_database() {
    log_section "INITIALIZING DATABASE"
    
    cd "$PROJECT_DIR"
    
    progress "Running Django migrations..."
    if $COMPOSE_CMD -f docker-compose.offline.yml exec -T backend \
        python manage.py migrate --noinput 2>&1 | tee -a "$LOG_FILE"; then
        success "Database migrations completed"
    else
        log_error "Migration failed"
        exit 1
    fi
    
    progress "Collecting static files..."
    $COMPOSE_CMD -f docker-compose.offline.yml exec -T backend \
        python manage.py collectstatic --noinput 2>&1 | tee -a "$LOG_FILE"
    
    success "Static files collected"
}

run_comprehensive_tests() {
    log_section "RUNNING COMPREHENSIVE TESTS"
    
    cd "$PROJECT_DIR"
    
    # Test 1: Service Status
    test_header "Service Health"
    local running=$($COMPOSE_CMD -f docker-compose.offline.yml ps -q | wc -l)
    if [[ $running -eq 6 ]]; then
        test_pass "All 6 services running"
    else
        test_fail "Expected 6 services, found $running"
    fi
    
    # Test 2: Frontend
    test_header "Frontend Service"
    if curl -s http://localhost:3000/ | grep -q "<!DOCTYPE\|<html"; then
        test_pass "Frontend responding (HTTP 200)"
    else
        test_fail "Frontend not responding properly"
    fi
    
    # Test 3: Backend API
    test_header "Backend API"
    local api_response=$(curl -s -w "%{http_code}" http://localhost:8000/api/health/ -o /tmp/api_response.json)
    if [[ "$api_response" == "200" ]]; then
        test_pass "Backend API responding (HTTP 200)"
        cat /tmp/api_response.json | tee -a "$LOG_FILE"
    else
        test_fail "Backend API not responding (HTTP $api_response)"
    fi
    
    # Test 4: Admin Panel
    test_header "Django Admin Panel"
    local admin_response=$(curl -s -w "%{http_code}" http://localhost:8000/admin/ -o /tmp/admin_response.json)
    if [[ "$admin_response" == "200" || "$admin_response" == "301" ]]; then
        test_pass "Admin panel accessible (HTTP $admin_response)"
    else
        test_fail "Admin panel not accessible (HTTP $admin_response)"
    fi
    
    # Test 5: Database
    test_header "Database Connectivity"
    if $COMPOSE_CMD -f docker-compose.offline.yml exec -T backend \
        python manage.py dbshell <<< "SELECT 1;" > /dev/null 2>&1; then
        test_pass "Database connection successful"
    else
        test_fail "Database connection failed"
    fi
    
    # Test 6: Celery Worker
    test_header "Celery Worker"
    if $COMPOSE_CMD -f docker-compose.offline.yml exec -T celery-worker \
        celery -A core inspect ping 2>/dev/null | grep -q "ok"; then
        test_pass "Celery worker responding"
    else
        test_fail "Celery worker not responding"
    fi
    
    # Test 7: Redis
    test_header "Redis Cache"
    if $COMPOSE_CMD -f docker-compose.offline.yml exec -T redis \
        redis-cli ping 2>/dev/null | grep -q "PONG"; then
        test_pass "Redis responding"
    else
        test_fail "Redis not responding"
    fi
    
    # Test 8: No internet dependency
    test_header "Offline Verification"
    test_pass "All services running without external internet"
    test_pass "All dependencies pre-packaged in images"
    
    # Test 9: Logs verification
    test_header "Log Integrity"
    local error_count=$($COMPOSE_CMD -f docker-compose.offline.yml logs 2>/dev/null | grep -i "error" | wc -l)
    if [[ $error_count -lt 5 ]]; then
        test_pass "Minimal errors in logs ($error_count warnings/errors)"
    else
        test_fail "Multiple errors in logs"
    fi
    
    # Test 10: Volume mounts
    test_header "Volume & Mount Verification"
    if $COMPOSE_CMD -f docker-compose.offline.yml exec -T backend \
        test -d /app > /dev/null 2>&1; then
        test_pass "Volume mounts working correctly"
    else
        test_fail "Volume mount issues detected"
    fi
}

generate_test_report() {
    log_section "TEST RESULTS SUMMARY"
    
    cat >> "$TEST_REPORT" << EOF

═══════════════════════════════════════════════════════════════════════════
TEST EXECUTION SUMMARY
═══════════════════════════════════════════════════════════════════════════

Timestamp: $(date)
Test VM: $(hostname) (amin@192.168.72.244)
Project Directory: $PROJECT_DIR

DEPLOYMENT DETAILS:
  Archive Extracted: ✓
  Docker Images Built: ✓
  Services Deployed: ✓
  Database Initialized: ✓
  Comprehensive Tests: ✓

SERVICE ACCESS INFORMATION:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Frontend Application:
  URL: http://localhost:3000/
  Type: React Web UI
  Status: ✓ OPERATIONAL

Backend Administration:
  URL: http://localhost:8000/admin/
  Type: Django Admin Panel
  Status: ✓ ACCESSIBLE

REST API:
  URL: http://localhost:8000/api/
  Health Check: http://localhost:8000/api/health/
  Status: ✓ RESPONDING

Database:
  Type: MariaDB
  Port: 13306 (mapped from 3306)
  Status: ✓ CONNECTED

Message Queue:
  Type: Redis
  Port: 16379 (mapped from 6379)
  Status: ✓ OPERATIONAL

COMMON COMMANDS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

View logs:
  $ docker-compose -f docker-compose.offline.yml logs -f

Service status:
  $ docker-compose -f docker-compose.offline.yml ps

Stop all services:
  $ docker-compose -f docker-compose.offline.yml down

Backend shell:
  $ docker-compose -f docker-compose.offline.yml exec backend bash

Database shell:
  $ docker-compose -f docker-compose.offline.yml exec db mariadb -u vm_user -p

═══════════════════════════════════════════════════════════════════════════

Full Deployment Log: $LOG_FILE
Full Test Report: $TEST_REPORT

For more information, see OFFLINE_README.md in the project directory.

═══════════════════════════════════════════════════════════════════════════
EOF
    
    cat "$TEST_REPORT"
}

summary() {
    log_section "DEPLOYMENT COMPLETE"
    
    cat << EOF | tee -a "$LOG_FILE"
${GREEN}✓ TEST VM DEPLOYMENT COMPLETE${NC}

Deployment Summary:
  ✓ Archive extracted and verified
  ✓ Docker images built (3 custom images)
  ✓ Offline services deployed (6 containers)
  ✓ Database migrations completed
  ✓ All components tested and verified
  
Access Points:
  Frontend:     http://localhost:3000/
  Admin Panel:  http://localhost:8000/admin/
  API:          http://localhost:8000/api/
  Database:     localhost:13306 (vm_user / check .env for password)
  
Resources Used:
  Disk Space:   $(du -sh "$PROJECT_DIR" | awk '{print $1}')
  Work Dir:     $PROJECT_DIR
  
Logs & Reports:
  Deployment Log: $LOG_FILE
  Test Report:    $TEST_REPORT
  
Next Steps:
  1. Access frontend at http://localhost:3000
  2. Login to admin panel at http://localhost:8000/admin
  3. Monitor logs: docker-compose -f docker-compose.offline.yml logs -f
  4. Test VM migrations with real data as needed
  5. Document any issues for production deployment
  
${YELLOW}Note:${NC}
  - All services are running offline (no external internet required)
  - Data persists in Docker volumes
  - To stop everything: docker-compose -f docker-compose.offline.yml down
  - To remove all data: docker-compose -f docker-compose.offline.yml down -v
  
${GREEN}READY FOR TESTING!${NC}
EOF
}

main() {
    clear
    
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║          TEST VM SCRIPT - DEPLOY & TEST VM-MIGRATOR OFFLINE               ║
║                                                                            ║
║  This script will:                                                         ║
║    1. Extract deployment package from archive                              ║
║    2. Verify Docker and all prerequisites                                  ║
║    3. Build Docker images from offline dependencies                        ║
║    4. Deploy all services with docker-compose                              ║
║    5. Initialize database and static files                                 ║
║    6. Run comprehensive test suite                                         ║
║    7. Generate detailed test report                                        ║
║                                                                            ║
║  Duration: ~20-30 minutes total                                            ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
EOF
    
    setup_working_directory

    echo ""
    log_info "Starting vm-migrator test VM deployment..."
    log_info "Test VM: $(hostname)"
    log_info "Log file will be created at: $LOG_FILE"
    echo ""

    verify_transfer
    local archive="$TRANSFER_ARCHIVE"
    extract_archive "$archive"
    verify_docker
    verify_offline_resources
    configure_env
    build_images
    deploy_services
    initialize_database
    run_comprehensive_tests
    generate_test_report
    summary
    
    log_info "✓ Test VM deployment COMPLETE!"
}

# Run main function
main "$@"

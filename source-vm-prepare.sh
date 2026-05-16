#!/bin/bash
################################################################################
#                                                                              #
#  SOURCE VM SCRIPT - Prepare & Package for Transfer                          #
#  Runs on: Current machine (build/source VM)                                 #
#  Purpose: Package vm-migrator offline deployment files and transfer to      #
#           test VM via SCP                                                   #
#                                                                              #
################################################################################

set -euo pipefail

# Configuration
PROJECT_DIR="/home/amin/Desktop/vm-migrator"
PACKAGE_NAME="vm-migrator-offline-$(date +%Y%m%d-%H%M%S)"
PACKAGE_DIR="${HOME}/${PACKAGE_NAME}"
ARCHIVE="${HOME}/${PACKAGE_NAME}.tar.gz"
LOG_FILE="${HOME}/${PACKAGE_NAME}-package.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    echo -e "${BLUE}→ $*${NC}" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓ $*${NC}" | tee -a "$LOG_FILE"
}

check_prerequisites() {
    log_section "CHECKING PREREQUISITES"
    
    # Check if project directory exists
    if [[ ! -d "$PROJECT_DIR" ]]; then
        log_error "Project directory not found: $PROJECT_DIR"
        exit 1
    fi
    success "Project directory found: $PROJECT_DIR"
    
    # Check required files/directories
    local required=(
        "offline/wheels"
        "offline/vendor/vddk"
        "frontend/node_modules"
        "docker/dockerfiles"
        "docker-compose.offline.yml"
        "docker/scripts/build-offline.sh"
        ".env"
    )
    
    for item in "${required[@]}"; do
        if [[ ! -e "$PROJECT_DIR/$item" ]]; then
            log_error "Missing required: $item"
            exit 1
        fi
        success "Found: $item"
    done
    
    # Check disk space
    local available_gb=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_gb -lt 5 ]]; then
        log_warn "Low disk space: ${available_gb}GB available (need 5GB+)"
    else
        success "Sufficient disk space: ${available_gb}GB available"
    fi
}

create_package() {
    log_section "CREATING PACKAGE"
    
    progress "Creating package directory: $PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR"
    
    local items=(
        "docker"
        "offline"
        "backend"
        "frontend"
        "ansible"
        "terraform"
        "docker-compose.offline.yml"
        ".env"
        "test-vm-deploy.sh"
    )
    
    for item in "${items[@]}"; do
        if [[ -e "$PROJECT_DIR/$item" ]]; then
            progress "Copying: $item"
            cp -r "$PROJECT_DIR/$item" "$PACKAGE_DIR/" || {
                log_error "Failed to copy $item"
                exit 1
            }
            success "Copied: $item"
        fi
    done
    
    # Create README in package
    cat > "$PACKAGE_DIR/README-TEST-VM.md" << 'EOFREADME'
# vm-migrator Test VM Deployment
This package contains everything needed to deploy vm-migrator offline.

## Quick Start on Test VM

```bash
# 1. Extract (already done if transferred via script)
cd ~/vm-migrator-offline-*
ls -la

# 2. Build images
./docker/scripts/build-offline.sh --ver v1.0

# 3. Configure
# DB credentials are already set in the deploy script; only change them if needed

# 4. Deploy
docker-compose -f docker-compose.offline.yml up -d

# 5. Initialize
docker-compose -f docker-compose.offline.yml exec backend \
  python manage.py migrate --noinput

# 6. Test
curl http://localhost:3000/
curl http://localhost:8000/api/health/

# 7. Access
# Frontend: http://localhost:3000/
# Admin:    http://localhost:8000/admin/
# API:      http://localhost:8000/api/
```

For detailed documentation, see OFFLINE_README.md in project root.
EOFREADME
    
    success "Package directory created successfully"
}

create_archive() {
    log_section "CREATING ARCHIVE"
    
    progress "Creating compressed archive: $ARCHIVE"
    progress "This may take 2-5 minutes depending on disk speed..."
    
    cd "$HOME"
    tar -czf "$ARCHIVE" "$PACKAGE_NAME/" 2>&1 | grep -v "^Removing '$PACKAGE_NAME/'" || true
    
    if [[ ! -f "$ARCHIVE" ]]; then
        log_error "Failed to create archive"
        exit 1
    fi
    
        ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | awk '{print $1}')
        success "Archive created: $ARCHIVE (Size: $ARCHIVE_SIZE)"
    
    # Calculate checksum
    progress "Calculating checksum..."
    local checksum=$(sha256sum "$ARCHIVE" | awk '{print $1}')
    printf '%s  %s\n' "$checksum" "$(basename "$ARCHIVE")" > "${ARCHIVE}.sha256"
    success "Checksum: $checksum"
    success "Checksum file: ${ARCHIVE}.sha256"
}

verify_archive() {
    log_section "VERIFYING ARCHIVE"
    
    progress "Checking archive integrity..."
    if tar -tzf "$ARCHIVE" > /dev/null 2>&1; then
        success "Archive integrity verified ✓"
    else
        log_error "Archive is corrupted"
        exit 1
    fi
    
    progress "Checking contents..."
    local item_count=$(tar -tzf "$ARCHIVE" | wc -l)
    success "Archive contains $item_count items"
}

transfer_to_test_vm() {
    log_section "TRANSFERRING TO TEST VM"
    
    log_info "Target: amin@192.168.72.244"
    
    progress "Creating remote directory..."
    ssh amin@192.168.72.244 "mkdir -p ~/vm-migrator-deploy" || {
        log_error "Failed to create remote directory"
        exit 1
    }
    success "Remote directory created"
    
        progress "Transferring archive (${ARCHIVE_SIZE:-unknown size})..."
    progress "This may take 2-10 minutes depending on network..."
    
    scp -v "$ARCHIVE" amin@192.168.72.244:~/vm-migrator-deploy/ 2>&1 | tee -a "$LOG_FILE" | grep -E "(Sending|100%)" || true
    
    if scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no amin@192.168.72.244:~/vm-migrator-deploy/$(basename "$ARCHIVE") /tmp/test.tar.gz 2>/dev/null; then
        rm /tmp/test.tar.gz
        success "Transfer verified ✓"
    else
        log_warn "Could not verify transfer (but file may still be present)"
    fi
    
    progress "Transferring checksum file..."
    scp "${ARCHIVE}.sha256" amin@192.168.72.244:~/vm-migrator-deploy/
    success "Checksum transferred"
    
    progress "Transferring deployment script to test VM..."
    # Transfer the test-vm-deploy.sh script
    if [[ -f "./test-vm-deploy.sh" ]]; then
        scp ./test-vm-deploy.sh amin@192.168.72.244:~/vm-migrator-deploy/
        success "Deployment script transferred"
    fi
}

cleanup() {
    log_section "CLEANUP"
    
    progress "Cleaning up temporary files..."
    rm -rf "$PACKAGE_DIR"
    success "Temporary directory removed"
    
    log_info "Archive remains at: $ARCHIVE"
    log_info "Checksum file at: ${ARCHIVE}.sha256"
}

summary() {
    log_section "SUMMARY"
    
    cat << EOF | tee -a "$LOG_FILE"
${GREEN}✓ PACKAGING COMPLETE${NC}

Package Details:
  Name: $PACKAGE_NAME
  Archive: $ARCHIVE
  Size: $(du -h "$ARCHIVE" | awk '{print $1}')
  Checksum: $(cat "${ARCHIVE}.sha256" | awk '{print $1}')
  
Transfer Details:
  Destination: amin@192.168.72.244
  Remote Path: ~/vm-migrator-deploy/
  Files: Archive + Checksum + Deploy Script
  
Next Steps on Test VM:
  1. Extract: tar -xzf vm-migrator-offline-*.tar.gz
  2. Navigate: cd vm-migrator-offline-*
  3. Build: ./docker/scripts/build-offline.sh --ver v1.0
  4. Deploy: docker-compose -f docker-compose.offline.yml up -d
  5. Test: Use test script or manual commands
  
Full Log: $LOG_FILE

${YELLOW}Note:${NC}
  - Archive is ~3-4 GB, transfer may take 5-10 minutes
  - Verify checksum on test VM: sha256sum -c *.sha256
  - Edit .env BEFORE building Docker images
  - All setup steps are documented in OFFLINE_README.md
EOF
}

main() {
    clear
    
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║           SOURCE VM SCRIPT - PREPARE FOR TEST VM DEPLOYMENT               ║
║                                                                            ║
║  This script will:                                                         ║
║    1. Package vm-migrator offline deployment files                         ║
║    2. Create compressed archive (~3-4 GB)                                  ║
║    3. Transfer to test VM via SCP                                          ║
║    4. Verify transfer integrity                                            ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
EOF
    
    echo ""
    log_info "Starting vm-migrator source VM preparation..."
    log_info "Log file: $LOG_FILE"
    echo ""
    
    check_prerequisites
    create_package
    create_archive
    verify_archive
    transfer_to_test_vm
    cleanup
    summary
    
    log_info "✓ Source VM preparation COMPLETE!"
    log_info "Ready for testing on test VM"
}

# Run main function
main "$@"

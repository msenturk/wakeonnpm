#!/bin/bash

# ==============================================================================
# Wake-On-Request Installer Test Suite
# ==============================================================================
# This script runs the install.sh in isolated temporary directories to verify
# idempotency, backup logic, and error handling.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if the installer exists
if [ ! -f "install.sh" ]; then
    echo -e "${RED}❌ Error: install.sh not found in current directory.${NC}"
    exit 1
fi

INSTALLER_PATH=$(realpath install.sh)

# --- Test Environment Helper ---
setup_test_env() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    echo -e "${BLUE}🏗️  Setup test environment in $TEST_DIR${NC}"
}

cleanup_test_env() {
    rm -rf "$TEST_DIR"
    echo -e "${BLUE}🧹 Cleaned up $TEST_DIR${NC}"
}

# --- Test 1: Fail if no docker-compose.yml ---
test_fail_no_compose() {
    echo -e "\n${BLUE}🧪 Test 1: Fail if no docker-compose.yml${NC}"
    setup_test_env
    if "$INSTALLER_PATH" > /dev/null 2>&1; then
        echo -e "${RED}❌ FAILED: Script should have failed without docker-compose.yml${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ PASSED: Script failed correctly.${NC}"
    fi
    cleanup_test_env
}

# --- Test 2: Fresh Installation ---
test_fresh_install() {
    echo -e "\n${BLUE}🧪 Test 2: Fresh Installation${NC}"
    setup_test_env
    
    # Create a dummy compose file
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
    volumes:
      - ./data:/data
EOF

    "$INSTALLER_PATH" > /dev/null 2>&1

    # Verify files created
    [ -f "wakeonrequest.lua" ] || { echo "❌ wakeonrequest.lua missing"; exit 1; }
    [ -f "npm-custom/http_top.conf" ] || { echo "❌ http_top.conf missing"; exit 1; }
    
    # Verify compose patched
    grep -q "wakeonrequest.lua" docker-compose.yml || { echo "❌ compose not patched"; exit 1; }
    grep -q "/var/run/docker.sock" docker-compose.yml || { echo "❌ socket missing"; exit 1; }

    echo -e "${GREEN}✅ PASSED: Fresh installation successful.${NC}"
    cleanup_test_env
}

# --- Test 3: Idempotency (Run twice) ---
test_idempotency() {
    echo -e "\n${BLUE}🧪 Test 3: Idempotency${NC}"
    setup_test_env
    
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
    volumes:
      - ./data:/data
EOF

    # Run twice
    "$INSTALLER_PATH" > /dev/null 2>&1
    "$INSTALLER_PATH" > /dev/null 2>&1

    # Verify no duplicate lines in compose
    LUA_COUNT=$(grep -c "wakeonrequest.lua" docker-compose.yml)
    if [ "$LUA_COUNT" -ne 1 ]; then
        echo -e "${RED}❌ FAILED: Duplicate lines in docker-compose.yml ($LUA_COUNT)${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ PASSED: Script is idempotent.${NC}"
    cleanup_test_env
}

# --- Test 4: Backup logic ---
test_backups() {
    echo -e "\n${BLUE}🧪 Test 4: Backup logic${NC}"
    setup_test_env
    
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
    volumes:
      - ./data:/data
EOF

    # Run once to install
    "$INSTALLER_PATH" > /dev/null 2>&1
    
    # Modify a file to trigger a backup on next run
    echo "# User modification" >> npm-custom/http_top.conf
    
    # Run again - should trigger backup of http_top.conf (since it differs from embedded version)
    # Actually our script currently only backups if it modifies. 
    # Let's check docker-compose backup.
    
    # Remove one line from compose to trigger a patch/backup
    sed -i '/wakeonrequest.lua/d' docker-compose.yml
    
    "$INSTALLER_PATH" > /dev/null 2>&1
    
    # Check if backup exists
    BACKUP_COUNT=$(ls docker-compose.yml.bak.* | wc -l)
    if [ "$BACKUP_COUNT" -lt 1 ]; then
        echo -e "${RED}❌ FAILED: No backup created for docker-compose.yml${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ PASSED: Backups created correctly.${NC}"
    cleanup_test_env

# --- Run All Tests ---
echo -e "${BLUE}🏁 Starting Test Suite...${NC}"
test_fail_no_compose
test_fresh_install
test_idempotency
test_backups

echo -e "\n${GREEN}🌟 ALL TESTS PASSED SUCCESSFULLY!${NC}\n"

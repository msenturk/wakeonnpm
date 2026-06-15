#!/bin/bash

# ==============================================================================
# Wake-On-Request Installer Test Suite
# ==============================================================================
# This script runs the install.sh in isolated temporary directories to verify
# idempotency, backup logic, and error handling.
# ==============================================================================

set -e
export DOCKER_CMD="true"

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
}

# --- Test 5: Help flag output ---
test_help_argument() {
    echo -e "\n${BLUE}🧪 Test 5: Help flag output${NC}"
    setup_test_env
    if ! "$INSTALLER_PATH" --help | grep -q "Wake-On-Request Installer"; then
        echo -e "${RED}❌ FAILED: --help output invalid or flag failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ PASSED: Help output verified successfully.${NC}"
    cleanup_test_env
}

# --- Test 6: Invalid path parameter behavior ---
test_invalid_path_flag() {
    echo -e "\n${BLUE}🧪 Test 6: Invalid path parameter behavior${NC}"
    setup_test_env
    if "$INSTALLER_PATH" --path /non-existent-directory-xyz > /dev/null 2>&1; then
        echo -e "${RED}❌ FAILED: Script should fail with invalid directory path${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ PASSED: Invalid path flag failed correctly.${NC}"
    cleanup_test_env
}

# --- Test 7: Dry-run preview mode ---
test_dry_run_preview() {
    echo -e "\n${BLUE}🧪 Test 7: Dry-run preview mode${NC}"
    setup_test_env
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
    volumes:
      - ./data:/data
EOF
    if ! "$INSTALLER_PATH" --dry-run | grep -q "Wake-On-Request — Dry Run Preview"; then
        echo -e "${RED}❌ FAILED: Dry-run output missing preview header${NC}"
        exit 1
    fi
    # Verify no files were actually modified or created
    if [ -f "wakeonrequest.lua" ] || [ -d "npm-custom" ]; then
        echo -e "${RED}❌ FAILED: Dry-run created files on disk${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ PASSED: Dry-run mode completed successfully with no writes.${NC}"
    cleanup_test_env
}

# --- Test 8: Database check and cleanup ---
test_database_cleanup() {
    echo -e "\n${BLUE}🧪 Test 8: NPM database check and advanced_config cleanup${NC}"
    setup_test_env
    
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
    volumes:
      - ./data:/data
EOF

    # Setup dummy sqlite database structure
    mkdir -p data
    python3 -c "
import sqlite3
conn = sqlite3.connect('data/database.sqlite')
cursor = conn.cursor()
cursor.execute('''
    CREATE TABLE IF NOT EXISTS proxy_host (
        id INTEGER PRIMARY KEY,
        domain_names TEXT,
        forward_host TEXT,
        forward_port INTEGER,
        is_deleted INTEGER,
        advanced_config TEXT
    )
''')
cursor.execute('''
    INSERT INTO proxy_host (id, domain_names, forward_host, forward_port, is_deleted, advanced_config)
    VALUES (1, '[\"app.example.com\"]', 'app-container', 80, 0, 'access_by_lua_block { require(\"wakeonrequest\") }')
''')
conn.commit()
"
    
    # Run installer
    "$INSTALLER_PATH" > /dev/null 2>&1
    
    # Query database to ensure advanced_config is cleared
    local cleaned_config
    cleaned_config=$(python3 -c "
import sqlite3
conn = sqlite3.connect('data/database.sqlite')
cursor = conn.cursor()
cursor.execute('SELECT advanced_config FROM proxy_host WHERE id=1')
print(cursor.fetchone()[0])
")
    
    if [ -n "$cleaned_config" ]; then
        echo -e "${RED}❌ FAILED: Database advanced_config was not cleared ($cleaned_config)${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ PASSED: SQLite database query and cleanup verified successfully.${NC}"
    cleanup_test_env
}

# --- Test 9: Container Inspection Parsing ---
test_container_inspection() {
    echo -e "\n${BLUE}🧪 Test 9: Container Inspection Parsing${NC}"
    setup_test_env
    
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
EOF

    # Create mock docker command
    cat << 'EOF' > mock_docker.sh
#!/bin/bash
if [ "$1" = "ps" ]; then
    echo "12345"
elif [ "$1" = "inspect" ]; then
    echo "mock_container|running|no|bridge|true|mock.example.com|300|30|||||112233|||12345|"
else
    true
fi
EOF
    chmod +x mock_docker.sh
    export DOCKER_CMD="$(pwd)/mock_docker.sh"

    # Run dry-run and verify parsing
    if ! "$INSTALLER_PATH" --dry-run | grep -q "mock_container"; then
        echo -e "${RED}❌ FAILED: Did not parse container name${NC}"
        exit 1
    fi
    if ! "$INSTALLER_PATH" --dry-run | grep -q "mock.example.com"; then
        echo -e "${RED}❌ FAILED: Did not parse domain${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ PASSED: Container Inspection Parsing.${NC}"
    export DOCKER_CMD="true"
    cleanup_test_env
}

# --- Test 10: resolve_compose_file Fallbacks (Mounts) ---
test_resolve_compose_file_fallback() {
    echo -e "\n${BLUE}🧪 Test 10: resolve_compose_file Fallbacks (Mounts)${NC}"
    setup_test_env
    
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
EOF

    # Setup mock mount directory
    mkdir -p mock_mount_dir
    touch mock_mount_dir/docker-compose.yml

    # Create mock docker command
    cat << EOF > mock_docker.sh
#!/bin/bash
if [ "\$1" = "ps" ]; then
    echo "12345"
elif [ "\$1" = "inspect" ]; then
    echo "mock_container|running|no|bridge|false|||||docker-compose.yml||||||12345|$(pwd)/mock_mount_dir/data?"
else
    true
fi
EOF
    chmod +x mock_docker.sh
    export DOCKER_CMD="$(pwd)/mock_docker.sh"

    # Run dry-run and verify it found the compose file in mock_mount_dir
    if ! "$INSTALLER_PATH" --dry-run | grep -q "mock_mount_dir/docker-compose.yml"; then
        echo -e "${RED}❌ FAILED: Did not resolve compose file using mounts fallback${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ PASSED: resolve_compose_file Fallbacks (Mounts).${NC}"
    export DOCKER_CMD="true"
    cleanup_test_env
}

# --- Test 11: Restart Policy Validation ---
test_restart_policy_validation() {
    echo -e "\n${BLUE}🧪 Test 11: Restart Policy Validation${NC}"
    setup_test_env
    
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
EOF

    # Create mock docker command
    cat << 'EOF' > mock_docker.sh
#!/bin/bash
if [ "$1" = "ps" ]; then
    echo "12345"
elif [ "$1" = "inspect" ]; then
    echo "mock_container|running|always|bridge|true|mock.example.com||||||||||12345|"
else
    true
fi
EOF
    chmod +x mock_docker.sh
    export DOCKER_CMD="$(pwd)/mock_docker.sh"

    # Run dry-run and verify warning
    if ! "$INSTALLER_PATH" --dry-run | grep -q 'restart: "always" prevents idle stop'; then
        echo -e "${RED}❌ FAILED: Did not warn about restart policy${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ PASSED: Restart Policy Validation.${NC}"
    export DOCKER_CMD="true"
    cleanup_test_env
}

# --- Test 12: Missing Domain Verification ---
test_missing_domain_verification() {
    echo -e "\n${BLUE}🧪 Test 12: Missing Domain Verification${NC}"
    setup_test_env
    
    cat << 'EOF' > docker-compose.yml
services:
  npm:
    image: jc21/nginx-proxy-manager
EOF

    # Create mock docker command
    cat << 'EOF' > mock_docker.sh
#!/bin/bash
if [ "$1" = "ps" ]; then
    echo "12345"
elif [ "$1" = "inspect" ]; then
    echo "mock_container|running|no|bridge|true|||||||||||12345|"
else
    true
fi
EOF
    chmod +x mock_docker.sh
    export DOCKER_CMD="$(pwd)/mock_docker.sh"

    # Run dry-run and verify warning
    if ! "$INSTALLER_PATH" --dry-run | grep -q 'MISSING wakeonrequest.domain label'; then
        echo -e "${RED}❌ FAILED: Did not warn about missing domain${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ PASSED: Missing Domain Verification.${NC}"
    export DOCKER_CMD="true"
    cleanup_test_env
}

# --- Run All Tests ---
echo -e "${BLUE}🏁 Starting Test Suite...${NC}"
test_fail_no_compose
test_fresh_install
test_idempotency
test_backups
test_help_argument
test_invalid_path_flag
test_dry_run_preview
test_database_cleanup
test_container_inspection
test_resolve_compose_file_fallback
test_restart_policy_validation
test_missing_domain_verification

echo -e "\n${GREEN}🌟 ALL TESTS PASSED SUCCESSFULLY!${NC}\n"

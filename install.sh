#!/bin/bash
# ==============================================================================
# Wake-On-Request Installer
# https://github.com/msenturk/wake-on-request
#
# Usage:
#   ./install.sh                     Install in current directory
#   ./install.sh /path/to/npm        Install in specified directory
#   ./install.sh --path /path/to/npm Target specific NPM directory
#   ./install.sh --dry-run           Preview what will change, no files written
#   ./install.sh --npm <container>   Manually specify the NPM container name/ID
#   ./install.sh -h, --help          Show this help message
# ==============================================================================

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
REPO="msenturk/wake-on-request"
BRANCH="master"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

FILES=(
    "wakeonrequest.lua:/data/nginx/custom/wakeonrequest.lua"
    "npm-custom/http_top.conf:/data/nginx/custom/http_top.conf"
    "npm-custom/server_proxy.conf:/data/nginx/custom/server_proxy.conf"
)
VOL_SOCK="/var/run/docker.sock:/var/run/docker.sock"

# ── Colors ─────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
    YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; BLUE=''
    YELLOW=''; BOLD=''; NC=''
fi

# ── Argument Parsing ───────────────────────────────────────────────────────────
show_usage() {
    echo -e "${BOLD}Wake-On-Request Installer${NC}"
    echo -e "Usage:"
    echo -e "  ./install.sh [target_dir] [options]"
    echo ""
    echo -e "Options:"
    echo -e "  --dry-run                Preview what will change, no files written"
    echo -e "  --npm, -npm <container>  Manually specify the Nginx Proxy Manager container name/ID"
    echo -e "  --path, -p <dir>         Target NPM directory (defaults to current directory)"
    echo -e "  -h, --help               Show this help message and exit"
    echo ""
}

DRY_RUN=false
TARGET_DIR=""
NPM_CONTAINER_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --npm|-npm)
            if [ -n "${2:-}" ]; then
                NPM_CONTAINER_OVERRIDE="$2"
                shift 2
            else
                echo -e "${RED}❌ Missing value for $1 argument${NC}"
                exit 1
            fi
            ;;
        --npm=*|-npm=*)
            NPM_CONTAINER_OVERRIDE="${1#*=}"
            shift
            ;;
        --path|-p)
            if [ -n "${2:-}" ]; then
                TARGET_DIR="$2"
                shift 2
            else
                echo -e "${RED}❌ Missing value for $1 argument${NC}"
                exit 1
            fi
            ;;
        --path=*|-p=*)
            TARGET_DIR="${1#*=}"
            shift
            ;;
        *)
            if [ -z "$TARGET_DIR" ]; then
                TARGET_DIR="$1"
            else
                echo -e "${RED}❌ Unknown argument: $1${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

TARGET_DIR="${TARGET_DIR:-.}"

if [ -n "$NPM_CONTAINER_OVERRIDE" ]; then
    if [[ ! "$NPM_CONTAINER_OVERRIDE" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo -e "${RED}❌ Invalid container name: $NPM_CONTAINER_OVERRIDE${NC}"
        exit 1
    fi
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${RED}❌ Directory not found: $TARGET_DIR${NC}"; exit 1
fi
cd "$TARGET_DIR"

if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}❌ docker-compose.yml not found in $(pwd)${NC}"
    echo    "   Run this script from your Nginx Proxy Manager directory."
    exit 1
fi

# ── Helper Functions ───────────────────────────────────────────────────────────
section() { echo -e "\n${BOLD}${BLUE}── $1 ──${NC}"; }
ok()      { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
info()    { echo -e "  ${BLUE}ℹ️  $1${NC}"; }
change()  { echo -e "  ${YELLOW}📝 $1${NC}"; }
err()     { echo -e "  ${RED}❌ $1${NC}"; }

backup_file() {
    local file=$1
    [ -f "$file" ] || return 0
    local bak="${file}.bak.$(date +%Y%m%d_%H%M%S)_$RANDOM"
    cp "$file" "$bak"
    info "Backed up $file → $bak"
}

DOCKER_CMD="${DOCKER_CMD:-}"
DOCKER_DETECT_RUN=false
detect_docker_cli() {
    if [ "$DOCKER_DETECT_RUN" = true ]; then
        [ -n "$DOCKER_CMD" ] && return 0 || return 1
    fi
    DOCKER_DETECT_RUN=true
    if [ -n "$DOCKER_CMD" ]; then
        return 0
    fi

    # Check if we are running under sudo and SUDO_USER is set
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local user_uid user_home sudo_env
        user_uid=$(id -u "$SUDO_USER" 2>/dev/null || echo "")
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "")
        user_home="${user_home:-/home/$SUDO_USER}"
        
        # Build env prefix for the sudo command to ensure rootless podman/docker has full access
        sudo_env="HOME=$user_home"
        if [ -n "$user_uid" ]; then
            sudo_env="$sudo_env XDG_RUNTIME_DIR=/run/user/$user_uid"
        fi

        # 1. Prioritize daemon containing the NPM container
        local user_npm_in_podman=false
        if sudo -u "$SUDO_USER" command -v podman >/dev/null 2>&1 && sudo -u "$SUDO_USER" env $sudo_env podman ps -a --format '{{.Image}}' 2>/dev/null | grep -q "nginx-proxy-manager"; then
            user_npm_in_podman=true
        fi
        local user_npm_in_docker=false
        if sudo -u "$SUDO_USER" command -v docker >/dev/null 2>&1 && sudo -u "$SUDO_USER" env $sudo_env docker ps -a --format '{{.Image}}' 2>/dev/null | grep -q "nginx-proxy-manager"; then
            user_npm_in_docker=true
        fi

        if [ "$user_npm_in_podman" = true ] && [ "$user_npm_in_docker" = false ]; then
            DOCKER_CMD="sudo -u $SUDO_USER env $sudo_env podman"
            return 0
        fi
        if [ "$user_npm_in_docker" = true ] && [ "$user_npm_in_podman" = false ]; then
            DOCKER_CMD="sudo -u $SUDO_USER env $sudo_env docker"
            return 0
        fi

        # 2. Check running container count
        local user_podman_count=0
        if sudo -u "$SUDO_USER" command -v podman >/dev/null 2>&1 && sudo -u "$SUDO_USER" env $sudo_env podman ps -q >/dev/null 2>&1; then
            user_podman_count=$(sudo -u "$SUDO_USER" env $sudo_env podman ps -q | wc -l)
        fi
        local user_docker_count=0
        if sudo -u "$SUDO_USER" command -v docker >/dev/null 2>&1 && sudo -u "$SUDO_USER" env $sudo_env docker ps -q >/dev/null 2>&1; then
            user_docker_count=$(sudo -u "$SUDO_USER" env $sudo_env docker ps -q | wc -l)
        fi

        if [ "$user_podman_count" -gt 0 ] && [ "$user_docker_count" -eq 0 ]; then
            DOCKER_CMD="sudo -u $SUDO_USER env $sudo_env podman"
            return 0
        fi
        if [ "$user_docker_count" -gt 0 ] && [ "$user_podman_count" -eq 0 ]; then
            DOCKER_CMD="sudo -u $SUDO_USER env $sudo_env docker"
            return 0
        fi

        # 3. Fallback to user commands if no running containers found but binaries exist
        if sudo -u "$SUDO_USER" command -v podman >/dev/null 2>&1 && sudo -u "$SUDO_USER" env $sudo_env podman ps >/dev/null 2>&1; then
            DOCKER_CMD="sudo -u $SUDO_USER env $sudo_env podman"
            return 0
        fi
        if sudo -u "$SUDO_USER" command -v docker >/dev/null 2>&1 && sudo -u "$SUDO_USER" env $sudo_env docker ps >/dev/null 2>&1; then
            DOCKER_CMD="sudo -u $SUDO_USER env $sudo_env docker"
            return 0
        fi
    fi

    # Standard detection (non-sudo or root)
    # 1. Prioritize daemon containing NPM container
    local npm_in_podman=false
    if command -v podman >/dev/null 2>&1 && podman ps -a --format '{{.Image}}' 2>/dev/null | grep -q "nginx-proxy-manager"; then
        npm_in_podman=true
    fi
    local npm_in_docker=false
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Image}}' 2>/dev/null | grep -q "nginx-proxy-manager"; then
        npm_in_docker=true
    fi

    if [ "$npm_in_podman" = true ] && [ "$npm_in_docker" = false ]; then
        DOCKER_CMD="podman"
        return 0
    fi
    if [ "$npm_in_docker" = true ] && [ "$npm_in_podman" = false ]; then
        DOCKER_CMD="docker"
        return 0
    fi

    # 2. Check running container count
    local podman_count=0
    if command -v podman >/dev/null 2>&1 && podman ps -q >/dev/null 2>&1; then
        podman_count=$(podman ps -q | wc -l)
    fi
    local docker_count=0
    if command -v docker >/dev/null 2>&1 && docker ps -q >/dev/null 2>&1; then
        docker_count=$(docker ps -q | wc -l)
    fi

    if [ "$podman_count" -gt 0 ] && [ "$docker_count" -eq 0 ]; then
        DOCKER_CMD="podman"
        return 0
    fi
    if [ "$docker_count" -gt 0 ] && [ "$podman_count" -eq 0 ]; then
        DOCKER_CMD="docker"
        return 0
    fi

    # 3. Default to binaries
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
        DOCKER_CMD="docker"
        return 0
    fi
    if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then
        DOCKER_CMD="podman"
        return 0
    fi
    return 1
}
has_docker() {
    detect_docker_cli
}
detect_host_ip() {
    local ip
    ip=$(ip route get 1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2 || echo "")
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    fi
    echo "${ip:-127.0.0.1}"
}

NPM_PROXY_HOSTS=""
find_npm_container_id() {
    if ! has_docker; then
        echo ""
        return
    fi
    if [ -n "${NPM_CONTAINER_OVERRIDE:-}" ]; then
        npm_cid=$($DOCKER_CMD ps -q -f "name=${NPM_CONTAINER_OVERRIDE}" 2>/dev/null | head -n1)
        [ -z "$npm_cid" ] && npm_cid=$($DOCKER_CMD ps -q -f "id=${NPM_CONTAINER_OVERRIDE}" 2>/dev/null | head -n1)
        [ -z "$npm_cid" ] && npm_cid="$NPM_CONTAINER_OVERRIDE"
    else
        # Try local compose service first if in NPM directory
        npm_cid=$($DOCKER_CMD compose ps -q app 2>/dev/null) || { warn "Could not query compose app service"; npm_cid=""; }
        [ -z "$npm_cid" ] && { npm_cid=$($DOCKER_CMD compose ps -q nginx-proxy-manager 2>/dev/null) || { warn "Could not query compose nginx-proxy-manager service"; npm_cid=""; }; }
        
        # Fallback to scanning all containers
        if [ -z "$npm_cid" ]; then
            npm_cid=$($DOCKER_CMD ps -a --format '{{.ID}}|{{.Image}}' 2>/dev/null | grep "nginx-proxy-manager" | head -n1 | cut -d'|' -f1 || echo "")
        fi
    fi
    echo "$npm_cid"
}

fetch_npm_proxy_hosts() {
    if ! has_docker; then
        if [ -f "./data/database.sqlite" ]; then
            NPM_PROXY_HOSTS=$(python3 -c "import sqlite3; conn = sqlite3.connect('./data/database.sqlite'); cursor = conn.cursor(); cursor.execute('SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;'); [print(f\"{row[0]}|{row[1]}|{row[2]}\") for row in cursor.fetchall()]" 2>/dev/null || true)
            if [ -z "$NPM_PROXY_HOSTS" ]; then
                NPM_PROXY_HOSTS=$(sqlite3 ./data/database.sqlite "SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;" 2>/dev/null || echo "")
            fi
        fi
        return
    fi
    local npm_cid
    npm_cid=$(find_npm_container_id)
    if [ -n "$npm_cid" ]; then
        NPM_PROXY_HOSTS=$($DOCKER_CMD exec "$npm_cid" python3 -c "import sqlite3; conn = sqlite3.connect('/data/database.sqlite'); cursor = conn.cursor(); cursor.execute('SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;'); [print(f\"{row[0]}|{row[1]}|{row[2]}\") for row in cursor.fetchall()]" 2>/dev/null) || NPM_PROXY_HOSTS=""
        if [ -z "$NPM_PROXY_HOSTS" ]; then
            NPM_PROXY_HOSTS=$($DOCKER_CMD exec "$npm_cid" sqlite3 /data/database.sqlite \
                "SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;" 2>/dev/null) || { warn "Failed to query SQLite DB inside container $npm_cid. Check permissions."; NPM_PROXY_HOSTS=""; }
        fi
    fi
    if [ -z "$NPM_PROXY_HOSTS" ] && [ -f "./data/database.sqlite" ]; then
        NPM_PROXY_HOSTS=$(python3 -c "import sqlite3; conn = sqlite3.connect('./data/database.sqlite'); cursor = conn.cursor(); cursor.execute('SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;'); [print(f\"{row[0]}|{row[1]}|{row[2]}\") for row in cursor.fetchall()]" 2>/dev/null) || NPM_PROXY_HOSTS=""
        if [ -z "$NPM_PROXY_HOSTS" ]; then
            NPM_PROXY_HOSTS=$(sqlite3 ./data/database.sqlite "SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;" 2>/dev/null) || { warn "Failed to query local SQLite DB. Check permissions."; NPM_PROXY_HOSTS=""; }
        fi
    fi
}

find_npm_config_for_container() {
    local cname="$1"
    local ips="$2"
    local pub_ports="$3"
    matched_domain=""
    matched_port=""
    matched_fwd_host=""
    matched_access_type=""

    [ -z "$NPM_PROXY_HOSTS" ] && return 1

    local host_ip
    host_ip=$(detect_host_ip)

    while IFS='|' read -r domain_json fwd_host fwd_port; do
        [ -z "$domain_json" ] && continue

        local is_match=false
        local access_type=""

        # 1. Match by container name
        if [ "$fwd_host" = "$cname" ]; then
            is_match=true
            access_type="name"
        # 2. Match by container internal IP
        else
            for ip in $ips; do
                if [ "$fwd_host" = "$ip" ]; then
                    is_match=true
                    access_type="ip"
                    break
                fi
            done
        fi

        # 3. Match by host IP or localhost/0.0.0.0 and published port
        if [ "$is_match" = false ] && [ -n "$pub_ports" ]; then
            if [ "$fwd_host" = "$host_ip" ] || [ "$fwd_host" = "127.0.0.1" ] || [ "$fwd_host" = "localhost" ] || [ "$fwd_host" = "0.0.0.0" ]; then
                for port in $pub_ports; do
                    if [ "$fwd_port" = "$port" ]; then
                        is_match=true
                        access_type="ip"
                        break
                    fi
                done
            fi
        fi

        if [ "$is_match" = true ]; then
            local domains
            domains=$(echo "$domain_json" | tr -d '[]"' | tr ',' ' ' | xargs)
            matched_domain=$(echo "$domains" | awk '{print $1}')
            matched_port="$fwd_port"
            matched_fwd_host="$fwd_host"
            matched_access_type="$access_type"
            return 0
        fi
    done <<< "$NPM_PROXY_HOSTS"
    return 1
}

count_old_snippets() {
    local count=""
    local npm_cid
    npm_cid=$(find_npm_container_id)
    if [ -n "$npm_cid" ] && $DOCKER_CMD exec "$npm_cid" test -f /data/database.sqlite >/dev/null 2>&1; then
        count=$($DOCKER_CMD exec "$npm_cid" python3 -c "import sqlite3; conn = sqlite3.connect('/data/database.sqlite'); cursor = conn.cursor(); cursor.execute(\"SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%';\"); print(cursor.fetchone()[0])" 2>/dev/null) || count=""
        if [ -z "$count" ]; then
            count=$($DOCKER_CMD exec "$npm_cid" sqlite3 /data/database.sqlite \
                "SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%';" 2>/dev/null) || { warn "Failed to query SQLite DB inside container $npm_cid."; count=""; }
        fi
    elif [ -f "./data/database.sqlite" ]; then
        count=$(python3 -c "import sqlite3; conn = sqlite3.connect('./data/database.sqlite'); cursor = conn.cursor(); cursor.execute(\"SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%';\"); print(cursor.fetchone()[0])" 2>/dev/null) || count=""
        if [ -z "$count" ]; then
            count=$(sqlite3 ./data/database.sqlite "SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%';" 2>/dev/null) || { warn "Failed to query local SQLite DB."; count=""; }
        fi
    fi
    echo "$count"
}

clear_old_snippets() {
    local cleaned="0"
    local npm_cid
    npm_cid=$(find_npm_container_id)
    if [ -n "$npm_cid" ] && $DOCKER_CMD exec "$npm_cid" test -f /data/database.sqlite >/dev/null 2>&1; then
        cleaned=$($DOCKER_CMD exec "$npm_cid" python3 -c "import sqlite3; conn = sqlite3.connect('/data/database.sqlite'); cursor = conn.cursor(); cursor.execute(\"UPDATE proxy_host SET advanced_config = '' WHERE advanced_config LIKE '%wakeonrequest%';\"); conn.commit(); print(cursor.rowcount)" 2>/dev/null) || cleaned=""
        if [ -z "$cleaned" ]; then
            cleaned=$($DOCKER_CMD exec "$npm_cid" sqlite3 /data/database.sqlite \
                "UPDATE proxy_host SET advanced_config = '' WHERE advanced_config LIKE '%wakeonrequest%'; SELECT changes();" 2>/dev/null) || { warn "Failed to update SQLite DB inside container $npm_cid."; cleaned="0"; }
        fi
    elif [ -f "./data/database.sqlite" ]; then
        cleaned=$(python3 -c "import sqlite3; conn = sqlite3.connect('./data/database.sqlite'); cursor = conn.cursor(); cursor.execute(\"UPDATE proxy_host SET advanced_config = '' WHERE advanced_config LIKE '%wakeonrequest%';\"); conn.commit(); print(cursor.rowcount)" 2>/dev/null) || cleaned=""
        if [ -z "$cleaned" ]; then
            cleaned=$(sqlite3 ./data/database.sqlite "UPDATE proxy_host SET advanced_config = '' WHERE advanced_config LIKE '%wakeonrequest%'; SELECT changes();" 2>/dev/null) || { warn "Failed to update local SQLite DB."; cleaned="0"; }
        fi
    else
        cleaned=""
    fi
    echo "$cleaned"
}

# ── Docker Environment Scan ────────────────────────────────────────────────────
scan_docker_environment() {
    section "Environment Scan"

    if ! has_docker; then
        warn "Docker socket or daemon not accessible — skipping environment scan."
        return
    fi

    ok "Environment scan complete."
}

resolve_compose_file() {
    local compose_file="$1"
    local working_dir="$2"
    local mounts="$3"

    local c_file="${compose_file:-}"
    
    # If c_file is relative, and working_dir is set, combine them
    if [ -n "$c_file" ] && [ -n "$working_dir" ]; then
        if [[ ! "$c_file" =~ ^/ ]] && [[ ! "$c_file" =~ ^[a-zA-Z]: ]]; then
            c_file="${working_dir}/${c_file}"
        fi
    fi

    # Convert Windows to WSL if needed
    if [ -n "$c_file" ]; then
        c_file="${c_file//\\//}"
        if [[ "$c_file" =~ ^[a-zA-Z]:/ ]]; then
            c_file=$(wslpath -u "$c_file" 2>/dev/null || echo "$c_file")
        fi
    fi

    # If it exists, return it
    if [ -n "$c_file" ] && [ -f "$c_file" ]; then
        echo "$c_file"
        return
    fi

    # Try searching common names if not absolute
    local search_names="docker-compose.yml docker-compose.yaml compose.yml compose.yaml"
    if [ -n "$compose_file" ] && [[ ! "$compose_file" =~ ^/ ]] && [[ ! "$compose_file" =~ ^[a-zA-Z]: ]]; then
        search_names="$compose_file $search_names"
    fi

    # Try working_dir
    if [ -n "$working_dir" ]; then
        local wdir="${working_dir//\\//}"
        if [[ "$wdir" =~ ^[a-zA-Z]:/ ]]; then
            wdir=$(wslpath -u "$wdir" 2>/dev/null || echo "$wdir")
        fi
        for name in $search_names; do
            if [ -f "${wdir}/${name}" ]; then
                echo "${wdir}/${name}"
                return
            fi
        done
    fi

    # Try mounts
    if [ -n "$mounts" ]; then
        IFS='?' read -r -a mounts_array <<< "$mounts"
        for mnt in "${mounts_array[@]}"; do
            [ -z "$mnt" ] && continue
            
            # Skip docker volumes
            if [[ "$mnt" =~ /var/lib/docker/volumes ]] || [[ "$mnt" =~ /containers/storage/volumes ]]; then
                continue
            fi

            local mnt_wsl="${mnt//\\//}"
            if [[ "$mnt_wsl" =~ ^[a-zA-Z]:/ ]]; then
                mnt_wsl=$(wslpath -u "$mnt_wsl" 2>/dev/null || echo "$mnt_wsl")
            fi

            # Start from the mount path and go up to 3 parent directories
            local curr="$mnt_wsl"
            if [ -f "$curr" ]; then
                curr=$(dirname "$curr")
            fi

            local depth=0
            while [ -n "$curr" ] && [ "$curr" != "/" ] && [ "$curr" != "." ] && [ $depth -lt 4 ]; do
                for name in $search_names; do
                    if [ -f "${curr}/${name}" ]; then
                        echo "${curr}/${name}"
                        return
                    fi
                done
                curr=$(dirname "$curr")
                depth=$((depth + 1))
            done
        done
    fi

    # If nothing found, return original but translated
    local fallback="$compose_file"
    if [ -n "$fallback" ]; then
        fallback="${fallback//\\//}"
        if [[ "$fallback" =~ ^[a-zA-Z]:/ ]]; then
            fallback=$(wslpath -u "$fallback" 2>/dev/null || echo "$fallback")
        fi
    fi
    echo "$fallback"
}

# ── Python-based container inspector ─────────────────────────────────────────
# Calls `docker inspect <id>` for a single container and uses Python's stdlib
# json module to extract all needed fields into a safe, pipe-delimited record.
# Never uses --format Go templates, so it handles any value (ports, labels, paths)
# without the multi-line bleeding bug.
# Output: name|status|restart|netmode|enabled|domain|idle|start|port_label|
#         config_files|working_dir|svc_name|network_ids|exposed_ports|
#         published_ports|ips|long_id|mounts
inspect_container_python() {
    local cid="$1"
    $DOCKER_CMD inspect "$cid" 2>/dev/null | python3 - <<'PYEOF'
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if not data:
    sys.exit(0)

c = data[0]
labels = c.get("Config", {}).get("Labels") or {}
net_settings = c.get("NetworkSettings", {})
networks = net_settings.get("Networks") or {}
ports_map = net_settings.get("Ports") or {}
mounts = c.get("Mounts") or []
hostconfig = c.get("HostConfig", {})

name       = c.get("Name", "").lstrip("/")
status     = c.get("State", {}).get("Status", "")
restart    = hostconfig.get("RestartPolicy", {}).get("Name", "")
netmode    = hostconfig.get("NetworkMode", "")
enabled    = labels.get("wakeonrequest.enable", "")
domain     = labels.get("wakeonrequest.domain", "")
idle       = labels.get("wakeonrequest.idle_timeout", "")
start      = labels.get("wakeonrequest.start_timeout", "")
port_label = labels.get("wakeonrequest.port", "")
config_f   = labels.get("com.docker.compose.project.config_files", "")
working_d  = labels.get("com.docker.compose.project.working_dir", "")
svc_name   = labels.get("com.docker.compose.service", "")
long_id    = c.get("Id", "")

net_ids = " ".join(v.get("NetworkID", "") for v in networks.values())
ips     = " ".join(v.get("IPAddress", "") for v in networks.values())

# Ports: exposed = keys of ports_map; published = host ports from bindings
exposed    = " ".join(k for k in ports_map)
published  = " ".join(
    b["HostPort"]
    for bindings in ports_map.values()
    if bindings
    for b in bindings
    if b and b.get("HostPort")
)

# Mounts: bind-mounts only (skip anonymous volumes)
mount_sources = "?".join(
    m.get("Source", "")
    for m in mounts
    if m.get("Source")
)

fields = [name, status, restart, netmode, enabled, domain, idle, start,
          port_label, config_f, working_d, svc_name, net_ids, exposed,
          published, ips, long_id, mount_sources]

# Replace any embedded | with ▒ to keep the record safe
print("|".join(f.replace("|", "▒") for f in fields))
PYEOF
}

parse_container_details() {
    local details="$1"
    local npm_id="$2"
    local npm_networks="$3"

    IFS='|' read -r cname state restart network enabled domain idle start port_label compose_file working_dir svc_name networks exposed_ports published_ports ips long_id mounts <<< "$details"

    local is_npm=false
    if [ -n "$npm_id" ]; then
        if [ "$long_id" = "$npm_id" ] || [ "${long_id:0:12}" = "$npm_id" ] || [ "$cname" = "/$npm_id" ]; then
            is_npm=true
        fi
    fi
    [ "$is_npm" = true ] && return 1

    compose_path=$(resolve_compose_file "$compose_file" "$working_dir" "$mounts")
    exposed_ports=$(echo "$exposed_ports" | xargs)
    published_ports=$(echo "$published_ports" | xargs)
    ips=$(echo "$ips" | xargs)

    local exp_count pub_count
    exp_count=$(echo "$exposed_ports" | wc -w)
    pub_count=$(echo "$published_ports" | wc -w)

    single_exposed=""
    [ "$exp_count" -eq 1 ] && single_exposed="${exposed_ports%%/*}"

    single_published=""
    [ "$pub_count" -eq 1 ] && single_published="${published_ports}"

    matched_domain=""
    matched_port=""
    matched_fwd_host=""
    matched_access_type=""
    find_npm_config_for_container "$cname" "$ips" "$published_ports" || true

    detected_port=""
    port_source=""
    if [ -n "$port_label" ]; then
        detected_port="$port_label"; port_source="from label"
    elif [ -n "$matched_port" ]; then
        detected_port="$matched_port"; port_source="from NPM database"
    elif [ -n "$single_exposed" ]; then
        detected_port="$single_exposed"; port_source="auto-detected"
    elif [ -n "$single_published" ]; then
        detected_port="$single_published"; port_source="published port"
    fi

    shares_network=false
    for net in $npm_networks; do
        for cnet in $networks; do
            if [ "$net" = "$cnet" ]; then
                shares_network=true
                break 2
            fi
        done
    done

    fwd_host=""
    fwd_note=""
    if [ -n "$matched_fwd_host" ]; then
        fwd_host="$matched_fwd_host"
        if [ "$matched_access_type" = "name" ]; then
            fwd_note="NPM database config — accesses via container name"
            port_source="from NPM database"
        else
            fwd_note="NPM database config — accesses via IP"
            port_source="from NPM database"
        fi
    elif [ "$network" = "host" ]; then
        fwd_host=$(detect_host_ip)
        fwd_note="host network — NPM cannot route by name"
    elif [ "$shares_network" = "true" ]; then
        fwd_host="$cname"
        fwd_note="same network as NPM — use container name"
    else
        fwd_host=$(detect_host_ip)
        fwd_note="different network from NPM — use host IP"
    fi

    restart_needed=false
    if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
        restart_needed=true
    fi

    return 0
}

# ──────────────────────────────────────────────────────
# server_proxy.conf is not hosted on GitHub — it is embedded here instead.
# Called by both run_dry_run (for missing files) and run_install (as fallback).
write_bundled_files() {
    local target="npm-custom/server_proxy.conf"
    if [ -f "$target" ]; then
        backup_file "$target"
    fi
    mkdir -p npm-custom
    cat > "$target" << 'EOF'
# ── Wake-On-Request: Global Interceptor ──────────────────────────────────────
# Injected into every NPM proxy-host server block via server_proxy.conf.
# Calls global_wake() which looks up the request host in the shared dict
# (populated from Docker labels) and starts the matching container if needed.
# No per-host NPM Advanced Tab configuration required.
access_by_lua_block {
    require("wakeonrequest").global_wake()
}
EOF
}

# ── Dry Run ────────────────────────────────────────────────────────────────────
run_dry_run() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Wake-On-Request — Dry Run Preview${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "  Directory: $(pwd)\n"

    local any_change=false

    # ── Files ─────────────────────────────────────────────────────────────────
    section "Files"
    for entry in "${FILES[@]}"; do
        local local_path="${entry%%:*}"
        local remote_file="$(basename "$local_path")"
        if [ ! -f "$local_path" ]; then
            if [ "$local_path" = "npm-custom/server_proxy.conf" ]; then
                change "Write     $local_path   ← bundled in install.sh"
            else
                change "Download  $local_path   ← $RAW_BASE/$remote_file"
            fi
            any_change=true
        else
            ok "Exists    $local_path"
        fi
    done

    # ── docker-compose.yml volumes ────────────────────────────────────────────
    section "docker-compose.yml — Volume Changes"
    local compose_clean=true
    for entry in "${FILES[@]}"; do
        local local_path="${entry%%:*}"
        local container_path="${entry##*:}"
        local vol="./${local_path}:${container_path}"
        if ! grep -qF "$vol" docker-compose.yml; then
            change "ADD  - ${vol}"
            compose_clean=false
            any_change=true
        else
            ok "OK   - ${vol}"
        fi
    done
    if ! grep -qF "$VOL_SOCK" docker-compose.yml; then
        change "ADD  - ${VOL_SOCK}"
        compose_clean=false
        any_change=true
    else
        ok "OK   - ${VOL_SOCK}"
    fi

    if [ "$compose_clean" = false ]; then
        echo ""
        info "These lines will be inserted under your NPM service's 'volumes:' block."
    fi

    # ── Container label status ────────────────────────────────────────────────
    section "Container Label Status"
    if has_docker; then
        fetch_npm_proxy_hosts
        local npm_id npm_networks
        
        # Find NPM container
        npm_id=$(find_npm_container_id)

        if [ -n "$npm_id" ]; then
            npm_networks=$($DOCKER_CMD inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' "$npm_id" 2>/dev/null || true)
        fi

        while IFS= read -r cid || [ -n "$cid" ]; do
                [ -z "$cid" ] && continue
                local details
                details=$(inspect_container_python "$cid")
                [ -z "$details" ] && continue

                parse_container_details "$details" "$npm_id" "$npm_networks" || continue

                # ── Already configured ─────────────────────────────────────
                if [ "$enabled" = "true" ] && [ -n "$domain" ]; then
                    idle="${idle:-300}"
                    start="${start:-30}"
                    if [ "$restart_needed" = true ]; then
                        warn "${BOLD}$cname${NC}${YELLOW}  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
                        err "      restart: \"$restart\" prevents idle stop → must be changed to \"no\" manually in docker-compose.yml"
                    else
                        ok "${BOLD}$cname${NC}${GREEN}  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
                    fi
                    continue
                fi

                if [ "$enabled" = "true" ] && [ -z "$domain" ]; then
                    warn "${BOLD}$cname${NC}${YELLOW}  →  wakeonrequest.enable=true but MISSING wakeonrequest.domain label!"
                    continue
                fi

                # ── Not yet configured — detect everything ─────────────────
                [ -z "$fwd_port" ] && fwd_port="<port>"

                # ── Print tailored block ──────────────────────────────────────────
                local status_tag="state: $state | restart: $restart"
                [ "$network" = "host" ] && status_tag="$status_tag | network: host"

                echo -e "  ${YELLOW}➕ ${BOLD}$cname${NC}  [$status_tag]"

                if [ "$restart_needed" = "true" ]; then
                    err "restart: \"$restart\" prevents idle stop → must be changed to \"no\""
                fi

                echo ""
                echo -e "     ${BOLD}── NPM Proxy Host settings ──${NC}"
                echo -e "     Forward Host : ${GREEN}$fwd_host${NC}"
                if [ -n "$fwd_port" ] && [ "$fwd_port" != "<port>" ]; then
                    echo -e "     Forward Port : ${GREEN}$fwd_port${NC}  ${BLUE}($port_source)${NC}"
                else
                    echo -e "     Forward Port : ${YELLOW}<set manually>${NC}  ${BLUE}(could not auto-detect)${NC}"
                fi
                echo -e "     Note         : ${BLUE}$fwd_note${NC}"

                echo ""
                local label_domain="<your-domain.example.com>"
                if [ -n "$matched_domain" ]; then
                    label_domain="$matched_domain"
                elif [ -n "$domain" ]; then
                    label_domain="$domain"
                fi

                local ip_labels=""
                if [[ "$fwd_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    ip_labels="     ${GREEN}  - \"wakeonrequest.probe_host=${fwd_host}\"${NC}\n     ${GREEN}  - \"wakeonrequest.port=${fwd_port}\"${NC}"
                fi

                if [ -n "$compose_path" ] && [ -f "$compose_path" ]; then
                    if grep -qF "wakeonrequest.enable" "$compose_path"; then
                        ok "Compose File : ${GREEN}Already configured${NC} in ${BLUE}$compose_path${NC}"
                    else
                        change "Compose File : ${YELLOW}Will patch${NC} at ${BLUE}$compose_path${NC}"
                        echo ""
                        echo -e "     ${BOLD}── Proposed changes for $compose_path (Method A) ──${NC}"
                        echo ""
                        if [ "$restart_needed" = "true" ]; then
                            echo -e "     ${YELLOW}restart: \"no\"${NC}                                  ${BLUE}# change from: $restart${NC}"
                        fi
                        echo -e "     ${GREEN}labels:${NC}"
                        echo -e "     ${GREEN}  - \"wakeonrequest.enable=true\"${NC}"
                        echo -e "     ${GREEN}  - \"wakeonrequest.domain=${label_domain}\"${NC}  ${BLUE}# ← your NPM domain${NC}"
                        echo -e "     ${GREEN}  - \"wakeonrequest.idle_timeout=300\"${NC}                  ${BLUE}# stop after 5 min idle${NC}"
                        echo -e "     ${GREEN}  - \"wakeonrequest.start_timeout=30\"${NC}                  ${BLUE}# wait up to 30s on wake${NC}"
                        if [ -n "$ip_labels" ]; then
                            echo -e "$ip_labels"
                        fi
                        echo ""
                    fi
                else
                    warn "Compose File : ${RED}Not found${NC} (checked: ${YELLOW}${compose_path:-none}${NC})"
                    echo ""
                    echo -e "     ${BOLD}── Add to $cname's docker-compose.yml manually (Method A) ──${NC}"
                    echo ""
                    if [ "$restart_needed" = "true" ]; then
                        echo -e "     ${YELLOW}restart: \"no\"${NC}                                  ${BLUE}# change from: $restart${NC}"
                    fi
                    echo -e "     ${GREEN}labels:${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.enable=true\"${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.domain=${label_domain}\"${NC}  ${BLUE}# ← your NPM domain${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.idle_timeout=300\"${NC}                  ${BLUE}# stop after 5 min idle${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.start_timeout=30\"${NC}                  ${BLUE}# wait up to 30s on wake${NC}"
                    if [ -n "$ip_labels" ]; then
                        echo -e "$ip_labels"
                    fi
                    echo ""
                fi

                # ── NPM Advanced Tab Config (Method B) ──
                echo -e "     ${BOLD}── NPM Advanced Tab Config (Method B) ──${NC}"
                echo ""
                echo -e "     ${GREEN}set \$wake_container     \"${cname}\";${NC}"
                echo -e "     ${GREEN}set \$wake_idle_timeout  300;${NC}"
                echo -e "     ${GREEN}set \$wake_start_timeout 30;${NC}"
                if [[ "$fwd_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "     ${GREEN}set \$wake_probe_host    \"${fwd_host}\";${NC}       ${BLUE}# cross-network probe IP${NC}"
                    echo -e "     ${GREEN}set \$wake_port          ${fwd_port:-80};${NC}    ${BLUE}# cross-network probe port${NC}"
                fi
                echo ""
        done < <($DOCKER_CMD ps -a -q 2>/dev/null)
    else
        warn "Docker socket or daemon not available — skipping container scan."
    fi

    # ── NPM Database Status ───────────────────────────────────────────────────
    section "NPM Database Status"
    local count
    count=$(count_old_snippets)
    if [ -n "$count" ]; then
        if [ "$count" -gt 0 ] 2>/dev/null; then
            change "NPM Database: Will clear old Lua snippets from $count proxy host(s) in Advanced tab."
        else
            ok "NPM Database: No old Lua snippets to clean."
        fi
    else
        info "No NPM database found or accessible — skipping database check."
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    if [ "$any_change" = true ]; then
        echo -e "  ${YELLOW}${BOLD}Changes pending. To apply, run:${NC}"
        echo -e "  ${BOLD}  ./install.sh${NC}"
        echo ""
        echo -e "  ${BLUE}Running without --dry-run will:${NC}"
        echo -e "  ${BLUE}  • Download any missing files from GitHub${NC}"
        echo -e "  ${BLUE}  • Write npm-custom/server_proxy.conf (bundled in this script)${NC}"
        echo -e "  ${BLUE}  • Add the missing volume mounts to docker-compose.yml${NC}"
        echo -e "  ${BLUE}  • Back up docker-compose.yml before editing it${NC}"
    else
        echo -e "  ${GREEN}✨ Already up to date. No changes needed.${NC}"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}\n"
    exit 0
}

# ── Interactive App Container Configuration ────────────────────────────────────
# For each unmanaged container: detect its compose file, ask the user whether
# to patch it, prompt for the domain, then write only the wakeonrequest labels.
# Never touches restart policy — just warns if it needs changing.
configure_app_containers() {
    if ! has_docker; then
        warn "Docker socket or daemon not available — skipping app container setup."
        return
    fi

    section "App Container Setup"

    fetch_npm_proxy_hosts

    local npm_id npm_networks

    # Find NPM container
    npm_id=$(find_npm_container_id)

    if [ -n "$npm_id" ]; then
        npm_networks=$($DOCKER_CMD inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' "$npm_id" 2>/dev/null || true)
    fi

    local any_unmanaged=false

    while IFS= read -r cid || [ -n "$cid" ]; do
            [ -z "$cid" ] && continue
            local details
            details=$(inspect_container_python "$cid")
            [ -z "$details" ] && continue

            # Parse fields (clean pipe-delimited output from Python)
            local cname state restart network enabled domain idle start port_label compose_file working_dir svc_name networks exposed_ports published_ports ips long_id mounts
            IFS='|' read -r cname state restart network enabled domain idle start port_label compose_file working_dir svc_name networks exposed_ports published_ports ips long_id mounts <<< "$details"

            local is_npm=false
            if [ -n "$npm_id" ]; then
                if [ "$long_id" = "$npm_id" ] || [ "${long_id:0:12}" = "$npm_id" ] || [ "$cname" = "/$npm_id" ]; then
                    is_npm=true
                fi
            fi
            [ "$is_npm" = true ] && continue

            # No <no value> cleanup needed — Python returns empty strings

            local compose_path
            compose_path=$(resolve_compose_file "$compose_file" "$working_dir" "$mounts")

            # Trim whitespace
            exposed_ports=$(echo "$exposed_ports" | xargs)
            published_ports=$(echo "$published_ports" | xargs)
            ips=$(echo "$ips" | xargs)

            # Skip already-configured containers
            if [ "$enabled" = "true" ] && [ -n "$domain" ]; then
                idle="${idle:-300}"
                start="${start:-30}"
                if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
                    warn "${BOLD}$cname${NC}${YELLOW}  already configured  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
                    err "      restart: \"$restart\" must be changed to \"no\" manually in docker-compose.yml"
                else
                    ok "${BOLD}$cname${NC}${GREEN}  already configured  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
                fi
                continue
            fi

            any_unmanaged=true

            # Count exposed/published ports
            local exp_count pub_count
            exp_count=$(echo "$exposed_ports" | wc -w)
            pub_count=$(echo "$published_ports" | wc -w)

            local single_exposed=""
            [ "$exp_count" -eq 1 ] && single_exposed="${exposed_ports%%/*}"

            local single_published=""
            [ "$pub_count" -eq 1 ] && single_published="${published_ports}"

            local detected_port="" port_source=""

        local user_domain=""
        local default_domain=""
        local default_port=""
        
        # 1. Search in NPM SQLite database
        local matched_domain="" matched_port="" matched_fwd_host="" matched_access_type=""
        find_npm_config_for_container "$cname" "$ips" "$published_ports" || true
        
        if [ -n "$matched_domain" ]; then
            default_domain="$matched_domain"
            default_port="$matched_port"
            port_source="from NPM database"
        elif [ -n "$domain" ]; then
            default_domain="$domain"
            default_port="$port_label"
            port_source="from existing labels"
        else
            # Fallback to standard exposed/published port detection
            if [ -n "$single_exposed" ]; then
                default_port="$single_exposed"
                port_source="auto-detected"
            elif [ -n "$single_published" ]; then
                default_port="$single_published"
                port_source="published port"
            else
                default_port=""
                port_source=""
            fi
        fi

        # Determine if this container shares a network with NPM
        local shares_network=false
        for net in $npm_networks; do
            for cnet in $networks; do
                if [ "$net" = "$cnet" ]; then
                    shares_network=true
                    break 2
                fi
            done
        done

        # Decide Forward Host recommendation
        local fwd_host
        if [ -n "$matched_fwd_host" ]; then
            fwd_host="$matched_fwd_host"
        elif [ "$network" = "host" ]; then
            fwd_host=$(detect_host_ip)
        elif [ "$shares_network" = "true" ]; then
            fwd_host="$cname"
        else
            fwd_host=$(detect_host_ip)
        fi

        # ── Print container summary ───────────────────────────────────────────
        echo ""
        echo -e "  ${YELLOW}➕ ${BOLD}$cname${NC}  [state: $state | restart: $restart]"
        if [ -n "$default_domain" ]; then
            echo -e "     NPM Domain       : ${GREEN}$default_domain${NC}  ${BLUE}($port_source)${NC}"
        fi
        echo -e "     NPM Forward Host : ${GREEN}$fwd_host${NC}"
        if [ -n "$matched_fwd_host" ]; then
            if [ "$matched_access_type" = "name" ]; then
                echo -e "     Forward Note     : ${BLUE}accesses via container name (from NPM database)${NC}"
            else
                echo -e "     Forward Note     : ${BLUE}accesses via IP (from NPM database)${NC}"
            fi
        fi
        if [ -n "$default_port" ] && [ "$default_port" != "<port>" ]; then
            echo -e "     NPM Forward Port : ${GREEN}$default_port${NC}  ${BLUE}($port_source)${NC}"
        else
            echo -e "     NPM Forward Port : ${YELLOW}<set manually>${NC}"
        fi
        if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
            echo -e "     ${RED}❌ restart: \"$restart\" must be changed to \"no\" manually${NC}"
            echo -e "        ${BLUE}(wake-on-request cannot stop containers with auto-restart)${NC}"
        fi

        # ── Ask configuration method ──────────────────────────────────────────
        echo ""
        echo -e "     Choose configuration method for ${BOLD}$cname${NC}:"
        echo -e "       [1] Use Docker Labels (Method A — Recommended)"
        echo -e "       [2] Use NPM Advanced Tab (Method B)"
        echo -e "       [3] Skip this container"
        echo ""
        printf "     Enter option [1-3] (default: 1): "
        
        local answer=""
        if [ -t 0 ] && [ -c /dev/tty ]; then
            read -r answer </dev/tty || answer="3"
        else
            read -r answer || answer="3"
        fi
        [ -z "$answer" ] && answer="1"

        if [ "$answer" = "3" ]; then
            info "Skipped $cname"
            continue
        elif [ "$answer" = "2" ]; then
            local method="B"
        else
            local method="A"
        fi

        # ── Resolve domain ────────────────────────────────────────────────────
        if [ -n "$default_domain" ]; then
            user_domain="$default_domain"
        else
            while [ -z "$user_domain" ]; do
                printf "     NPM domain for %s (e.g. app.example.com): " "$cname"
                if [ -t 0 ] && [ -c /dev/tty ]; then
                    read -r user_domain </dev/tty || user_domain=""
                else
                    read -r user_domain || user_domain=""
                fi
                user_domain="${user_domain// /}"   # strip accidental spaces
            done
        fi

        # ── Prompt for idle timeout ───────────────────────────────────────────
        local user_idle=""
        printf "     Idle timeout in seconds [300]: "
        if [ -t 0 ] && [ -c /dev/tty ]; then
            read -r user_idle </dev/tty || user_idle=""
        else
            read -r user_idle || user_idle=""
        fi
        user_idle="${user_idle// /}"
        [ -z "$user_idle" ] && user_idle="300"

        # ── Prompt for start timeout ──────────────────────────────────────────
        local user_start=""
        printf "     Start timeout in seconds [30]: "
        if [ -t 0 ] && [ -c /dev/tty ]; then
            read -r user_start </dev/tty || user_start=""
        else
            read -r user_start || user_start=""
        fi
        user_start="${user_start// /}"
        [ -z "$user_start" ] && user_start="30"

        # ── Build the proposed additions/changes ──────────────────────────────
        local label_block append_content ip_labels_text
        label_block="      labels:\n\
        - \"wakeonrequest.enable=true\"\n\
        - \"wakeonrequest.domain=${user_domain}\"\n\
        - \"wakeonrequest.idle_timeout=${user_idle}\"\n\
        - \"wakeonrequest.start_timeout=${user_start}\""

        append_content="        - \"wakeonrequest.enable=true\"\n        - \"wakeonrequest.domain=${user_domain}\"\n        - \"wakeonrequest.idle_timeout=${user_idle}\"\n        - \"wakeonrequest.start_timeout=${user_start}\""

        ip_labels_text=""
        if [[ "$fwd_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            label_block="${label_block}\n\
        - \"wakeonrequest.probe_host=${fwd_host}\"\n\
        - \"wakeonrequest.port=${default_port:-80}\""
            append_content="${append_content}\n        - \"wakeonrequest.probe_host=${fwd_host}\"\n        - \"wakeonrequest.port=${default_port:-80}\""
            ip_labels_text="     ${GREEN}    - \"wakeonrequest.probe_host=${fwd_host}\"${NC}\n     ${GREEN}    - \"wakeonrequest.port=${default_port:-80}\"${NC}"
        fi

        # ── Show Proposed Changes ─────────────────────────────────────────────
        echo ""
        if [ "$method" = "B" ]; then
            info "Paste this configuration snippet into Nginx Proxy Manager's Advanced Tab for ${BOLD}${user_domain}${NC}:"
            echo ""
            echo -e "     ${GREEN}set \$wake_container     \"${cname}\";${NC}"
            echo -e "     ${GREEN}set \$wake_idle_timeout  ${user_idle};${NC}"
            echo -e "     ${GREEN}set \$wake_start_timeout ${user_start};${NC}"
            if [[ "$fwd_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "     ${GREEN}set \$wake_probe_host    \"${fwd_host}\";${NC}       ${BLUE}# cross-network probe IP${NC}"
                echo -e "     ${GREEN}set \$wake_port          ${default_port:-80};${NC}    ${BLUE}# cross-network probe port${NC}"
            fi
            echo ""
            if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
                warn "Remember to change restart to \"no\" manually for $cname if needed"
            fi
            continue
        fi

        if [ -n "$compose_path" ] && [ -f "$compose_path" ]; then
            info "Proposed changes for $compose_path:"
            echo ""
            if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
                echo -e "     ${YELLOW}restart: \"no\"${NC}                                  ${BLUE}# change from: $restart${NC}"
            fi
            if grep -qF "wakeonrequest.enable" "$compose_path"; then
                warn "wakeonrequest labels already present in $compose_path — this will skip writing."
            elif grep -A50 "${svc_name}:" "$compose_path" | grep -qE "^[[:space:]]+labels:"; then
                echo -e "     ${GREEN}labels: (append to existing block)${NC}"
                echo -e "     ${GREEN}${append_content}${NC}"
            else
                echo -e "     ${GREEN}${label_block}${NC}"
            fi
            echo ""

            # Safety check: only patch if we can find the service name in the file
            if [ -z "$svc_name" ] || ! grep -qF "${svc_name}:" "$compose_path"; then
                warn "Cannot safely locate service '${svc_name}' in $compose_path — showing manual snippet instead."
            else
                printf "     Apply these changes to %s? [Y/n] " "$compose_path"
                local apply_ans
                read -r apply_ans </dev/tty
                if [ -z "$apply_ans" ]; then
                    apply_ans="y"
                fi
                if [[ ! "$apply_ans" =~ ^[Yy]$ ]]; then
                    info "Skipped writing to $compose_path"
                    continue
                fi

                # ── Apply changes ──────────────────────────────────────────────────
                if grep -qF "wakeonrequest.enable" "$compose_path"; then
                    warn "wakeonrequest labels already present in $compose_path — skipping write."
                else
                    backup_file "$compose_path"
                    local patch_mode="insert"
                    local patch_content="$label_block"
                    if grep -A50 "^[[:space:]]*${svc_name}:" "$compose_path" | grep -qE "^[[:space:]]+labels:"; then
                        patch_mode="append"
                        patch_content="$append_content"
                    fi

                    python3 - "$compose_path" "$svc_name" "$patch_content" "$patch_mode" << 'PYEOF'
import sys, re

c_path, svc, content, mode = sys.argv[1:5]
content_lines = content.split(r"\n")

with open(c_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
in_svc = False
patched = False

for line in lines:
    out.append(line)
    if patched:
        continue
        
    line_clean = line.rstrip("\r\n")
    if re.match(r"^\s*" + re.escape(svc) + r":\s*$", line_clean):
        in_svc = True
        if mode == "insert":
            for cl in content_lines:
                out.append(cl + ("\r\n" if line.endswith("\r\n") else "\n"))
            patched = True
            in_svc = False
        continue
        
    if in_svc and mode == "append":
        if re.match(r"^\s*labels:\s*", line_clean):
            for cl in content_lines:
                out.append(cl + ("\r\n" if line.endswith("\r\n") else "\n"))
            patched = True
            in_svc = False

with open(c_path, "w", encoding="utf-8", newline="") as f:
    f.writelines(out)
PYEOF
                    if [ "$patch_mode" = "append" ]; then
                        ok "Labels appended to existing labels: block in $compose_path"
                    else
                        ok "Labels added to $compose_path"
                    fi
                fi

                if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
                    echo ""
                    warn "Remember to change restart to \"no\" in $compose_path"
                    warn "Then run: docker compose up -d --force-recreate $cname"
                else
                    echo ""
                    info "Apply with: docker compose up -d --force-recreate $cname"
                fi
                continue
            fi
        else
            if [ -n "$compose_path" ]; then
                warn "Compose file not accessible at: $compose_path"
            else
                warn "No compose file found for $cname (may have been started with docker run)"
            fi
        fi

        # ── Fallback: print the snippet to add manually ───────────────────────
        echo ""
        echo -e "     ${BOLD}Add this to ${cname}'s docker-compose.yml manually:${NC}"
        echo ""
        if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
            echo -e "     ${YELLOW}  restart: \"no\"${NC}  ${BLUE}# change from: $restart${NC}"
        fi
        echo -e "     ${GREEN}  labels:${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.enable=true\"${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.domain=${user_domain}\"${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.idle_timeout=${user_idle}\"${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.start_timeout=${user_start}\"${NC}"
        if [ -n "$ip_labels_text" ]; then
            echo -e "$ip_labels_text"
        fi
        echo ""
        info "Then run: docker compose up -d --force-recreate $cname"

    done < <($DOCKER_CMD ps -a -q 2>/dev/null)

    if [ "$any_unmanaged" = false ]; then
        ok "All containers are already configured."
    fi
}

# ── Installation ───────────────────────────────────────────────────────────────
run_install() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Wake-On-Request Installer${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "  Directory: $(pwd)\n"

    # ── Download files from repo (server_proxy.conf is bundled, not downloaded) ──
    section "Downloading Files"
    mkdir -p npm-custom

    # Write bundled files first (no network needed)
    write_bundled_files

    for entry in "${FILES[@]}"; do
        local local_path="${entry%%:*}"
        local remote_file="$(basename "$local_path")"
        local url="$RAW_BASE/$remote_file"

        # server_proxy.conf is embedded — skip curl for it
        if [ "$local_path" = "npm-custom/server_proxy.conf" ]; then
            ok "Bundled   $local_path (no download needed)"
            continue
        fi

        backup_file "$local_path"
        echo -ne "  Downloading ${BOLD}$local_path${NC} ... "
        if curl -fsSL "$url" > "${local_path}.tmp"; then
            mv "${local_path}.tmp" "$local_path"
            echo -e "${GREEN}done${NC}"
        else
            rm -f "${local_path}.tmp"
            echo -e "${RED}FAILED${NC}"
            err "Could not download $url"
            err "Check your internet connection or download manually:"
            err "  curl -L $url -o $local_path"
            exit 1
        fi
    done
    ok "All files ready."

    # ── Patch docker-compose.yml ───────────────────────────────────────────────
    section "Patching docker-compose.yml"
    local missing=false
    for entry in "${FILES[@]}"; do
        local local_path="${entry%%:*}"
        local container_path="${entry##*:}"
        grep -qF "./${local_path}:${container_path}" docker-compose.yml || missing=true
    done
    grep -qF "$VOL_SOCK" docker-compose.yml || missing=true

    if [ "$missing" = true ]; then
        # Validate YAML before touching it
        local parse_ok=true
        if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
            python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))" 2>/dev/null \
                || { warn "docker-compose.yml is not valid YAML — skipping auto-patch."; parse_ok=false; }
        fi

        local vol_count
        vol_count=$(grep -cE "^[[:space:]]+volumes:" docker-compose.yml || echo 0)

        if [ "$parse_ok" = false ] || [ "$vol_count" -gt 1 ]; then
            warn "Complex docker-compose.yml detected — showing manual instructions:"
            echo ""
            echo -e "  Add these under your NPM service's ${YELLOW}volumes:${NC} block:"
            for entry in "${FILES[@]}"; do
                local local_path="${entry%%:*}"
                local container_path="${entry##*:}"
                local vol="./${local_path}:${container_path}"
                grep -qF "$vol" docker-compose.yml || echo "      - $vol"
            done
            grep -qF "$VOL_SOCK" docker-compose.yml || echo "      - $VOL_SOCK"
        else
            backup_file "docker-compose.yml"
            for entry in "${FILES[@]}"; do
                local local_path="${entry%%:*}"
                local container_path="${entry##*:}"
                local vol="./${local_path}:${container_path}"
                grep -qF "$vol" docker-compose.yml \
                    || sed -i "/^[[:space:]]\{2,\}volumes:/a \\      - $vol" docker-compose.yml
            done
            grep -qF "$VOL_SOCK" docker-compose.yml \
                || sed -i "/^[[:space:]]\{2,\}volumes:/a \\      - $VOL_SOCK" docker-compose.yml
            ok "docker-compose.yml patched."
        fi
    else
        ok "docker-compose.yml already configured — no changes needed."
    fi

    # ── Clean up old NPM database snippets ────────────────────────────────────
    section "Cleaning NPM Database"
    local cleaned
    cleaned=$(clear_old_snippets)
    if [ -n "$cleaned" ]; then
        if [ "$cleaned" != "0" ] && [ -n "$cleaned" ]; then
            ok "Cleared old Lua snippets from $cleaned proxy host(s)."
        else
            ok "No old snippets found — nothing to clean."
        fi
    else
        info "No NPM database found or accessible — skipping cleanup."
    fi

    # ── Configure App Containers ──────────────────────────────────────────────
    if [ -t 0 ] && [ -t 1 ]; then
        configure_app_containers
    else
        info "Non-interactive environment detected — skipping interactive app configuration."
    fi

    # ── Next Steps ────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✨ Installation Complete!${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Next Steps:${NC}"
    echo ""
    echo -e "  ${BOLD}1.${NC} Restart NPM to load Wake-On-Request:"
    echo -e "     ${BLUE}docker compose up -d${NC}"
    echo ""
    echo -e "  ${BOLD}2.${NC} For each app you want to manage, add labels to its docker-compose.yml:"
    echo ""
    echo -e "     ${GREEN}labels:${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.enable=true\"${NC}             ${BLUE}# required — opt-in app for wake-on-request${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.domain=yourapp.example.com\"${NC}   ${BLUE}# required — comma-separated NPM domains${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.idle_timeout=300\"${NC}             ${BLUE}# optional — stop after 5 min idle (default: 300s)${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.start_timeout=30\"${NC}             ${BLUE}# optional — wait up to 30s on wake (default: 30s)${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.probe_host=192.168.1.103\"${NC}     ${BLUE}# optional — IP to probe for readiness (defaults to container name)${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.port=8080\"${NC}                    ${BLUE}# optional — port to probe (defaults to exposed port)${NC}"
    echo -e "     ${YELLOW}  restart: \"no\"${NC}                                  ${BLUE}# required — allows idle stop${NC}"
    echo ""
    echo -e "  ${BOLD}3.${NC} Then recreate the app container:"
    echo -e "     ${BLUE}docker compose up -d --force-recreate your-app${NC}"
    echo ""
    echo -e "  ${BOLD}4.${NC} Run with ${BOLD}--dry-run${NC} anytime to check container label status:"
    echo -e "     ${BLUE}./install.sh --dry-run${NC}"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
scan_docker_environment

if [ "$DRY_RUN" = true ]; then
    run_dry_run
else
    run_install
fi


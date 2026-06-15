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
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

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
    local bak="${file}.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp "$file" "$bak"
    info "Backed up $file → $bak"
}

DOCKER_CMD=""
detect_docker_cli() {
    if [ -n "$DOCKER_CMD" ]; then
        return 0
    fi

    # Check if we are running under sudo and SUDO_USER is set
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        # 1. Prioritize daemon containing the NPM container
        local user_npm_in_podman=false
        if sudo -u "$SUDO_USER" command -v podman >/dev/null 2>&1 && sudo -u "$SUDO_USER" podman ps -a --format '{{.Image}}' 2>/dev/null | grep -q "nginx-proxy-manager"; then
            user_npm_in_podman=true
        fi
        local user_npm_in_docker=false
        if sudo -u "$SUDO_USER" command -v docker >/dev/null 2>&1 && sudo -u "$SUDO_USER" docker ps -a --format '{{.Image}}' 2>/dev/null | grep -q "nginx-proxy-manager"; then
            user_npm_in_docker=true
        fi

        if [ "$user_npm_in_podman" = true ] && [ "$user_npm_in_docker" = false ]; then
            DOCKER_CMD="sudo -u $SUDO_USER podman"
            return 0
        fi
        if [ "$user_npm_in_docker" = true ] && [ "$user_npm_in_podman" = false ]; then
            DOCKER_CMD="sudo -u $SUDO_USER docker"
            return 0
        fi

        # 2. Check running container count
        local user_podman_count=0
        if sudo -u "$SUDO_USER" command -v podman >/dev/null 2>&1 && sudo -u "$SUDO_USER" podman ps -q >/dev/null 2>&1; then
            user_podman_count=$(sudo -u "$SUDO_USER" podman ps -q | wc -l)
        fi
        local user_docker_count=0
        if sudo -u "$SUDO_USER" command -v docker >/dev/null 2>&1 && sudo -u "$SUDO_USER" docker ps -q >/dev/null 2>&1; then
            user_docker_count=$(sudo -u "$SUDO_USER" docker ps -q | wc -l)
        fi

        if [ "$user_podman_count" -gt 0 ] && [ "$user_docker_count" -eq 0 ]; then
            DOCKER_CMD="sudo -u $SUDO_USER podman"
            return 0
        fi
        if [ "$user_docker_count" -gt 0 ] && [ "$user_podman_count" -eq 0 ]; then
            DOCKER_CMD="sudo -u $SUDO_USER docker"
            return 0
        fi

        # 3. Fallback to user commands if no running containers found but binaries exist
        if sudo -u "$SUDO_USER" command -v podman >/dev/null 2>&1 && sudo -u "$SUDO_USER" podman ps >/dev/null 2>&1; then
            DOCKER_CMD="sudo -u $SUDO_USER podman"
            return 0
        fi
        if sudo -u "$SUDO_USER" command -v docker >/dev/null 2>&1 && sudo -u "$SUDO_USER" docker ps >/dev/null 2>&1; then
            DOCKER_CMD="sudo -u $SUDO_USER docker"
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

NPM_PROXY_HOSTS=""
find_npm_container_id() {
    if ! has_docker; then
        echo ""
        return
    fi
    local npm_cid=""
    if [ -n "${NPM_CONTAINER_OVERRIDE:-}" ]; then
        npm_cid=$($DOCKER_CMD ps -q -f "name=${NPM_CONTAINER_OVERRIDE}" 2>/dev/null | head -n1)
        [ -z "$npm_cid" ] && npm_cid=$($DOCKER_CMD ps -q -f "id=${NPM_CONTAINER_OVERRIDE}" 2>/dev/null | head -n1)
        [ -z "$npm_cid" ] && npm_cid="$NPM_CONTAINER_OVERRIDE"
    else
        # Try local compose service first if in NPM directory
        npm_cid=$($DOCKER_CMD compose ps -q app 2>/dev/null || true)
        [ -z "$npm_cid" ] && npm_cid=$($DOCKER_CMD compose ps -q nginx-proxy-manager 2>/dev/null || true)
        
        # Fallback to scanning all containers
        if [ -z "$npm_cid" ]; then
            local container_ids
            container_ids=$($DOCKER_CMD ps -a -q || true)
            for cid in $container_ids; do
                local img
                img=$($DOCKER_CMD inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)
                if echo "$img" | grep -q "nginx-proxy-manager"; then
                    npm_cid="$cid"
                    break
                fi
            done
        fi
    fi
    echo "$npm_cid"
}

fetch_npm_proxy_hosts() {
    if ! has_docker; then
        return
    fi
    local npm_cid
    npm_cid=$(find_npm_container_id)
    if [ -n "$npm_cid" ]; then
        NPM_PROXY_HOSTS=$($DOCKER_CMD exec "$npm_cid" python3 -c "import sqlite3; conn = sqlite3.connect('/data/database.sqlite'); cursor = conn.cursor(); cursor.execute('SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;'); [print(f\"{row[0]}|{row[1]}|{row[2]}\") for row in cursor.fetchall()]" 2>/dev/null || true)
        if [ -z "$NPM_PROXY_HOSTS" ]; then
            NPM_PROXY_HOSTS=$($DOCKER_CMD exec "$npm_cid" sqlite3 /data/database.sqlite \
                "SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0;" 2>/dev/null || echo "")
        fi
    fi
}

find_npm_config_for_container() {
    local cname="$1"
    local ips="$2"
    matched_domain=""
    matched_port=""

    [ -z "$NPM_PROXY_HOSTS" ] && return 1

    while IFS='|' read -r domain_json fwd_host fwd_port; do
        [ -z "$domain_json" ] && continue

        local is_match=false
        if [ "$fwd_host" = "$cname" ]; then
            is_match=true
        else
            for ip in $ips; do
                if [ "$fwd_host" = "$ip" ]; then
                    is_match=true
                    break
                fi
            done
        fi

        if [ "$is_match" = true ]; then
            local domains
            domains=$(echo "$domain_json" | tr -d '[]"' | tr ',' ' ' | xargs)
            matched_domain=$(echo "$domains" | awk '{print $1}')
            matched_port="$fwd_port"
            return 0
        fi
    done <<< "$NPM_PROXY_HOSTS"
    return 1
}

# ── Docker Environment Scan ────────────────────────────────────────────────────
scan_docker_environment() {
    section "Environment Scan"

    if ! has_docker; then
        warn "Docker socket or daemon not accessible — skipping environment scan."
        return
    fi

    fetch_npm_proxy_hosts

    local container_ids npm_id npm_networks
    container_ids=$($DOCKER_CMD ps -a -q || true)

    # Find NPM container
    npm_id=$(find_npm_container_id)

    if [ -n "$npm_id" ]; then
        npm_networks=$($DOCKER_CMD inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' "$npm_id" 2>/dev/null || true)
    fi

    local restart_warning=""
    local isolated=""

    for cid in $container_ids; do
        [ "$cid" = "$npm_id" ] && continue

        # Inspect container
        local details
        details=$($DOCKER_CMD inspect --format '{{.Name}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.NetworkMode}}|{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' "$cid" 2>/dev/null || true)
        [ -z "$details" ] && continue

        # Parse fields
        local cname restart network networks
        IFS='|' read -r cname restart network networks <<< "$details"
        cname="${cname#/}"

        # 1. Check restart policy
        if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
            restart_warning="${restart_warning}    ${cname}  [restart: ${restart}]\n"
        fi

        # 2. Check network membership
        # Skip host network containers
        if [ "$network" != "host" ]; then
            local shares_network=false
            for net in $npm_networks; do
                for cnet in $networks; do
                    if [ "$net" = "$cnet" ]; then
                        shares_network=true
                        break 2
                    fi
                done
            done

            if [ "$shares_network" = false ]; then
                isolated="${isolated}    ${cname}\n"
            fi
        fi
    done

    if [ -n "$restart_warning" ]; then
        warn "These containers have auto-restart enabled, which PREVENTS Wake-On-Request"
        warn "from stopping them. Change restart to \"no\" in their docker-compose.yml:"
        echo -e "$restart_warning"
    fi

    if [ -n "$isolated" ]; then
        warn "These containers are on a DIFFERENT network than NPM."
        info "For these, set NPM Forward Host to your Docker Host IP."
        echo -e "$isolated"
    fi

    ok "Environment scan complete."
}

# ── Bundled file fallback ──────────────────────────────────────────────────────
# server_proxy.conf is not hosted on GitHub — it is embedded here instead.
# Called by both run_dry_run (for missing files) and run_install (as fallback).
write_bundled_files() {
    local target="npm-custom/server_proxy.conf"
    [ -f "$target" ] && return 0   # already present, nothing to do
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
        local container_ids npm_id npm_networks
        container_ids=$($DOCKER_CMD ps -a -q || true)
        
        # Find NPM container
        npm_id=$(find_npm_container_id)

        if [ -n "$npm_id" ]; then
            npm_networks=$($DOCKER_CMD inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' "$npm_id" 2>/dev/null || true)
        fi

        for cid in $container_ids; do
            [ "$cid" = "$npm_id" ] && continue

            # Get container details via Go Template (including IPAddress)
            local details
            details=$($DOCKER_CMD inspect --format '{{.Name}}|{{.State.Status}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.NetworkMode}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.enable"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.domain"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.idle_timeout"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.start_timeout"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.port"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "com.docker.compose.project.config_files"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "com.docker.compose.service"}}{{end}}|{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}|{{.NetworkSettings.Ports}}|{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cid" 2>/dev/null || true)

            [ -z "$details" ] && continue

            # Parse fields
            local cname state restart network enabled domain idle start port_label compose_file svc_name networks raw_ports ips
            IFS='|' read -r cname state restart network enabled domain idle start port_label compose_file svc_name networks raw_ports ips <<< "$details"
            cname="${cname#/}"

            # Strip "<no value>" strings from labels (for older docker engines/podman)
            enabled="${enabled#<no value>}"
            domain="${domain#<no value>}"
            idle="${idle#<no value>}"
            start="${start#<no value>}"
            port_label="${port_label#<no value>}"
            compose_file="${compose_file#<no value>}"
            svc_name="${svc_name#<no value>}"

            # Parse exposed and published ports from raw_ports
            local exposed_ports="" published_ports=""
            if [ -n "$raw_ports" ]; then
                raw_ports="${raw_ports#<no value>}"
                if [ -n "$raw_ports" ] && [ "$raw_ports" != "map[]" ]; then
                    exposed_ports=$(echo "$raw_ports" | grep -oE '[0-9]+/(tcp|udp)' | tr '\n' ' ' || echo "")
                    published_ports=$(echo "$raw_ports" | grep -oE '[0-9]+\}' | tr -d '}' | tr '\n' ' ' || echo "")
                fi
            fi

            echo ""
            # ── Already configured ────────────────────────────────────────────
            if [ "$enabled" = "true" ] && [ -n "$domain" ]; then
                idle="${idle:-300}"
                start="${start:-30}"
                ok "${BOLD}$cname${NC}${GREEN}  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
                continue
            fi

            if [ "$enabled" = "true" ] && [ -z "$domain" ]; then
                warn "${BOLD}$cname${NC}${YELLOW}  →  wakeonrequest.enable=true but MISSING wakeonrequest.domain label!"
                continue
            fi

            # ── Not yet configured — detect everything ────────────────────────

            # Detect exposed port (prefer label > single exposed port > published port)
            local detected_port="" port_source=""
            
            # Clean exposed/published ports & ips
            exposed_ports=$(echo "$exposed_ports" | xargs)
            published_ports=$(echo "$published_ports" | xargs)
            ips=$(echo "$ips" | xargs)

            # Count exposed/published ports
            local exp_count pub_count
            exp_count=$(echo "$exposed_ports" | wc -w)
            pub_count=$(echo "$published_ports" | wc -w)

            local single_exposed=""
            if [ "$exp_count" -eq 1 ]; then
                single_exposed="${exposed_ports%%/*}"
            fi

            local single_published=""
            if [ "$pub_count" -eq 1 ]; then
                single_published="${published_ports}"
            fi

            # Match against NPM SQLite database
            local matched_domain="" matched_port=""
            find_npm_config_for_container "$cname" "$ips" || true

            if [ -n "$port_label" ]; then
                detected_port="$port_label"
                port_source="from label"
            elif [ -n "$matched_port" ]; then
                detected_port="$matched_port"
                port_source="from NPM database"
            elif [ -n "$single_exposed" ]; then
                detected_port="$single_exposed"
                port_source="auto-detected"
            elif [ -n "$single_published" ]; then
                detected_port="$single_published"
                port_source="published port"
            else
                detected_port=""
                port_source=""
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
            local fwd_host fwd_port fwd_note restart_needed
            if [ "$network" = "host" ]; then
                fwd_host="<your-docker-host-ip>"
                fwd_port="${single_published:-<port>}"
                fwd_note="host network — NPM cannot route by name"
            elif [ "$shares_network" = "true" ]; then
                fwd_host="$cname"
                fwd_port="${detected_port:-<port>}"
                fwd_note="same network as NPM — use container name"
            else
                fwd_host="<your-docker-host-ip>"
                fwd_port="${single_published:-<port>}"
                fwd_note="different network from NPM — use host IP"
            fi

            restart_needed=false
            if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
                restart_needed=true
            fi

            # ── Translate Windows path to WSL format ──────────────────────────────
            local compose_path="$compose_file"
            if [ -n "$compose_path" ]; then
                compose_path="${compose_path//\\//}"
                if [[ "$compose_path" =~ ^[a-zA-Z]:/ ]]; then
                    compose_path=$(wslpath -u "$compose_path" 2>/dev/null || echo "$compose_path")
                fi
            fi

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
            [ -n "$matched_domain" ] && label_domain="$matched_domain"

            if [ -n "$compose_path" ] && [ -f "$compose_path" ]; then
                if grep -qF "wakeonrequest.enable" "$compose_path"; then
                    ok "Compose File : ${GREEN}Already configured${NC} in ${BLUE}$compose_path${NC}"
                else
                    change "Compose File : ${YELLOW}Will patch${NC} at ${BLUE}$compose_path${NC}"
                    echo ""
                    echo -e "     ${BOLD}── Proposed changes for $compose_path ──${NC}"
                    echo ""
                    if [ "$restart_needed" = "true" ]; then
                        echo -e "     ${YELLOW}restart: \"no\"${NC}                                  ${BLUE}# change from: $restart${NC}"
                    fi
                    echo -e "     ${GREEN}labels:${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.enable=true\"${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.domain=${label_domain}\"${NC}  ${BLUE}# ← your NPM domain${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.idle_timeout=300\"${NC}                  ${BLUE}# stop after 5 min idle${NC}"
                    echo -e "     ${GREEN}  - \"wakeonrequest.start_timeout=30\"${NC}                  ${BLUE}# wait up to 30s on wake${NC}"
                    echo ""
                fi
            else
                warn "Compose File : ${RED}Not found${NC} (checked: ${YELLOW}${compose_path:-none}${NC})"
                echo ""
                echo -e "     ${BOLD}── Add to $cname's docker-compose.yml manually ──${NC}"
                echo ""
                if [ "$restart_needed" = "true" ]; then
                    echo -e "     ${YELLOW}restart: \"no\"${NC}                                  ${BLUE}# change from: $restart${NC}"
                fi
                echo -e "     ${GREEN}labels:${NC}"
                echo -e "     ${GREEN}  - \"wakeonrequest.enable=true\"${NC}"
                echo -e "     ${GREEN}  - \"wakeonrequest.domain=${label_domain}\"${NC}  ${BLUE}# ← your NPM domain${NC}"
                echo -e "     ${GREEN}  - \"wakeonrequest.idle_timeout=300\"${NC}                  ${BLUE}# stop after 5 min idle${NC}"
                echo -e "     ${GREEN}  - \"wakeonrequest.start_timeout=30\"${NC}                  ${BLUE}# wait up to 30s on wake${NC}"
                echo ""
            fi
        done
    else
        warn "Docker socket or daemon not available — skipping container scan."
    fi

    # ── NPM Database Status ───────────────────────────────────────────────────
    section "NPM Database Status"
    local npm_db="./data/database.sqlite"
    if [ -f "$npm_db" ]; then
        if has_docker; then
            local npm_cid
            npm_cid=$($DOCKER_CMD compose ps -q app 2>/dev/null || true)
            [ -z "$npm_cid" ] && npm_cid=$($DOCKER_CMD compose ps -q nginx-proxy-manager 2>/dev/null || true)
            [ -z "$npm_cid" ] && npm_cid=$($DOCKER_CMD ps -q -f "name=nginx-proxy-manager" 2>/dev/null | head -n1)
            [ -z "$npm_cid" ] && npm_cid=$($DOCKER_CMD ps -q -f "ancestor=jc21/nginx-proxy-manager" 2>/dev/null | head -n1)
            if [ -n "$npm_cid" ]; then
                local count
                count=$($DOCKER_CMD exec "$npm_cid" python3 -c "import sqlite3; conn = sqlite3.connect('/data/database.sqlite'); cursor = conn.cursor(); cursor.execute(\"SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%';\"); print(cursor.fetchone()[0])" 2>/dev/null || true)
                if [ -z "$count" ]; then
                    count=$($DOCKER_CMD exec "$npm_cid" sqlite3 /data/database.sqlite \
                        "SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%';" 2>/dev/null || echo "")
                fi
                if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
                    change "NPM Database: Will clear old Lua snippets from $count proxy host(s) in Advanced tab."
                else
                    ok "NPM Database: No old Lua snippets to clean."
                fi
            else
                warn "NPM container is not running — skipping database check."
            fi
        else
            warn "Docker socket not accessible — skipping database check."
        fi
    else
        info "No NPM database found at $npm_db — skipping database check."
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

    local container_ids npm_id npm_networks
    container_ids=$($DOCKER_CMD ps -a -q || true)

    # Find NPM container
    npm_id=$(find_npm_container_id)

    if [ -n "$npm_id" ]; then
        npm_networks=$($DOCKER_CMD inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' "$npm_id" 2>/dev/null || true)
    fi

    local any_unmanaged=false

    for cid in $container_ids; do
        [ "$cid" = "$npm_id" ] && continue

        # Get container details via Go Template (including IPAddress)
        local details
        details=$($DOCKER_CMD inspect --format '{{.Name}}|{{.State.Status}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.NetworkMode}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.enable"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.domain"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.idle_timeout"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.start_timeout"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "wakeonrequest.port"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "com.docker.compose.project.config_files"}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "com.docker.compose.service"}}{{end}}|{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}|{{.NetworkSettings.Ports}}|{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cid" 2>/dev/null || true)

        [ -z "$details" ] && continue

        # Parse fields
        local cname state restart network enabled domain idle start port_label compose_file svc_name networks raw_ports ips
        IFS='|' read -r cname state restart network enabled domain idle start port_label compose_file svc_name networks raw_ports ips <<< "$details"
        cname="${cname#/}"

        # Strip "<no value>" strings from labels (for older docker engines/podman)
        enabled="${enabled#<no value>}"
        domain="${domain#<no value>}"
        idle="${idle#<no value>}"
        start="${start#<no value>}"
        port_label="${port_label#<no value>}"
        compose_file="${compose_file#<no value>}"
        svc_name="${svc_name#<no value>}"

        # Parse exposed and published ports from raw_ports
        local exposed_ports="" published_ports=""
        if [ -n "$raw_ports" ]; then
            raw_ports="${raw_ports#<no value>}"
            if [ -n "$raw_ports" ] && [ "$raw_ports" != "map[]" ]; then
                exposed_ports=$(echo "$raw_ports" | grep -oE '[0-9]+/(tcp|udp)' | tr '\n' ' ' || echo "")
                published_ports=$(echo "$raw_ports" | grep -oE '[0-9]+\}' | tr -d '}' | tr '\n' ' ' || echo "")
            fi
        fi

        # Skip already-configured containers
        if [ "$enabled" = "true" ] && [ -n "$domain" ]; then
            idle="${idle:-300}"
            start="${start:-30}"
            ok "${BOLD}$cname${NC}${GREEN}  already configured  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
            continue
        fi

        any_unmanaged=true

        # Detect exposed port (prefer label > single exposed port > published port)
        local detected_port="" port_source=""
        
        # Clean exposed/published ports & ips
        exposed_ports=$(echo "$exposed_ports" | xargs)
        published_ports=$(echo "$published_ports" | xargs)
        ips=$(echo "$ips" | xargs)

        # Count exposed/published ports
        local exp_count pub_count
        exp_count=$(echo "$exposed_ports" | wc -w)
        pub_count=$(echo "$published_ports" | wc -w)

        local single_exposed=""
        if [ "$exp_count" -eq 1 ]; then
            single_exposed="${exposed_ports%%/*}"
        fi

        local single_published=""
        if [ "$pub_count" -eq 1 ]; then
            single_published="${published_ports}"
        fi

        local user_domain=""
        local default_domain=""
        local default_port=""
        
        # 1. Search in NPM SQLite database
        local matched_domain="" matched_port=""
        find_npm_config_for_container "$cname" "$ips" || true
        
        if [ -n "$matched_domain" ]; then
            default_domain="$matched_domain"
            default_port="$matched_port"
            port_source="from NPM database"
        else
            # Fallback to standard exposed/published port detection
            if [ -n "$port_label" ]; then
                default_port="$port_label"
                port_source="from label"
            elif [ -n "$single_exposed" ]; then
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
        if [ "$network" = "host" ]; then
            fwd_host="<your-docker-host-ip>"
        elif [ "$shares_network" = "true" ]; then
            fwd_host="$cname"
        else
            fwd_host="<your-docker-host-ip>"
        fi

        # ── Print container summary ───────────────────────────────────────────
        echo ""
        echo -e "  ${YELLOW}➕ ${BOLD}$cname${NC}  [state: $state | restart: $restart]"
        if [ -n "$default_domain" ]; then
            echo -e "     NPM Domain       : ${GREEN}$default_domain${NC}  ${BLUE}(auto-detected from database)${NC}"
        fi
        echo -e "     NPM Forward Host : ${GREEN}$fwd_host${NC}"
        if [ -n "$default_port" ] && [ "$default_port" != "<port>" ]; then
            echo -e "     NPM Forward Port : ${GREEN}$default_port${NC}  ${BLUE}($port_source)${NC}"
        else
            echo -e "     NPM Forward Port : ${YELLOW}<set manually>${NC}"
        fi
        if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
            echo -e "     ${RED}❌ restart: \"$restart\" must be changed to \"no\" manually${NC}"
            echo -e "        ${BLUE}(wake-on-request cannot stop containers with auto-restart)${NC}"
        fi

        # ── Ask whether to configure this container ───────────────────────────
        echo ""
        local prompt_msg="Configure wake-on-request for $cname"
        if [ -n "$default_domain" ]; then
            prompt_msg="$prompt_msg (domain: $default_domain, port: $default_port)"
        fi
        printf "     %s? [Y/n] " "$prompt_msg"
        local answer
        read -r answer </dev/tty
        if [ -z "$answer" ]; then
            answer="y"
        fi
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "Skipped $cname"
            continue
        fi

        # ── Resolve domain ────────────────────────────────────────────────────
        if [ -n "$default_domain" ]; then
            user_domain="$default_domain"
        else
            while [ -z "$user_domain" ]; do
                printf "     NPM domain for %s (e.g. app.example.com): " "$cname"
                read -r user_domain </dev/tty
                user_domain="${user_domain// /}"   # strip accidental spaces
            done
        fi

        # ── Prompt for idle timeout ───────────────────────────────────────────
        local user_idle=""
        printf "     Idle timeout in seconds [300]: "
        read -r user_idle </dev/tty
        user_idle="${user_idle// /}"
        [ -z "$user_idle" ] && user_idle="300"

        # ── Prompt for start timeout ──────────────────────────────────────────
        local user_start=""
        printf "     Start timeout in seconds [30]: "
        read -r user_start </dev/tty
        user_start="${user_start// /}"
        [ -z "$user_start" ] && user_start="30"

        # ── Translate Windows path to WSL format ──────────────────────────────
        local compose_path="$compose_file"
        if [ -n "$compose_path" ]; then
            compose_path="${compose_path//\\//}"
            if [[ "$compose_path" =~ ^[a-zA-Z]:/ ]]; then
                compose_path=$(wslpath -u "$compose_path" 2>/dev/null || echo "$compose_path")
            fi
        fi

        # ── Locate and patch the compose file ────────────────────────────────
        if [ -n "$compose_path" ] && [ -f "$compose_path" ]; then
            echo ""
            info "Found compose file: $compose_path"

            # Safety check: only patch if we can find the service name in the file
            if [ -z "$svc_name" ] || ! grep -qF "${svc_name}:" "$compose_path"; then
                warn "Cannot safely locate service '${svc_name}' in $compose_path — showing manual snippet instead."
            else
                backup_file "$compose_path"

                # Build the label block to inject (indented 6 spaces for typical compose layout)
                local label_block
                label_block="      labels:\n\
        - \"wakeonrequest.enable=true\"\n\
        - \"wakeonrequest.domain=${user_domain}\"\n\
        - \"wakeonrequest.idle_timeout=${user_idle}\"\n\
        - \"wakeonrequest.start_timeout=${user_start}\""

                # Check if a labels: block already exists under this service
                if grep -qF "wakeonrequest.enable" "$compose_path"; then
                    warn "wakeonrequest labels already present in $compose_path — skipping write."
                elif grep -A50 "${svc_name}:" "$compose_path" | grep -qE "^[[:space:]]+labels:"; then
                    # labels: block exists — append our entries after it
                    sed -i "/^[[:space:]]*labels:/a \\        - \"wakeonrequest.enable=true\"\n        - \"wakeonrequest.domain=${user_domain}\"\n        - \"wakeonrequest.idle_timeout=${user_idle}\"\n        - \"wakeonrequest.start_timeout=${user_start}\"" \
                        "$compose_path"
                    ok "Labels appended to existing labels: block in $compose_path"
                else
                    # No labels: block — insert one after the service name line
                    sed -i "/^[[:space:]]*${svc_name}:/a \\${label_block}" "$compose_path"
                    ok "Labels added to $compose_path"
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
        echo -e "     ${BOLD}Add this to ${cname}'s docker-compose.yml:${NC}"
        echo ""
        if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
            echo -e "     ${YELLOW}  restart: \"no\"${NC}  ${BLUE}# change from: $restart${NC}"
        fi
        echo -e "     ${GREEN}  labels:${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.enable=true\"${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.domain=${user_domain}\"${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.idle_timeout=${user_idle}\"${NC}"
        echo -e "     ${GREEN}    - \"wakeonrequest.start_timeout=${user_start}\"${NC}"
        echo ""
        info "Then run: docker compose up -d --force-recreate $cname"

    done

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
    local npm_db="./data/database.sqlite"
    if [ -f "$npm_db" ]; then
        local npm_cid
        npm_cid=$(find_npm_container_id)
        if [ -n "$npm_cid" ]; then
            local cleaned
            cleaned=$($DOCKER_CMD exec "$npm_cid" python3 -c "import sqlite3; conn = sqlite3.connect('/data/database.sqlite'); cursor = conn.cursor(); cursor.execute(\"UPDATE proxy_host SET advanced_config = '' WHERE advanced_config LIKE '%wakeonrequest%';\"); conn.commit(); print(cursor.rowcount)" 2>/dev/null || true)
            if [ -z "$cleaned" ]; then
                cleaned=$($DOCKER_CMD exec "$npm_cid" sqlite3 /data/database.sqlite \
                    "UPDATE proxy_host
                     SET    advanced_config = ''
                     WHERE  advanced_config LIKE '%wakeonrequest%';
                     SELECT changes();" 2>/dev/null || echo "0")
            fi
            if [ "$cleaned" != "0" ] && [ -n "$cleaned" ]; then
                ok "Cleared old Lua snippets from $cleaned proxy host(s)."
            else
                ok "No old snippets found — nothing to clean."
            fi
        else
            warn "NPM container is not running — skipping database cleanup."
            info "After starting NPM, clear any 'access_by_lua_block' from Proxy Host Advanced tabs."
        fi
    else
        info "No NPM database found at $npm_db — skipping cleanup."
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
    echo -e "     ${GREEN}  - \"wakeonrequest.enable=true\"${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.domain=yourapp.example.com\"${NC}   ${BLUE}# must match your NPM domain${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.idle_timeout=300\"${NC}             ${BLUE}# stop after 5 min idle${NC}"
    echo -e "     ${GREEN}  - \"wakeonrequest.start_timeout=30\"${NC}             ${BLUE}# wait up to 30s on wake${NC}"
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


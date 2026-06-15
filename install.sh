#!/bin/bash
# ==============================================================================
# Wake-On-Request Installer
# https://github.com/msenturk/wake-on-request
#
# Usage:
#   ./install.sh                  Install in current directory
#   ./install.sh /path/to/npm     Install in specified directory
#   ./install.sh --dry-run        Preview what will change, no files written
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
DRY_RUN=false
TARGET_DIR="."
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) TARGET_DIR="$arg" ;;
    esac
done

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

docker_api() { curl -sf --unix-socket /var/run/docker.sock "http://localhost$1"; }
has_docker() { [ -e "/var/run/docker.sock" ]; }
has_jq()     { command -v jq >/dev/null 2>&1; }

# ── Docker Environment Scan ────────────────────────────────────────────────────
scan_docker_environment() {
    section "Environment Scan"

    if ! has_docker; then
        warn "Docker socket not accessible — skipping environment scan."
        return
    fi
    if ! has_jq; then
        warn "'jq' not installed — skipping environment scan."
        return
    fi

    local cjson
    cjson=$(docker_api "/containers/json?all=1")

    local npm_id
    npm_id=$(echo "$cjson" | jq -r '
        .[] | select(.Image | test("nginx-proxy-manager")) | .Id' | head -n1)

    local npm_networks
    npm_networks=$(echo "$cjson" | jq -r --arg id "$npm_id" '
        .[] | select(.Id == $id) | .NetworkSettings.Networks | keys[]' 2>/dev/null || true)

    # Build a jq filter to check NPM network membership
    local jq_net_filter="false"
    if [ -n "$npm_networks" ]; then
        jq_net_filter=$(echo "$npm_networks" \
            | awk '{print "has(\""$1"\")"}' | paste -sd ' or ' -)
    fi

    # Containers with 'always' or 'unless-stopped' restart policies
    local restart_warning
    restart_warning=$(echo "$cjson" | jq -r --arg id "$npm_id" '
        .[] | select(.Id != $id)
             | select(.HostConfig.RestartPolicy.Name == "always"
                   or .HostConfig.RestartPolicy.Name == "unless-stopped")
             | "    \(.Names[0] | ltrimstr("/"))  [restart: \(.HostConfig.RestartPolicy.Name)]"')

    if [ -n "$restart_warning" ]; then
        warn "These containers have auto-restart enabled, which PREVENTS Wake-On-Request"
        warn "from stopping them. Change restart to \"no\" in their docker-compose.yml:"
        echo "$restart_warning" | while IFS= read -r line; do
            echo -e "  ${YELLOW}${line}${NC}"
        done
    fi

    # Containers on a different network than NPM
    local isolated
    isolated=$(echo "$cjson" | jq -r --arg id "$npm_id" \
        --argjson net_filter "$(echo "$jq_net_filter" | jq -Rs .)" '
        .[] | select(.Id != $id)
             | select(.HostConfig.NetworkMode != "host")
             | select(.Image | test("nginx-proxy-manager") | not)
             | select(.NetworkSettings.Networks | ($net_filter | @json | fromjson | . == "false")
                or (.NetworkSettings.Networks | to_entries | length == 0))
             | "    \(.Names[0] | ltrimstr("/"))"' 2>/dev/null || true)

    if [ -n "$isolated" ]; then
        warn "These containers are on a DIFFERENT network than NPM."
        info "For these, set NPM Forward Host to your Docker Host IP."
        echo "$isolated"
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
        if [ ! -f "$local_path" ]; then
            if [ "$local_path" = "npm-custom/server_proxy.conf" ]; then
                change "Write     $local_path   ← bundled in install.sh"
            else
                change "Download  $local_path   ← $RAW_BASE/$local_path"
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
    if has_docker && has_jq; then
        local cjson npm_id npm_networks
        cjson=$(docker_api "/containers/json?all=1")
        npm_id=$(echo "$cjson" | jq -r '
            .[] | select(.Image | test("nginx-proxy-manager")) | .Id' | head -n1)
        npm_networks=$(echo "$cjson" | jq -r --arg id "$npm_id" '
            .[] | select(.Id == $id) | .NetworkSettings.Networks | keys[]' 2>/dev/null || true)

        echo "$cjson" | jq -c --arg id "$npm_id" '.[] | select(.Id != $id)' | \
        while IFS= read -r c; do
            local cname state restart network enabled domain
            cname=$(echo "$c"   | jq -r '.Names[0] | ltrimstr("/")')
            state=$(echo "$c"   | jq -r '.State')
            restart=$(echo "$c" | jq -r '.HostConfig.RestartPolicy.Name')
            network=$(echo "$c" | jq -r '.HostConfig.NetworkMode')
            enabled=$(echo "$c" | jq -r '.Labels["wakeonrequest.enable"] // ""')
            domain=$(echo "$c"  | jq -r '.Labels["wakeonrequest.domain"] // ""')

            echo ""
            # ── Already configured ────────────────────────────────────────────
            if [ "$enabled" = "true" ] && [ -n "$domain" ]; then
                local idle start
                idle=$(echo "$c" | jq -r '.Labels["wakeonrequest.idle_timeout"] // "300"')
                start=$(echo "$c" | jq -r '.Labels["wakeonrequest.start_timeout"] // "30"')
                ok "${BOLD}$cname${NC}${GREEN}  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
                continue
            fi

            if [ "$enabled" = "true" ] && [ -z "$domain" ]; then
                warn "${BOLD}$cname${NC}${YELLOW}  →  wakeonrequest.enable=true but MISSING wakeonrequest.domain label!"
                continue
            fi

            # ── Not yet configured — detect everything ────────────────────────

            # Detect exposed port (prefer label > single exposed port > published port)
            local port_label exposed_port published_port detected_port port_source
            port_label=$(echo "$c"     | jq -r '.Labels["wakeonrequest.port"] // ""')
            exposed_port=$(echo "$c"   | jq -r '
                (.Config.ExposedPorts // {}) | keys
                | map(scan("^[0-9]+")) | if length == 1 then .[0] else "" end')
            published_port=$(echo "$c" | jq -r '
                [.Ports[]? | select(.PublicPort != null) | .PublicPort | tostring]
                | if length == 1 then .[0] else "" end')

            if   [ -n "$port_label" ];     then detected_port="$port_label";    port_source="from label"
            elif [ -n "$exposed_port" ];   then detected_port="$exposed_port";  port_source="auto-detected"
            elif [ -n "$published_port" ]; then detected_port="$published_port"; port_source="published port"
            else                                detected_port="";               port_source=""
            fi

            # Determine if this container shares a network with NPM
            local shares_network=false
            if [ -n "$npm_networks" ]; then
                while IFS= read -r net; do
                    if echo "$c" | jq -e --arg n "$net" \
                        '.NetworkSettings.Networks | has($n)' >/dev/null 2>&1; then
                        shares_network=true; break
                    fi
                done <<< "$npm_networks"
            fi

            # Decide Forward Host recommendation
            local fwd_host fwd_port fwd_note restart_needed
            if [ "$network" = "host" ]; then
                fwd_host="<your-docker-host-ip>"
                fwd_port="${published_port:-<port>}"
                fwd_note="host network — NPM cannot route by name"
            elif [ "$shares_network" = "true" ]; then
                fwd_host="$cname"
                fwd_port="${detected_port:-<port>}"
                fwd_note="same network as NPM — use container name"
            else
                fwd_host="<your-docker-host-ip>"
                fwd_port="${published_port:-<port>}"
                fwd_note="different network from NPM — use host IP"
            fi

            restart_needed=false
            if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
                restart_needed=true
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
            echo -e "     ${BOLD}── Add to $cname's docker-compose.yml ──${NC}"
            echo ""
            if [ "$restart_needed" = "true" ]; then
                echo -e "     ${YELLOW}restart: \"no\"${NC}                                  ${BLUE}# change from: $restart${NC}"
            fi
            echo -e "     ${GREEN}labels:${NC}"
            echo -e "     ${GREEN}  - \"wakeonrequest.enable=true\"${NC}"
            echo -e "     ${GREEN}  - \"wakeonrequest.domain=<your-domain.example.com>\"${NC}  ${BLUE}# ← your NPM domain${NC}"
            echo -e "     ${GREEN}  - \"wakeonrequest.idle_timeout=300\"${NC}                  ${BLUE}# stop after 5 min idle${NC}"
            echo -e "     ${GREEN}  - \"wakeonrequest.start_timeout=30\"${NC}                  ${BLUE}# wait up to 30s on wake${NC}"
            echo ""
        done
    else
        warn "Docker socket or jq not available — skipping container scan."
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
    if ! has_docker || ! has_jq; then
        warn "Docker socket or jq not available — skipping app container setup."
        return
    fi

    section "App Container Setup"

    local cjson npm_id npm_networks
    cjson=$(docker_api "/containers/json?all=1")
    npm_id=$(echo "$cjson" | jq -r '
        .[] | select(.Image | test("nginx-proxy-manager")) | .Id' | head -n1)
    npm_networks=$(echo "$cjson" | jq -r --arg id "$npm_id" '
        .[] | select(.Id == $id) | .NetworkSettings.Networks | keys[]' 2>/dev/null || true)

    local any_unmanaged=false

    while IFS= read -r c; do
        local cname enabled domain compose_file
        cname=$(echo "$c"   | jq -r '.Names[0] | ltrimstr("/")')
        enabled=$(echo "$c" | jq -r '.Labels["wakeonrequest.enable"] // ""')
        domain=$(echo "$c"  | jq -r '.Labels["wakeonrequest.domain"] // ""')

        # Skip already-configured containers
        if [ "$enabled" = "true" ] && [ -n "$domain" ]; then
            local idle start
            idle=$(echo "$c" | jq -r '.Labels["wakeonrequest.idle_timeout"] // "300"')
            start=$(echo "$c" | jq -r '.Labels["wakeonrequest.start_timeout"] // "30"')
            ok "${BOLD}$cname${NC}${GREEN}  already configured  →  domain: $domain  |  idle: ${idle}s  |  start: ${start}s"
            continue
        fi

        any_unmanaged=true

        # ── Detect compose file via Docker Compose labels ─────────────────────
        compose_file=$(echo "$c" | jq -r \
            '.Labels["com.docker.compose.project.config_files"] // ""' | cut -d',' -f1)

        # ── Detect restart policy ─────────────────────────────────────────────
        local restart
        restart=$(echo "$c" | jq -r '.HostConfig.RestartPolicy.Name')

        # ── Detect network / forward host ─────────────────────────────────────
        local network shares_network fwd_host detected_port port_source
        network=$(echo "$c" | jq -r '.HostConfig.NetworkMode')
        shares_network=false
        if [ -n "$npm_networks" ]; then
            while IFS= read -r net; do
                if echo "$c" | jq -e --arg n "$net" \
                    '.NetworkSettings.Networks | has($n)' >/dev/null 2>&1; then
                    shares_network=true; break
                fi
            done <<< "$npm_networks"
        fi

        local port_label exposed_port published_port
        port_label=$(echo "$c"     | jq -r '.Labels["wakeonrequest.port"] // ""')
        exposed_port=$(echo "$c"   | jq -r '
            (.Config.ExposedPorts // {}) | keys
            | map(scan("^[0-9]+")) | if length == 1 then .[0] else "" end')
        published_port=$(echo "$c" | jq -r '
            [.Ports[]? | select(.PublicPort != null) | .PublicPort | tostring]
            | if length == 1 then .[0] else "" end')

        if   [ -n "$port_label" ];     then detected_port="$port_label";     port_source="from label"
        elif [ -n "$exposed_port" ];   then detected_port="$exposed_port";   port_source="auto-detected"
        elif [ -n "$published_port" ]; then detected_port="$published_port"; port_source="published port"
        else                                detected_port="";                port_source=""
        fi

        if [ "$network" = "host" ]; then
            fwd_host="<your-docker-host-ip>"
        elif [ "$shares_network" = "true" ]; then
            fwd_host="$cname"
        else
            fwd_host="<your-docker-host-ip>"
        fi

        # ── Print container summary ───────────────────────────────────────────
        echo ""
        echo -e "  ${YELLOW}➕ ${BOLD}$cname${NC}  [state: $(echo "$c" | jq -r '.State') | restart: $restart]"
        echo -e "     NPM Forward Host : ${GREEN}$fwd_host${NC}"
        if [ -n "$detected_port" ]; then
            echo -e "     NPM Forward Port : ${GREEN}$detected_port${NC}  ${BLUE}($port_source)${NC}"
        else
            echo -e "     NPM Forward Port : ${YELLOW}<set manually>${NC}"
        fi
        if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
            echo -e "     ${RED}❌ restart: \"$restart\" must be changed to \"no\" manually${NC}"
            echo -e "        ${BLUE}(wake-on-request cannot stop containers with auto-restart)${NC}"
        fi

        # ── Ask whether to configure this container ───────────────────────────
        echo ""
        printf "     Configure wake-on-request for %s? [y/N] " "$cname"
        local answer
        read -r answer </dev/tty
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "Skipped $cname"
            continue
        fi

        # ── Prompt for domain ─────────────────────────────────────────────────
        local user_domain=""
        while [ -z "$user_domain" ]; do
            printf "     NPM domain for %s (e.g. app.example.com): " "$cname"
            read -r user_domain </dev/tty
            user_domain="${user_domain// /}"   # strip accidental spaces
        done

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

        # ── Locate and patch the compose file ────────────────────────────────
        if [ -n "$compose_file" ] && [ -f "$compose_file" ]; then
            echo ""
            info "Found compose file: $compose_file"

            # Check if labels block already exists under this service
            local svc_name
            svc_name=$(echo "$c" | jq -r '.Labels["com.docker.compose.service"] // ""')

            # Safety check: only patch if we can find the service name in the file
            if [ -z "$svc_name" ] || ! grep -qF "${svc_name}:" "$compose_file"; then
                warn "Cannot safely locate service '${svc_name}' in $compose_file — showing manual snippet instead."
            else
                backup_file "$compose_file"

                # Build the label block to inject (indented 6 spaces for typical compose layout)
                local label_block
                label_block="      labels:\n\
        - \"wakeonrequest.enable=true\"\n\
        - \"wakeonrequest.domain=${user_domain}\"\n\
        - \"wakeonrequest.idle_timeout=${user_idle}\"\n\
        - \"wakeonrequest.start_timeout=${user_start}\""

                # Check if a labels: block already exists under this service
                if grep -qF "wakeonrequest.enable" "$compose_file"; then
                    warn "wakeonrequest labels already present in $compose_file — skipping write."
                elif grep -A50 "${svc_name}:" "$compose_file" | grep -qE "^[[:space:]]+labels:"; then
                    # labels: block exists — append our entries after it
                    sed -i "/^[[:space:]]*labels:/a \\        - \"wakeonrequest.enable=true\"\n        - \"wakeonrequest.domain=${user_domain}\"\n        - \"wakeonrequest.idle_timeout=${user_idle}\"\n        - \"wakeonrequest.start_timeout=${user_start}\"" \
                        "$compose_file"
                    ok "Labels appended to existing labels: block in $compose_file"
                else
                    # No labels: block — insert one after the service name line
                    sed -i "/^[[:space:]]*${svc_name}:/a \\${label_block}" "$compose_file"
                    ok "Labels added to $compose_file"
                fi

                if [ "$restart" = "always" ] || [ "$restart" = "unless-stopped" ]; then
                    echo ""
                    warn "Remember to change restart to \"no\" in $compose_file"
                    warn "Then run: docker compose up -d --force-recreate $cname"
                else
                    echo ""
                    info "Apply with: docker compose up -d --force-recreate $cname"
                fi
                continue
            fi
        else
            if [ -n "$compose_file" ]; then
                warn "Compose file not accessible at: $compose_file"
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

    done < <(echo "$cjson" | jq -c --arg id "$npm_id" '.[] | select(.Id != $id)')

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
        local url="$RAW_BASE/$local_path"

        # server_proxy.conf is embedded — skip curl for it
        if [ "$local_path" = "npm-custom/server_proxy.conf" ]; then
            ok "Bundled   $local_path (no download needed)"
            continue
        fi

        backup_file "$local_path"
        echo -ne "  Downloading ${BOLD}$local_path${NC} ... "
        if curl -fsSL "$url" -o "$local_path"; then
            echo -e "${GREEN}done${NC}"
        else
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
        npm_cid=$(docker compose ps -q app 2>/dev/null \
               || docker compose ps -q nginx-proxy-manager 2>/dev/null || true)
        if [ -n "$npm_cid" ]; then
            local cleaned
            cleaned=$(docker exec "$npm_cid" sqlite3 /data/database.sqlite \
                "UPDATE proxy_host
                 SET    advanced_config = ''
                 WHERE  advanced_config LIKE '%wakeonrequest%';
                 SELECT changes();" 2>/dev/null || echo "0")
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


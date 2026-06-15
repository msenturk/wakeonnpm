-- =============================================================================
-- wakeonrequest.lua
-- On-demand Docker container lifecycle manager for Nginx Proxy Manager.
--
-- Runs entirely inside NPM's OpenResty process — no sidecar needed.
--
-- FEATURES:
--   - Wake-on-Request: Starts stopped containers on first request.
--   - Idle Shutdown:   Automatically stops containers after inactivity.
--   - Startup Splash:  Shows a loading page while the container wakes up.
--   - Global Mode:     One interceptor covers ALL proxy hosts automatically.
--   - Zero UI Config:  No NPM Advanced Tab needed — configure via Docker labels.
--
-- CONFIGURATION METHODS:
--   Method A — Docker Labels (RECOMMENDED, zero NPM UI config):
--     Add to your app's docker-compose.yml:
--       labels:
--         - "wakeonrequest.enable=true"
--         - "wakeonrequest.domain=app.example.com"   # comma-separated for multiple
--         - "wakeonrequest.idle_timeout=300"          # optional (default: 300s)
--         - "wakeonrequest.start_timeout=30"          # optional (default: 30s)
--
--   Method B — NPM Advanced Tab (per-host override, no labels needed):
--     Paste into the Advanced tab of a specific Proxy Host:
--       set $wake_container   "my-container";  # required
--       set $wake_idle_timeout  300;            # optional
--       set $wake_start_timeout  30;            # optional
--       set $wake_timer_interval 60;            # optional (idle-check interval)
--       set $wake_poll_interval  0.5;           # optional (startup poll interval)
--       set $wake_splash        "true";         # optional (default: true)
--
-- GLOBAL CONFIG (npm-custom/http_top.conf — set once, never edit again):
--   lua_shared_dict wakeonrequest_state 1m;
--   lua_package_path "/data/nginx/custom/?.lua;;";
--   init_worker_by_lua_block { require("wakeonrequest").auto_start_timers() }
--
-- GLOBAL INTERCEPTOR (npm-custom/server_proxy.conf — injected by install.sh):
--   access_by_lua_block { require("wakeonrequest").global_wake() }
-- =============================================================================

local _M = {}

-- ── Defaults (can be overridden per proxy host before calling wake()) ─────────
_M.DOCKER_SOCKET    = "/var/run/docker.sock"
_M.DEFAULT_IDLE     = 600    -- seconds idle before auto-stop
_M.DEFAULT_START    = 30     -- seconds to wait for container ready
_M.POLL_INTERVAL    = 0.5    -- seconds between readiness polls
_M.TIMER_INTERVAL   = 60     -- seconds between idle checks
_M.SHARED_DICT      = "wakeonrequest_state"

-- Label that opts a container in to wakeonrequest management
_M.LABEL_ENABLE     = "wakeonrequest.enable"
_M.LABEL_DOMAIN     = "wakeonrequest.domain"
_M.LABEL_IDLE       = "wakeonrequest.idle_timeout"
_M.LABEL_START      = "wakeonrequest.start_timeout"

-- ── Docker socket I/O ────────────────────────────────────────────────────────

local json = require("cjson.safe")

-- ── Splash Page Template ─────────────────────────────────────────────────────

local SPLASH_TEMPLATE = [[
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Starting {name}</title>
    <style>
        :root {
            --color-background-primary: #ffffff;
            --color-text-primary: #111827;
            --color-text-secondary: #4b5563;
            --color-text-tertiary: #9ca3af;
            --color-border-secondary: #e5e7eb;
            --color-border-tertiary: #f3f4f6;
            --border-radius-lg: 1rem;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: #f9fafb;
            margin: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            height: 100vh;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        @keyframes pulse-ring {
            0%   { transform: scale(0.92); opacity: 0.5; }
            50%  { transform: scale(1);    opacity: 1;   }
            100% { transform: scale(0.92); opacity: 0.5; }
        }
        @keyframes progress {
            0%   { width: 0%; }
            60%  { width: 85%; }
            90%  { width: 92%; }
            100% { width: 92%; }
        }
        .splash-card {
            max-width: 400px;
            width: 100%;
            margin: 20px;
            background: var(--color-background-primary);
            border: 1px solid var(--color-border-secondary);
            border-radius: var(--border-radius-lg);
            padding: 40px 36px 36px;
            text-align: center;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1);
        }
        .ring-outer {
            width: 64px; height: 64px;
            border: 2px solid var(--color-border-tertiary);
            border-radius: 50%;
            display: flex; align-items: center; justify-content: center;
            animation: pulse-ring 2.4s ease-in-out infinite;
            margin: 0 auto 28px;
        }
        .ring-spin {
            width: 44px; height: 44px;
            border: 2px solid var(--color-border-secondary);
            border-top-color: var(--color-text-primary);
            border-radius: 50%;
            animation: spin 1s linear infinite;
        }
        .service-label {
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 0.1em;
            text-transform: uppercase;
            color: var(--color-text-tertiary);
            margin-bottom: 8px;
        }
        .service-name {
            font-size: 20px;
            font-weight: 600;
            color: var(--color-text-primary);
            margin-bottom: 28px;
        }
        .status-row {
            display: flex; align-items: center; justify-content: center; gap: 8px;
            margin-bottom: 28px;
        }
        .status-dot {
            width: 6px; height: 6px; border-radius: 50%;
            background: var(--color-text-secondary);
            animation: pulse-ring 2.4s ease-in-out infinite;
        }
        .status-text {
            font-size: 13px;
            color: var(--color-text-secondary);
        }
        .progress-track {
            height: 2px;
            background: var(--color-border-tertiary);
            border-radius: 99px;
            overflow: hidden;
        }
        .progress-bar {
            height: 100%;
            background: var(--color-text-primary);
            border-radius: 99px;
            animation: progress 3s ease-in-out infinite;
            width: 0%;
        }
        .footer {
            margin-top: 28px;
            padding-top: 20px;
            border-top: 1px solid var(--color-border-tertiary);
            font-size: 12px;
            color: var(--color-text-tertiary);
        }
    </style>
    <script>
        let attempts = parseInt(new URLSearchParams(window.location.search).get('retry') || '0');
        if (attempts >= 10) {
            document.addEventListener('DOMContentLoaded', () => {
                document.querySelector('.status-text').textContent = 'Service failed to start. Please contact the administrator.';
                const dot = document.querySelector('.status-dot');
                if (dot) { dot.style.animation = 'none'; dot.style.background = '#ef4444'; }
            });
        } else {
            let delay = Math.min(2000 * Math.pow(2, attempts), 16000);
            setTimeout(() => {
                let url = new URL(window.location);
                url.searchParams.set('retry', attempts + 1);
                window.location.href = url.toString();
            }, delay);
        }
    </script>
</head>
<body>
    <div class="splash-card">
        <div class="ring-outer">
            <div class="ring-spin"></div>
        </div>
        <div class="service-label">Starting service</div>
        <div class="service-name">{name}</div>
        <div class="status-row">
            <div class="status-dot"></div>
            <span class="status-text">Waking container from idle state</span>
        </div>
        <div class="progress-track">
            <div class="progress-bar"></div>
        </div>
        <div class="footer">
            This page refreshes automatically &nbsp;·&nbsp; Wake-On-Request
        </div>
    </div>
</body>
</html>
]]

local function render_splash(name)
    ngx.status = ngx.HTTP_OK
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.header.cache_control = "no-store"
    local html = SPLASH_TEMPLATE:gsub("{name}", name)
    ngx.say(html)
end

-- Raw HTTP/1.0 over the Unix socket.
-- Returns: status_code (int|nil), body (string), err (string|nil)
-- Optional timeout in milliseconds (defaults to 15000)
-- Raw HTTP request over the Docker Unix socket.
-- @param method string: HTTP method (GET, POST, etc.)
-- @param path string: Docker API path (e.g., "/containers/json")
-- @param body string (optional): JSON payload for POST requests
-- @param timeout number (optional): Socket timeout in milliseconds
-- @return status_code number|nil, body string, err string|nil
local function docker_request(method, path, body, timeout)
    local sock = ngx.socket.tcp()
    sock:settimeout(timeout or 15000)

    local ok, err = sock:connect("unix:" .. _M.DOCKER_SOCKET)
    if not ok then return nil, "", "socket connect: " .. (err or "?") end

    local extra_headers = ""
    local payload = body or ""
    if body then
        extra_headers = "Content-Length: " .. #payload .. "\r\nContent-Type: application/json\r\n"
    end

    local req = method .. " " .. path .. " HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n" .. extra_headers .. "\r\n" .. payload
    local _, werr = sock:send(req)
    if werr then sock:close(); return nil, "", "socket send: " .. werr end

    local status_line = sock:receive("*l")
    if not status_line then sock:close(); return nil, "", "no response" end
    local code = tonumber(status_line:match("HTTP/%d%.%d (%d+)"))

    local headers = {}
    while true do
        local line = sock:receive("*l")
        if not line or line == "" then break end
        -- Fix \r bug by stripping trailing whitespace
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then headers[k:lower()] = v:lower() end
    end

    local resp = ""
    local is_chunked = headers["transfer-encoding"] == "chunked"
    local len = tonumber(headers["content-length"])

    if is_chunked then
        local chunks = {}
        while true do
            local chunk_len_str = sock:receive("*l")
            if not chunk_len_str then break end
            local chunk_len = tonumber(chunk_len_str:match("^(%x+)"), 16)
            if not chunk_len or chunk_len == 0 then break end
            
            local chunk_data = sock:receive(chunk_len)
            if chunk_data then table.insert(chunks, chunk_data) end
            sock:receive(2) -- read trailing \r\n
        end
        resp = table.concat(chunks)
    elseif len and len > 0 then
        resp = sock:receive(len) or ""
    else
        local data, _, partial = sock:receive("*a")
        resp = data or partial or ""
    end

    sock:close()
    return code, resp, nil
end

-- ── Container introspection ───────────────────────────────────────────────────

-- Fetches full container metadata from Docker API.
-- @param name string: Container name or ID
-- @return table|nil, err string|nil
local function inspect(name)
    local code, body, err = docker_request("GET", "/containers/" .. name .. "/json")
    if err then return nil, err end
    if code ~= 200 then return nil, "Docker API error " .. code end
    return json.decode(body)
end

-- Fast status check for a container.
-- @param name string: Container name or ID
-- @return status string|nil, err string|nil
local function get_state(name)
    local data, err = inspect(name)
    if err then return nil, err end
    return data.State and data.State.Status, nil
end


-- Scans all Docker containers to find those opted-in via labels.
-- Used by the background timer to start idle-stop logic.
-- @return table|nil, err string|nil
local function discover_managed_containers()
    -- Use Docker API filter to only fetch containers with our enable label.
    -- This is much more efficient than fetching all containers.
    local filter = json.encode({ label = { [_M.LABEL_ENABLE .. "=true"] = true } })
    local path = "/containers/json?all=1&filters=" .. ngx.escape_uri(filter)

    local code, body, err = docker_request("GET", path)
    if err then return nil, err end
    if code ~= 200 then return nil, "Docker API returned " .. code end

    local list, jerr = json.decode(body)
    if not list then return nil, "JSON decode: " .. (jerr or "?") end

    local result = {}
    for _, c in ipairs(list) do
        local raw_name = c.Names and c.Names[1] or ""
        local name = raw_name:match("^/(.+)$") or raw_name
        local labels = c.Labels or {}
        local domain = labels[_M.LABEL_DOMAIN]
        local idle  = tonumber(labels[_M.LABEL_IDLE])  or _M.DEFAULT_IDLE
        local start = tonumber(labels[_M.LABEL_START]) or _M.DEFAULT_START
        if name ~= "" then
            table.insert(result, { name = name, idle = idle, start = start, domain = domain })
        end
    end
    return result, nil
end

-- ── Container control ─────────────────────────────────────────────────────────

local function start_container(name)
    local code, _, err = docker_request("POST", "/containers/" .. name .. "/start")
    return (code == 204 or code == 304), err
end

local function stop_container(name)
    local code, _, err = docker_request("POST", "/containers/" .. name .. "/stop?t=10", nil, 20000)
    return (code == 204 or code == 304), err
end

-- ── Readiness poll ────────────────────────────────────────────────────────────

-- Polls a container until it is running, healthy, and optionally accepting connections.
-- @param name string: Container name or ID
-- @param start_timeout number: Max seconds to wait
-- @param target_port string (optional): Port to probe for TCP connectivity
-- @param hint_ip string (optional): Previously known IP to prefer over DNS
-- @return boolean, err string|nil
local function wait_until_ready(name, start_timeout, target_port, hint_ip, poll_interval)
    local timeout  = start_timeout or _M.DEFAULT_START
    local deadline = ngx.now() + timeout

    while ngx.now() < deadline do
        local data, err = inspect(name)
        if not err and data and data.State then
            local st = data.State.Status
            if st == "running" then
                local healthy = true
                -- Respect Docker Healthcheck if present
                if data.State.Health then healthy = (data.State.Health.Status == "healthy") end

                if healthy and target_port then
                    -- Extract internal IP for a direct TCP probe (bypasses DNS lag)
                    local ip = nil
                    if data.NetworkSettings and data.NetworkSettings.Networks then
                        for _, net in pairs(data.NetworkSettings.Networks) do
                            if net.IPAddress and net.IPAddress ~= "" then
                                ip = net.IPAddress; break
                            end
                        end
                    end

                    local sock = ngx.socket.tcp()
                    sock:settimeout(500)
                    -- Prefer known IP (hint or discovered) over DNS name
                    local probe_host = hint_ip or ip or name
                    local pok, _ = sock:connect(probe_host, target_port)
                    if pok then sock:close(); return true end
                elseif healthy then return true end
            elseif st == "exited" or st == "dead" then return false, "exited" end
        end
        ngx.sleep(poll_interval or _M.POLL_INTERVAL)
    end
    return false, "timeout"
end

-- ── Shared-dict helpers ───────────────────────────────────────────────────────

local function shared_set(key, value, ttl)
    local d = ngx.shared[_M.SHARED_DICT]
    if d then
        local success, err = d:set(key, value, ttl or 0)
        if not success then
            ngx.log(ngx.WARN, "[wakeonrequest] shared_set failed for '", key, "': ", err)
        end
    end
end

local function shared_get(key)
    local d = ngx.shared[_M.SHARED_DICT]
    return d and d:get(key)
end

local function shared_del(key)
    local d = ngx.shared[_M.SHARED_DICT]
    if d then d:delete(key) end
end

local function touch(name)
    shared_set("seen:" .. name, ngx.now())
end

-- ── Idle-stop timer ───────────────────────────────────────────────────────────

local function schedule_check(name, idle_timeout, timer_interval)
    ngx.timer.at(timer_interval or _M.TIMER_INTERVAL, function(premature)
        if premature or not shared_get("timer_active:" .. name) then return end
        local state, state_err = get_state(name)
        if not state_err and state == "running" then
            local last = shared_get("seen:" .. name)
            if last and (ngx.now() - last) > idle_timeout then
                ngx.log(ngx.INFO, "[wakeonrequest] stopping idle container: ", name)
                local stopped, stop_err = stop_container(name)
                if not stopped then
                    ngx.log(ngx.WARN, "[wakeonrequest] idle stop failed for '", name, "': ", stop_err)
                else
                    shared_del("seen:" .. name)
                    shared_del("timer_active:" .. name)
                    return
                end
            end
        end
        schedule_check(name, idle_timeout, timer_interval)
    end)
end

-- Background worker that monitors a single container for inactivity.
-- @param name string: Container name or ID
-- @param idle_timeout number: Seconds of inactivity before stopping
_M.RESCAN_INTERVAL = 120
-- Master background loop (runs once on worker 0).
-- Responsibilities:
-- 1. Scan for newly enabled containers (labels).
-- 2. Scan for newly used containers (lua snippets).
-- 3. Perform idle-stop checks for all tracked containers in a single loop.
function _M.auto_start_timers()
    if ngx.worker.id() ~= 0 then return end
    ngx.timer.at(0, function()
        local registered = {}
        while true do
            local tracked = {}
            -- 1. Discover via Docker labels
            local containers = discover_managed_containers()
            if containers then
                for _, c in ipairs(containers) do
                    tracked[c.name] = { idle = c.idle, timer = _M.TIMER_INTERVAL }
                    if c.domain and c.domain ~= "" then
                        for d in string.gmatch(c.domain, "([^,]+)") do
                            local clean_d = d:match("^%s*(.-)%s*$")
                            if clean_d ~= "" then
                                shared_set("domain:" .. clean_d, c.name)
                            end
                        end
                    end
                end
            end

            -- 2. Discover via Shared Dict (containers configured in NPM UI)
            local dict = ngx.shared[_M.SHARED_DICT]
            if dict and dict.get_keys then
                for _, k in ipairs(dict:get_keys(0)) do
                    local name = k:match("^config:(.+)$")
                    if name then
                        local cfg = json.decode(shared_get(k) or "{}")
                        tracked[name] = {
                            idle = cfg.idle or _M.DEFAULT_IDLE,
                            timer = cfg.timer or _M.TIMER_INTERVAL
                        }
                    end
                end
            end

            -- 3. Initialize background timers for new containers
            for name, cfg in pairs(tracked) do
                if not registered[name] then
                    registered[name] = true
                    shared_set("timer_active:" .. name, true)
                    schedule_check(name, cfg.idle, cfg.timer)
                end
            end

            ngx.sleep(_M.RESCAN_INTERVAL)
        end
    end)
end

-- ── Main Entrypoint ──────────────────────────────────────────────────────────

-- Core logic called during the Nginx access phase.
-- Handles: auto-discovery, cold-start, splash page, and route resolution.
-- @param name string|nil: Explicit container name (optional)
-- @param opts table (optional): Override defaults (idle_timeout, start_timeout, splash, auto_port, use_ip)
function _M.wake(name, opts)
    -- Robust name detection with first-label stripping for host header
    if not name or name == "" then
        local host = ngx.var.host and ngx.var.host:match("^([^.]+)")
        name = ngx.var.forward_host or ngx.var.server or host
    end
    if not name or name == "" then ngx.exit(500); return end

    -- Core optimization: single inspect call
    local data, inspect_err = inspect(name)
    if inspect_err then
        ngx.log(ngx.ERR, "[wakeonrequest] inspect failed for '", name, "': ", inspect_err)
        ngx.exit(ngx.HTTP_BAD_GATEWAY)
        return
    end

    if opts and type(opts) == "table" then
        shared_set("config:" .. name, json.encode({
            idle = tonumber(opts.idle_timeout),
            start = tonumber(opts.start_timeout),
            timer = tonumber(opts.timer_interval),
            poll = tonumber(opts.poll_interval)
        }), _M.RESCAN_INTERVAL * 3)
    end

    local start_timeout = _M.DEFAULT_START
    if opts and opts.start_timeout then
        start_timeout = tonumber(opts.start_timeout)
    elseif data.Config and data.Config.Labels then
        start_timeout = tonumber(data.Config.Labels[_M.LABEL_START]) or _M.DEFAULT_START
    end

    local target_ip = nil
    if data.Config and data.Config.Labels and data.Config.Labels["wakeonrequest.probe_host"] then
        target_ip = data.Config.Labels["wakeonrequest.probe_host"]
    elseif data.NetworkSettings and data.NetworkSettings.Networks then
        for _, net in pairs(data.NetworkSettings.Networks) do
            if net.IPAddress and net.IPAddress ~= "" then
                target_ip = net.IPAddress; break
            end
        end
    end

    local detected_port = nil
    if data.Config then
        detected_port = (data.Config.Labels and data.Config.Labels["wakeonrequest.port"]) or nil
        if not detected_port and data.Config.ExposedPorts then
            local ports = {}
            for p, _ in pairs(data.Config.ExposedPorts) do
                local pnum = p:match("^(%d+)/"); if pnum then table.insert(ports, pnum) end
            end
            if #ports == 1 then detected_port = ports[1] end
        end
    end

    local state = data.State and data.State.Status
    touch(name)

    -- ── Handle Cold Start / Startup Wait ────────────────────────────────────
    local lock_key = "starting:" .. name
    local splash_key = "splash:" .. name
    local dict = ngx.shared[_M.SHARED_DICT]

    local splash_enabled = true
    if opts and opts.splash ~= nil then
        splash_enabled = (opts.splash == true)
    end

    if state ~= "running" or shared_get(splash_key) then
        -- Only the first request triggers the actual 'docker start' command
        if state ~= "running" and dict and dict:add(lock_key, true, start_timeout + 5) then
            if splash_enabled then shared_set(splash_key, true, start_timeout + 10) end
            local ok, start_err = start_container(name)
            if not ok then
                shared_del(lock_key)
                shared_del(splash_key)
                ngx.log(ngx.ERR, "[wakeonrequest] docker start failed for '", name, "': ", start_err)
                ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
                return
            end
            ngx.sleep(0.5)
        end

        -- Everyone (first request AND subsequent splash reloads) waits for readiness
        local wait_limit = splash_enabled and 0.5 or start_timeout
        local poll_interval = opts and tonumber(opts.poll_interval) or nil
        local ready, wait_err = wait_until_ready(name, wait_limit, detected_port, target_ip, poll_interval)

        if not ready then
            if splash_enabled then
                -- Still serve splash; user's browser will auto-refresh and hit this again
                render_splash(name)
                ngx.exit(ngx.HTTP_OK)
                return
            end
            shared_del(lock_key)
            shared_del(splash_key)
            ngx.log(ngx.ERR, "[wakeonrequest] '", name, "' did not become ready: ", wait_err)
            ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
            return
        end

        -- Ready! Cleanup locks
        shared_del(lock_key)
        shared_del(splash_key)
    end
    -- Clean up the 'retry' query parameter from splash page before final proxying
    -- to prevent it from leaking into the backend application logs/logic.
    -- Note: This only runs on the happy path. The splash page handles its own
    -- retry parameter cleanup via client-side JS redirects.
    local args = ngx.req.get_uri_args()
    if args.retry then
        args.retry = nil
        ngx.req.set_uri_args(args)
    end

    ngx.log(ngx.INFO, "[wakeonrequest] '", name, "' ready")
end

-- Global entrypoint for use in /data/nginx/custom/server_proxy.conf
function _M.global_wake()
    local name = ngx.var.wake_container

    if not name or name == "" then
        local host = ngx.var.host
        if host then
            name = shared_get("domain:" .. host)
        end
    end

    if not name or name == "" then return end -- Not managed by WakeOnRequest

    local opts = {
        idle_timeout = ngx.var.wake_idle_timeout,
        start_timeout = ngx.var.wake_start_timeout,
        timer_interval = ngx.var.wake_timer_interval,
        poll_interval = ngx.var.wake_poll_interval,
        splash = (ngx.var.wake_splash ~= "false")
    }

    _M.wake(name, opts)
end

return _M

# Wake-On-Request

** DONT USE IT YET ***

[![Master](https://img.shields.io/badge/branch-master-blue.svg)](https://github.com/msenturk/wake-on-request)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Wake-On-Request** automatically puts your Docker/Podman containers to sleep when idle and wakes them up instantly when someone visits your website. It runs directly inside Nginx Proxy Manager (NPM)'s OpenResty process, requiring no sidecar containers.

---

## Features & Current Status

* **Zero-UI Configuration (Method A - Recommended)**: Configure containers entirely via Docker labels. The installer will patch your `docker-compose.yml` automatically.
* **NPM Advanced Tab Configuration (Method B)**: Configure containers in the NPM Web UI using simple Nginx variables (no complex Lua code blocks required).
* **Global Interception**: Incoming requests are intercepted globally via a single injection block. No individual proxy host needs custom Lua access blocks.
* **Cross-Network Support**: Fully supports containers running on different networks or using `network_mode: host` via TCP readiness probes targeted at host IPs and published ports.
* **Automated SQLite Database Cleanup**: The installer automatically scans NPM's SQLite database to detect and clean up old, deprecated inline Lua access blocks.
* **Interactive CLI Installer**: Scans the Docker daemon, matches container IPs/ports against NPM proxy hosts, prompts for the preferred configuration method, previews changes, and takes timestamped backups of all files before modifying them.
* **Performance & Stability**: Timer scheduling is non-blocking to prevent OpenResty pool exhaustion, uses bounded TTL memory keys, and handles container startup failures gracefully with a retry-capped splash screen.

---

## Phase 1: Installation & Setup

Run these steps in the directory where your Nginx Proxy Manager `docker-compose.yml` is located.

### 1. Run the Installer
Run the script to download the engine files, scan your containers, and inject the global volume mounts into your NPM service definition:

```bash
# Run interactively (will prompt to configure discovered containers)
curl -sSL https://raw.githubusercontent.com/msenturk/wake-on-request/master/install.sh | bash
```

#### Advanced CLI Options:
If you download the script locally, you can use the following flags:
```bash
# Download the installer
curl -O https://raw.githubusercontent.com/msenturk/wake-on-request/master/install.sh
chmod +x install.sh

# 1. Target a specific NPM directory
./install.sh /path/to/nginx-proxy-manager

# 2. Preview proposed changes and container setup without writing files
./install.sh --dry-run

# 3. Manually specify the NPM container name or ID
./install.sh --npm my-custom-npm-container
```

### 2. Apply NPM Changes
Restart your NPM stack to load the Wake-On-Request OpenResty plugin:
```bash
docker compose up -d
```

---

## Phase 2: Container Configuration

To manage a container, ensure its restart policy is set to `restart: "no"` (so Wake-On-Request can keep it stopped when idle) and configure it using one of the two methods below.

### Method A: Docker Labels (Recommended - Zero UI Config)
Add configuration parameters directly to your app's `docker-compose.yml` file. No changes are needed in Nginx Proxy Manager.

```yaml
services:
  my-app:
    image: my-app:latest
    container_name: my-app
    restart: "no"  # <--- Required: Do not use 'always' or 'unless-stopped'
    expose:
      - "8080"
    labels:
      - "wakeonrequest.enable=true"
      - "wakeonrequest.domain=app.example.com"             # Comma-separated for multiple domains
      - "wakeonrequest.idle_timeout=300"                  # Optional: seconds of inactivity before stop (default: 300s)
      - "wakeonrequest.start_timeout=30"                  # Optional: max seconds to wait on wake (default: 30s)
      - "wakeonrequest.probe_host=192.168.1.103"          # Optional: Host IP if container is on a different network
      - "wakeonrequest.port=8080"                         # Optional: Published port if on a different network
    networks:
      - npm_proxy
```
*Apply with:* `docker compose up -d --force-recreate my-app`

---

### Method B: NPM Advanced Tab (Variable Override)
If you prefer not to add labels to your container, you can configure it entirely inside Nginx Proxy Manager's Web UI. 

1. Edit your **Proxy Host** in the NPM Admin dashboard.
2. Go to the **Advanced Tab** and paste the Nginx variable definitions:

```nginx
set $wake_container      "my-container-name";   # Required
set $wake_idle_timeout   300;                  # Optional (default: 300s)
set $wake_start_timeout  30;                   # Optional (default: 30s)
set $wake_probe_host     "192.168.1.103";      # Optional: Host IP (for cross-network setups)
set $wake_port           8080;                 # Optional: Published port (for cross-network setups)
set $wake_splash         "true";               # Optional: Show loading page (default: true)
```
3. Save the Proxy Host.

---

## Configuration Reference

| Option | Nginx Variable | Default | Description |
| :--- | :--- | :--- | :--- |
| `wakeonrequest.enable` | - | - | Set to `true` to opt-in the container for management. |
| `wakeonrequest.domain` | - | - | Comma-separated domains mapped to this container. |
| `wakeonrequest.idle_timeout` | `$wake_idle_timeout` | `300` | Inactivity duration in seconds before stopping the container. |
| `wakeonrequest.start_timeout` | `$wake_start_timeout` | `30` | Maximum seconds to wait for readiness probes on startup. |
| `wakeonrequest.probe_host` | `$wake_probe_host` | *Container name* | Target hostname/IP for TCP connectivity readiness check. |
| `wakeonrequest.port` | `$wake_port` | *Exposed port* | Port number for the TCP connectivity readiness check. |
| - | `$wake_splash` | `"true"` | Set to `"false"` to disable showing the waking-up splash screen. |
| - | `$wake_timer_interval` | `60` | Background loop check frequency for idle containers. |
| - | `$wake_poll_interval` | `0.5` | Readiness probe retry interval during container startup. |

---

## Troubleshooting

### 1. View Engine Logs
Watch logs in real-time to debug wake-up and sleep lifecycles:
```bash
# General Docker logs
docker logs -f nginx-proxy-manager 2>&1 | grep wakeonrequest

# Detailed Nginx error logs (contains OpenResty lua errors)
docker exec -it nginx-proxy-manager tail -f /data/logs/fallback_error.log
```

### 2. Docker Socket Permission Error
If you see permission denied warnings or docker connection failures in your logs:
```bash
sudo chmod 666 /var/run/docker.sock
```

### 3. Log Management
Custom logs are stored in standard locations. To prevent log exhaustion:
* **Manual clear**:
  ```bash
  docker exec nginx-proxy-manager sh -c "truncate -s 0 /data/logs/fallback_error.log"
  ```
* **Auto rotation** (add to NPM service's `docker-compose.yml` logging block):
  ```yaml
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"
  ```

---

## License

MIT License. See [LICENSE](LICENSE) for details.

# Wake-On-Request

[![Master](https://img.shields.io/badge/branch-master-blue.svg)](https://github.com/msenturk/wake-on-request)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Wake-On-Request** automatically puts your Docker containers to sleep when idle and wakes them up instantly when someone visits your website. It runs directly inside Nginx Proxy Manager (NPM).

## Recent Improvements
- **Complex `docker-compose.yml` Support**: The installer now smartly handles multi-service compose files without corrupting them. It validates YAML parsing and gracefully falls back to manual insertion if needed.
- **Improved Performance & Stability**: Upgraded background timers to use non-blocking recursive scheduling, preventing OpenResty timer pool exhaustion.
- **Robust Error Handling**: Added explicit timeouts for Docker API calls and better logging for transient API errors during container spin-up.
- **Bounded Memory Usage**: Added TTLs to shared dictionary keys to ensure memory scales predictably even on highly active reverse proxies.
- **Splash Screen Reliability**: The splash screen now has a maximum retry cap (10 attempts) to prevent infinite loops if a container fails to start, displaying a clear error message instead.

---

## Phase 1: Initial Setup 

Run these steps in the folder where your Nginx Proxy Manager `docker-compose.yml` is located.

### 1. Run the Installer
This script creates the necessary files and safely adds the required volume mounts to your `docker-compose.yml`.

Run it in your NPM directory:
```bash
curl -sSL https://raw.githubusercontent.com/msenturk/wake-on-request/master/install.sh | bash
```

**Advanced Installation Options:**
You can download the script and pass a target directory or use the `--dry-run` flag to verify what changes will be made without modifying any files.
```bash
# Download the script first
curl -O https://raw.githubusercontent.com/msenturk/wake-on-request/master/install.sh
chmod +x install.sh

# Install to a specific NPM directory
./install.sh /path/to/nginx-proxy-manager

# Verify installation correctness (Safe, no changes made)
./install.sh /path/to/nginx-proxy-manager --dry-run
```

### 2. Apply Changes
Restart your NPM stack to enable the Wake-On-Request engine:
```bash
docker compose up -d
```

---

## Phase 2: Add your Apps (For every new app)

To manage an app with Wake-On-Request, you must configure both the app's Docker container and the NPM Proxy Host.

### Step 1: Prepare the App (Mandatory `docker-compose.yml` changes)
Wake-On-Request cannot manage a container if Docker is constantly trying to restart it, or if NPM cannot reach it over the network. 

Ensure your app's `docker-compose.yml` has **`restart: "no"`** and is in the **same network** as NPM.
```yaml
services:
  my-app:
    container_name: my-app  # <--- Remember this name
    restart: "no"           # <--- Mandatory: Do not use 'always' or 'unless-stopped'
    networks:
      - npm_proxy           # <--- Mandatory: Must match your NPM network
```
*Note: If your container **cannot** be in the same network (e.g. using `network_mode: host`), see [Cross-Network Setup](#cross-network-setup-and-host-networking) below.*

### Step 2: Configure in NPM UI
1.  Open your **NPM Admin Dashboard**.
2.  **Add a Proxy Host** (or edit an existing one).
3.  Set **Forward Host** to your container name (e.g., `my-app`).
4.  Go to the **Advanced Tab** and paste this snippet:

```nginx
access_by_lua_block {
    require("wakeonrequest").wake("", { 
        idle_timeout  = 600,  -- Stop after 10 mins of inactivity
        splash        = true  -- Show the loading page
    })
}
```
5.  Click **Save**. That's it! Visit your domain and watch the container wake up.

---

## Options Reference

| Option | Default | Description |
| :--- | :--- | :--- |
| `idle_timeout` | `300` | Seconds of inactivity before stopping the container. |
| `start_timeout`| `30` | Max seconds to wait for the container to become healthy. |
| `splash` | `true` | Show the white "Waking up..." loading page to users. |
| `auto_port` | `true` | Automatically find the container's port (set to `false` for different networks). |
| `use_ip` | `false` | Force routing via Direct IP instead of DNS (container name). |
| `set_routing` | `true` | Overwrite Nginx routing variables. Set to `false` if using `network_mode: host`. |

---

## Troubleshooting

**1. Check the Logs**
If an app isn't waking up or you see a 502/500 error, watch the logs in real-time:
```bash
# General Docker logs
docker logs -f nginx-proxy-manager 2>&1 | grep wakeonrequest

# Detailed Nginx error logs (NPM specific)
docker exec -it nginx-proxy-manager tail -f /data/logs/fallback_error.log

# Podman users
podman exec -it nginx-proxy-manager tail -f /data/logs/fallback_error.log
```

**2. Permission Denied**
NPM needs access to the Docker socket. If you see permission errors in the logs, run:
```bash
sudo chmod 666 /var/run/docker.sock
```

**3. DNS / Networking**
By default, Wake-On-Request uses the **container name (DNS)** to reach your apps, which is the best practice for Docker/Podman networking. 

If DNS resolution is unstable or has high latency in your environment, Wake-On-Request will automatically fallback to the **Direct IP** of the container to ensure the request succeeds. You can force Direct IP usage by setting `use_ip = true` in the configuration.

**4. Managing Log Size**
NPM logs can grow over time. You can clear them manually or set up automatic rotation.

*Manual clear:*
```bash
docker exec nginx-proxy-manager sh -c "truncate -s 0 /data/logs/fallback_error.log"
```

*Automatic (Add to docker-compose.yml):*
```yaml
services:
  npm:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

---

## Advanced Scenarios

### Method B: Using Docker Labels
If you prefer keeping configuration in your YAML instead of the UI, add these labels to your container:
- `wakeonrequest.enable: "true"`
- `wakeonrequest.idle_timeout: "300"`

Then, in the NPM UI Advanced tab, just use: `access_by_lua_block { require("wakeonrequest").wake("container_name") }`

### Cross-Network Setup (and Host Networking)
If your containers are on a **different network** than NPM or are using **`network_mode: host`**, you must configure NPM to route by IP instead of DNS:
1.  Set **Forward Host** to your Host IP (e.g., `172.17.0.1` or `10.x.x.x`). Do NOT use the container name here.
2.  In the Lua snippet, provide the container name explicitly and disable automatic routing:
```nginx
access_by_lua_block {
    require("wakeonrequest").wake("real-container-name", { 
        auto_port   = false,
        set_routing = false 
    })
}
```

---

## License
MIT License. Free for personal and commercial use. See [LICENSE](LICENSE) for details.
[LICENSE](LICENSE) for details.

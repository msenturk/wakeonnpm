#!/usr/bin/env python3
# ==============================================================================
# Wake-On-Request Installer
# https://github.com/msenturk/wake-on-request
#
# Usage:
#   python3 install.py                     Install in current directory
#   python3 install.py /path/to/npm        Install in specified directory
#   python3 install.py --path /path/to/npm Target specific NPM directory
#   python3 install.py --dry-run           Preview what will change, no files written
#   python3 install.py --npm <container>   Manually specify the NPM container name/ID
#   python3 install.py -h, --help          Show this help message
# ==============================================================================

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

# ── Constants ──────────────────────────────────────────────────────────────────
REPO = "msenturk/wake-on-request"
BRANCH = "master"
RAW_BASE = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}"

# local_path → container_path
FILES: list[tuple[str, str]] = [
    ("wakeonrequest.lua", "/data/nginx/custom/wakeonrequest.lua"),
    ("npm-custom/http_top.conf", "/data/nginx/custom/http_top.conf"),
    ("npm-custom/server_proxy.conf", "/data/nginx/custom/server_proxy.conf"),
]
VOL_SOCK = "/var/run/docker.sock:/var/run/docker.sock"

SERVER_PROXY_CONF = """\
# ── Wake-On-Request: Global Interceptor ──────────────────────────────────────
# Injected into every NPM proxy-host server block via server_proxy.conf.
# Calls global_wake() which looks up the request host in the shared dict
# (populated from Docker labels) and starts the matching container if needed.
# No per-host NPM Advanced Tab configuration required.
access_by_lua_block {
    require("wakeonrequest").global_wake()
}
"""

# ── Terminal Output ────────────────────────────────────────────────────────────
class Console:
    """ANSI-colored terminal output helpers."""

    _enabled = sys.stdout.isatty()

    _RED    = "\033[0;31m"
    _GREEN  = "\033[0;32m"
    _BLUE   = "\033[0;34m"
    _YELLOW = "\033[1;33m"
    _BOLD   = "\033[1m"
    _NC     = "\033[0m"

    @classmethod
    def _c(cls, code: str, text: str) -> str:
        if cls._enabled:
            return f"{code}{text}{cls._NC}"
        return text

    @classmethod
    def section(cls, title: str) -> None:
        print(f"\n{cls._c(cls._BOLD + cls._BLUE, f'── {title} ──')}")

    @classmethod
    def ok(cls, msg: str) -> None:
        print(f"  {cls._c(cls._GREEN, f'✅ {msg}')}")

    @classmethod
    def warn(cls, msg: str) -> None:
        print(f"  {cls._c(cls._YELLOW, f'⚠️  {msg}')}")

    @classmethod
    def err(cls, msg: str) -> None:
        print(f"  {cls._c(cls._RED, f'❌ {msg}')}")

    @classmethod
    def info(cls, msg: str) -> None:
        print(f"  {cls._c(cls._BLUE, f'ℹ️  {msg}')}")

    @classmethod
    def change(cls, msg: str) -> None:
        print(f"  {cls._c(cls._YELLOW, f'📝 {msg}')}")

    @classmethod
    def bold(cls, text: str) -> str:
        return cls._c(cls._BOLD, text)

    @classmethod
    def green(cls, text: str) -> str:
        return cls._c(cls._GREEN, text)

    @classmethod
    def yellow(cls, text: str) -> str:
        return cls._c(cls._YELLOW, text)

    @classmethod
    def red(cls, text: str) -> str:
        return cls._c(cls._RED, text)

    @classmethod
    def blue(cls, text: str) -> str:
        return cls._c(cls._BLUE, text)

    @classmethod
    def banner(cls, title: str, color: str = "") -> None:
        color = color or (cls._BOLD + cls._BLUE)
        bar = cls._c(color, "════════════════════════════════════════")
        print(f"\n{bar}")
        print(f"{cls._c(color, f'  {title}')}")
        print(bar)


# ── Container Info ─────────────────────────────────────────────────────────────
@dataclass
class ContainerInfo:
    name: str = ""
    status: str = ""
    restart: str = ""
    network_mode: str = ""
    enabled: str = ""
    domain: str = ""
    idle_timeout: str = ""
    start_timeout: str = ""
    port_label: str = ""
    compose_config_files: str = ""
    compose_working_dir: str = ""
    compose_service: str = ""
    network_ids: list[str] = field(default_factory=list)
    exposed_ports: list[str] = field(default_factory=list)   # "80/tcp"
    published_ports: list[str] = field(default_factory=list) # "8080"
    ips: list[str] = field(default_factory=list)
    long_id: str = ""
    mounts: list[str] = field(default_factory=list)  # host bind-mount paths

    @property
    def restart_problematic(self) -> bool:
        return self.restart in ("always", "unless-stopped")

    @property
    def single_exposed_port(self) -> Optional[str]:
        if len(self.exposed_ports) == 1:
            return self.exposed_ports[0].split("/")[0]
        return None

    @property
    def single_published_port(self) -> Optional[str]:
        if len(self.published_ports) == 1:
            return self.published_ports[0]
        return None


# ── Docker / Podman Client ─────────────────────────────────────────────────────
class DockerClient:
    """Detects and wraps docker or podman CLI calls."""

    def __init__(self, cmd_override: str = "", npm_override: str = "") -> None:
        self._cmd: list[str] = []
        self._cmd_override = cmd_override
        self.npm_override = npm_override
        self._detected = False

    # ── Detection ─────────────────────────────────────────────────────────────
    def detect(self) -> bool:
        """Return True if a working container runtime was found."""
        if self._detected:
            return bool(self._cmd)

        # 1. Explicit override via env var or constructor
        if self._cmd_override:
            self._cmd = self._cmd_override.split()
            self._detected = True
            return True

        env_cmd = os.environ.get("DOCKER_CMD", "")
        if env_cmd:
            self._cmd = env_cmd.split()
            self._detected = True
            return True

        # 2. sudo context: prefer the runtime holding NPM (Unix only)
        if hasattr(os, "geteuid") and os.geteuid() == 0 and os.environ.get("SUDO_USER"):
            result = self._detect_sudo_context()
            if result:
                self._detected = True
                return True

        # 3. Standard detection
        result = self._detect_standard()
        self._detected = True
        return result

    def _run_quiet(self, cmd: list[str]) -> bool:
        try:
            subprocess.run(cmd, capture_output=True, check=True, timeout=5)
            return True
        except Exception:
            return False

    def _run_output(self, cmd: list[str]) -> str:
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return r.stdout.strip()
        except Exception:
            return ""

    def _has_npm(self, base_cmd: list[str]) -> bool:
        out = self._run_output(base_cmd + ["ps", "-a", "--format", "{{.Image}}"])
        return "nginx-proxy-manager" in out

    def _detect_standard(self) -> bool:
        has_podman = shutil.which("podman") is not None
        has_docker = shutil.which("docker") is not None

        npm_podman = has_podman and self._has_npm(["podman"])
        npm_docker = has_docker and self._has_npm(["docker"])

        if npm_podman and not npm_docker:
            self._cmd = ["podman"]; return True
        if npm_docker and not npm_podman:
            self._cmd = ["docker"]; return True

        # Fallback: running container count
        podman_count = len(self._run_output(["podman", "ps", "-q"]).splitlines()) if has_podman else 0
        docker_count = len(self._run_output(["docker", "ps", "-q"]).splitlines()) if has_docker else 0

        if podman_count > 0 and docker_count == 0:
            self._cmd = ["podman"]; return True
        if docker_count > 0 and podman_count == 0:
            self._cmd = ["docker"]; return True

        if has_docker and self._run_quiet(["docker", "ps"]):
            self._cmd = ["docker"]; return True
        if has_podman and self._run_quiet(["podman", "ps"]):
            self._cmd = ["podman"]; return True

        return False

    def _detect_sudo_context(self) -> bool:
        sudo_user = os.environ["SUDO_USER"]
        try:
            import pwd
            user_info = pwd.getpwnam(sudo_user)
            uid = user_info.pw_uid
            home = user_info.pw_dir
        except Exception:
            uid = 0
            home = f"/home/{sudo_user}"

        env = {"HOME": home, "XDG_RUNTIME_DIR": f"/run/user/{uid}"}
        env_list = [f"{k}={v}" for k, v in env.items()]

        for runtime in ("podman", "docker"):
            if not shutil.which(runtime):
                continue
            base = ["sudo", "-u", sudo_user, "env"] + env_list + [runtime]
            if self._has_npm(base):
                self._cmd = base
                return True

        for runtime in ("podman", "docker"):
            if not shutil.which(runtime):
                continue
            base = ["sudo", "-u", sudo_user, "env"] + env_list + [runtime]
            if self._run_quiet(base + ["ps"]):
                self._cmd = base
                return True

        return False

    # ── Public API ────────────────────────────────────────────────────────────
    @property
    def available(self) -> bool:
        return self.detect()

    def run(self, args: list[str], timeout: int = 15) -> str:
        if not self._cmd:
            return ""
        try:
            r = subprocess.run(
                self._cmd + args,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            return r.stdout
        except Exception:
            return ""

    def run_exec(self, container_id: str, args: list[str]) -> str:
        return self.run(["exec", container_id] + args, timeout=10)

    def container_ids(self) -> list[str]:
        out = self.run(["ps", "-a", "-q"])
        return [line.strip() for line in out.splitlines() if line.strip()]

    def find_npm_container(self) -> str:
        if self.npm_override:
            cid = self.run(["ps", "-q", "-f", f"name={self.npm_override}"]).strip().splitlines()
            if cid:
                return cid[0]
            cid = self.run(["ps", "-q", "-f", f"id={self.npm_override}"]).strip().splitlines()
            if cid:
                return cid[0]
            return self.npm_override

        # Try compose service first
        for svc in ("app", "nginx-proxy-manager"):
            cid = self.run(["compose", "ps", "-q", svc]).strip()
            if cid:
                return cid.splitlines()[0]

        # Scan all containers
        out = self.run(["ps", "-a", "--format", "{{.ID}}|{{.Image}}"])
        for line in out.splitlines():
            if "nginx-proxy-manager" in line:
                return line.split("|")[0].strip()

        return ""

    def inspect(self, cid: str) -> Optional[ContainerInfo]:
        raw = self.run(["inspect", cid])
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return None
        if not data:
            return None

        c = data[0]
        labels: dict = (c.get("Config") or {}).get("Labels") or {}
        net_settings: dict = c.get("NetworkSettings") or {}
        networks: dict = net_settings.get("Networks") or {}
        ports_map: dict = net_settings.get("Ports") or {}
        mounts: list = c.get("Mounts") or []
        hc: dict = c.get("HostConfig") or {}

        # Exposed ports (keys of ports_map)
        exposed = list(ports_map.keys())

        # Published ports (HostPort bindings)
        published: list[str] = []
        for bindings in ports_map.values():
            if not bindings:
                continue
            for b in bindings:
                if b and b.get("HostPort"):
                    published.append(b["HostPort"])

        # Bind-mount sources (skip anonymous volumes)
        mount_sources = [
            m["Source"]
            for m in mounts
            if m.get("Source") and "/containers/storage/volumes/" not in m.get("Source", "")
            and "/var/lib/docker/volumes/" not in m.get("Source", "")
        ]

        return ContainerInfo(
            name=c.get("Name", "").lstrip("/"),
            status=(c.get("State") or {}).get("Status", ""),
            restart=(hc.get("RestartPolicy") or {}).get("Name", ""),
            network_mode=hc.get("NetworkMode", ""),
            enabled=labels.get("wakeonrequest.enable", ""),
            domain=labels.get("wakeonrequest.domain", ""),
            idle_timeout=labels.get("wakeonrequest.idle_timeout", ""),
            start_timeout=labels.get("wakeonrequest.start_timeout", ""),
            port_label=labels.get("wakeonrequest.port", ""),
            compose_config_files=labels.get("com.docker.compose.project.config_files", ""),
            compose_working_dir=labels.get("com.docker.compose.project.working_dir", ""),
            compose_service=labels.get("com.docker.compose.service", ""),
            network_ids=[v.get("NetworkID", "") for v in networks.values()],
            exposed_ports=exposed,
            published_ports=published,
            ips=[v.get("IPAddress", "") for v in networks.values() if v.get("IPAddress")],
            long_id=c.get("Id", ""),
            mounts=mount_sources,
        )

    def network_ids_for(self, cid: str) -> list[str]:
        info = self.inspect(cid)
        return info.network_ids if info else []


# ── NPM Database ───────────────────────────────────────────────────────────────
class NpmDatabase:
    """Reads and writes the NPM SQLite database."""

    def __init__(self, docker: DockerClient, target_dir: Path, db_override: Optional[Path] = None) -> None:
        self._docker = docker
        self._target = target_dir
        self._db_override = db_override  # explicit sqlite file path from --path
        self._proxy_hosts: list[dict] = []  # [{domain_names, forward_host, forward_port}]
        self._fetched = False

    def _query_at(self, db_path: Path, sql: str, params: tuple = ()) -> list[tuple]:
        """Run SQL directly against a local SQLite file."""
        try:
            with sqlite3.connect(str(db_path)) as conn:
                return conn.execute(sql, params).fetchall()
        except Exception:
            return []

    def _local_db(self) -> Optional[Path]:
        if self._db_override and self._db_override.exists():
            return self._db_override
        for candidate in (
            self._target / "database.sqlite",
            self._target / "data" / "database.sqlite",
        ):
            if candidate.exists():
                return candidate
        return None

    def _query_local(self, sql: str, params: tuple = ()) -> list[tuple]:
        db = self._local_db()
        if not db:
            return []
        return self._query_at(db, sql, params)

    def _find_npm_db_via_inspect(self, npm_cid: str) -> Optional[Path]:
        """Inspect the NPM container to find its /data bind-mount host path.

        This is the most portable strategy — it reads the DB file directly
        from the host filesystem without needing any tools inside the container.
        Works with Docker, Podman, rootless, rootful.
        """
        out = self._docker.run(["inspect", "--format", "{{json .Mounts}}", npm_cid])
        if not out:
            return None
        try:
            mounts = json.loads(out.strip())
            for m in mounts:
                dest = m.get("Destination") or m.get("destination") or ""
                src  = m.get("Source")      or m.get("source")      or ""
                if dest == "/data" and src:
                    for candidate in (
                        Path(src) / "database.sqlite",
                        Path(src) / "data" / "database.sqlite",
                    ):
                        if candidate.exists():
                            return candidate
        except Exception:
            pass
        return None

    def _exec_query(self, npm_cid: str, sql: str) -> list[tuple]:
        """Run SQL against the NPM database via container exec.

        Tries in order:
          1. python3 inside the NPM container
          2. sqlite3 CLI inside the NPM container
          3. Throwaway Alpine container with --volumes-from (named-volume fallback)
        """
        sep = "\x1e"  # ASCII Record Separator — never appears in SQL text output

        # Strategy 1: python3 (present in jc21/nginx-proxy-manager images)
        py_cmd = (
            "import sqlite3,sys; conn=sqlite3.connect('/data/database.sqlite'); "
            f"rows=conn.execute({sql!r}).fetchall(); "
            "[sys.stdout.write('\x1e'.join(str(c) for c in r) + '\n') for r in rows]"
        )
        out = self._docker.run_exec(npm_cid, ["python3", "-c", py_cmd])
        if out and out.strip():
            return [tuple(line.split(sep)) for line in out.split("\n") if line.strip()]

        # Strategy 2: sqlite3 CLI inside the NPM container (Alpine-based images)
        out2 = self._docker.run_exec(
            npm_cid, ["sh", "-c", f"sqlite3 -separator '\x1e' /data/database.sqlite \"{sql}\""]
        )
        if out2 and out2.strip():
            return [tuple(line.split(sep)) for line in out2.split("\n") if line.strip()]

        # Strategy 3: throwaway Alpine container with --volumes-from
        #   Used when the DB is in a named Docker volume (no host path).
        return self._query_via_temp_container(npm_cid, sql, sep)

    def _query_via_temp_container(self, npm_cid: str, sql: str, sep: str = "\x1e") -> list[tuple]:
        """Spin up a minimal Alpine container with --volumes-from <npm_cid> and run sqlite3."""
        if not self._docker.available:
            return []
        cmd = self._docker._cmd + [
            "run", "--rm",
            "--volumes-from", npm_cid,
            "alpine:3.20",
            "sh", "-c",
            f"apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 -separator '{sep}' /data/database.sqlite \"{sql}\"",
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            out = result.stdout
            if out and out.strip():
                return [tuple(line.split(sep)) for line in out.split("\n") if line.strip()]
        except Exception:
            pass
        return []

    def _exec_write(self, npm_cid: str, sql: str) -> int:
        py_cmd = (
            "import sqlite3; conn=sqlite3.connect('/data/database.sqlite'); "
            f"cur=conn.execute({sql!r}); conn.commit(); print(cur.rowcount)"
        )
        out = self._docker.run_exec(npm_cid, ["python3", "-c", py_cmd])
        if out and out.strip():
            try:
                return int(out.strip())
            except ValueError:
                pass
        # Fallback: sqlite3 CLI
        out2 = self._docker.run_exec(
            npm_cid,
            ["sh", "-c", f"sqlite3 /data/database.sqlite \"{sql}; SELECT changes();\""]
        )
        try:
            return int(out2.strip().splitlines()[-1])
        except (ValueError, IndexError):
            pass
        # Fallback: temp Alpine container
        rows = self._query_via_temp_container(npm_cid, sql)
        return len(rows)  # rowcount not recoverable this way, but > 0 means success

    def fetch(self) -> None:
        if self._fetched:
            return
        self._fetched = True
        npm_cid = self._docker.find_npm_container() if self._docker.available else ""
        sql = "SELECT domain_names, forward_host, forward_port FROM proxy_host WHERE is_deleted=0"

        rows: list[tuple] = []

        if npm_cid:
            # Strategy 0: read DB directly from the host path found via container inspect.
            # Most reliable — no tools required inside the NPM container.
            db_path = self._find_npm_db_via_inspect(npm_cid)
            if db_path:
                Console.info(f"Reading NPM database from {db_path}")
                rows = self._query_at(db_path, sql)

            # Fallback: exec strategies (needed when DB is in a named Docker volume)
            if not rows:
                rows = self._exec_query(npm_cid, sql)

            if not rows:
                Console.warn(
                    "Could not read NPM database from container — "
                    "domain auto-detection will be skipped."
                )
                Console.info(
                    "  Tip: run the installer from your NPM data directory "
                    "(the one containing data/database.sqlite), "
                    "or pass --path /path/to/npm-data."
                )

        if not rows:
            rows = self._query_local(sql)

        self._proxy_hosts = [
            {"domain_names": r[0], "forward_host": str(r[1]), "forward_port": str(r[2])}
            for r in rows
            if len(r) >= 3
        ]

    def find_config_for(
        self, cname: str, ips: list[str], published_ports: list[str]
    ) -> Optional[dict]:
        """Return {domain, port, fwd_host, access_type} or None."""
        self.fetch()
        host_ip = _detect_host_ip()

        for row in self._proxy_hosts:
            fwd_host = row["forward_host"]
            fwd_port = row["forward_port"]
            raw_domains = row["domain_names"]

            access_type = ""
            matched = False

            if fwd_host == cname:
                matched = True
                access_type = "name"
            elif fwd_host in ips:
                matched = True
                access_type = "ip"
            elif fwd_host in (host_ip, "127.0.0.1", "localhost", "0.0.0.0"):
                if fwd_port in published_ports:
                    matched = True
                    access_type = "ip"

            if matched:
                try:
                    domains = json.loads(raw_domains)
                    first_domain = domains[0] if domains else ""
                except Exception:
                    first_domain = raw_domains.strip('[]"').split(",")[0].strip()

                return {
                    "domain": first_domain,
                    "port": fwd_port,
                    "fwd_host": fwd_host,
                    "access_type": access_type,
                }
        return None

    def count_old_snippets(self) -> Optional[int]:
        npm_cid = self._docker.find_npm_container() if self._docker.available else ""
        sql = "SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%'"
        if npm_cid:
            rows = self._exec_query(npm_cid, sql)
            if rows:
                try:
                    return int(rows[0][0])
                except (IndexError, ValueError):
                    pass
        rows = self._query_local(sql)
        if rows:
            try:
                return int(rows[0][0])
            except (IndexError, ValueError):
                pass
        return None

    def clear_old_snippets(self) -> Optional[int]:
        npm_cid = self._docker.find_npm_container() if self._docker.available else ""
        sql = "UPDATE proxy_host SET advanced_config = '' WHERE advanced_config LIKE '%wakeonrequest%'"
        if npm_cid:
            n = self._exec_write(npm_cid, sql)
            if n >= 0:
                return n
        rows = self._query_local(
            "SELECT COUNT(*) FROM proxy_host WHERE advanced_config LIKE '%wakeonrequest%'"
        )
        if not rows:
            return None
        db = self._local_db()
        if not db:
            return None
        try:
            with sqlite3.connect(str(db)) as conn:
                cur = conn.execute(sql)
                conn.commit()
                return cur.rowcount
        except Exception:
            return None


# ── Compose File Resolver ──────────────────────────────────────────────────────
class ComposeResolver:
    """Find the docker-compose.yml for a container using multiple fallback strategies."""

    _FILENAMES = [
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ]

    def resolve(
        self,
        config_files: str,
        working_dir: str,
        mounts: list[str],
    ) -> Optional[Path]:
        # Strategy 1: config_files label
        if config_files:
            p = self._wsl_path(config_files)
            if p and p.is_file():
                return p

        # Strategy 2: working_dir + common filenames
        if working_dir:
            wdir = self._wsl_path(working_dir)
            if wdir and wdir.is_dir():
                for name in self._FILENAMES:
                    candidate = wdir / name
                    if candidate.is_file():
                        return candidate

        # Strategy 3: Walk up from each bind mount (up to 4 parents)
        for mount_src in mounts:
            candidate = self._search_from_mount(mount_src)
            if candidate:
                return candidate

        # Strategy 4: Return translated path even if not found (for display)
        if config_files:
            return self._wsl_path(config_files)

        return None

    def _search_from_mount(self, mount_src: str) -> Optional[Path]:
        p = self._wsl_path(mount_src)
        if p is None:
            return None
        if p.is_file():
            p = p.parent
        depth = 0
        while p and p != p.parent and depth < 4:
            for name in self._FILENAMES:
                candidate = p / name
                if candidate.is_file():
                    return candidate
            p = p.parent
            depth += 1
        return None

    @staticmethod
    def _wsl_path(raw: str) -> Optional[Path]:
        """Return Path from a raw string, or None if empty."""
        return Path(raw) if raw else None


# ── Compose File Patcher ───────────────────────────────────────────────────────
class ComposePatcher:
    """Reads, validates, backs up, and patches docker-compose.yml."""

    def __init__(self, compose_path: Path) -> None:
        self.path = compose_path

    def validate(self) -> bool:
        """Return True if the file is parseable YAML with a services: block."""
        try:
            import importlib
            yaml_mod = importlib.import_module("yaml")
            try:
                with self.path.open() as f:
                    yaml_mod.safe_load(f)
                return True
            except Exception:
                return False
        except ImportError:
            pass
        # Fallback: basic structural check
        text = self.path.read_text()
        return "services:" in text

    def backup(self) -> Path:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        bak = self.path.with_suffix(f".yml.bak.{ts}.{os.getpid()}")
        shutil.copy2(self.path, bak)
        Console.info(f"Backed up {self.path.name} → {bak.name}")
        return bak

    def volumes_section_count(self) -> int:
        """Count top-level volumes: blocks (to detect multi-service compose files)."""
        text = self.path.read_text()
        return len(re.findall(r"^\s{2,}volumes:", text, re.MULTILINE))

    def has_volume(self, volume_string: str) -> bool:
        return volume_string in self.path.read_text()

    def add_volumes(self, volumes: list[str]) -> bool:
        """
        Idempotently add volumes under the first 'volumes:' block found under a service.
        Returns True if any change was made.
        """
        text = self.path.read_text()
        changed = False

        for vol in volumes:
            if vol in text:
                continue
            # Find first indented volumes: block and insert after it
            match = re.search(r"([ \t]+volumes:[ \t]*\n)", text)
            if match:
                indent = len(re.match(r"[ \t]*", match.group(1)).group(0))
                vol_indent = " " * (indent + 2)
                insertion = f"{vol_indent}- {vol}\n"
                pos = match.end()
                text = text[:pos] + insertion + text[pos:]
                changed = True

        if changed:
            self.path.write_text(text)
        return changed

    def add_labels_to_service(
        self,
        service_name: str,
        labels: list[str],
    ) -> bool:
        """
        Add wakeonrequest labels under a named service. Returns True if changed.
        Uses a safe regex approach that preserves all formatting.
        """
        text = self.path.read_text()

        if "wakeonrequest.enable" in text:
            return False  # Already configured

        # Find the service block
        svc_pattern = re.compile(
            r"(^  " + re.escape(service_name) + r":.*?\n)", re.MULTILINE
        )
        match = svc_pattern.search(text)
        if not match:
            return False

        # Check if this service already has a labels: block
        svc_start = match.end()
        # Find where the next service starts (4-space dedent)
        next_svc = re.search(r"^\S|\n  \S", text[svc_start:], re.MULTILINE)
        svc_block = text[svc_start: svc_start + (next_svc.start() if next_svc else len(text))]

        label_lines = "".join('      - "' + lbl + '"\n' for lbl in labels)

        if re.search(r"^\s{4,}labels:", svc_block, re.MULTILINE):
            # Append to existing labels block
            labels_match = re.search(r"(\s{4,}labels:\s*\n)", text[svc_start:])
            if labels_match:
                insert_pos = svc_start + labels_match.end()
                text = text[:insert_pos] + label_lines + text[insert_pos:]
                self.path.write_text(text)
                return True
        else:
            # Insert a new labels block after service name line
            insert_pos = match.end()
            text = text[:insert_pos] + "    labels:\n" + label_lines + text[insert_pos:]
            self.path.write_text(text)
            return True

        return False


# ── Utilities ──────────────────────────────────────────────────────────────────
def _detect_host_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        pass
    try:
        result = subprocess.run(
            ["ip", "route", "get", "1"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        m = re.search(r"src (\d+\.\d+\.\d+\.\d+)", result.stdout)
        if m:
            return m.group(1)
    except Exception:
        pass
    return "127.0.0.1"


def _is_ip(text: str) -> bool:
    return bool(re.fullmatch(r"\d+\.\d+\.\d+\.\d+", text.strip()))


def _backup_file(path: Path) -> None:
    if not path.exists():
        return
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    bak = path.with_suffix(f"{path.suffix}.bak.{ts}.{os.getpid()}")
    shutil.copy2(path, bak)
    Console.info(f"Backed up {path.name} → {bak.name}")


def _write_bundled_server_proxy(target: Path) -> None:
    if target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(SERVER_PROXY_CONF, encoding="utf-8")


# ── Forward Host Decision ──────────────────────────────────────────────────────
def _decide_forward_host(
    info: ContainerInfo,
    npm_network_ids: list[str],
    npm_config: Optional[dict],
) -> tuple[str, str, str]:
    """Return (fwd_host, fwd_port, fwd_note)."""
    if npm_config:
        fwd_host = npm_config["fwd_host"]
        fwd_port = npm_config["port"]
        note_suffix = (
            "accesses via container name"
            if npm_config["access_type"] == "name"
            else "accesses via IP"
        )
        return fwd_host, fwd_port, f"NPM database config — {note_suffix}"

    shares_network = bool(set(info.network_ids) & set(npm_network_ids))

    if info.network_mode == "host":
        return _detect_host_ip(), info.single_published_port or "<port>", "host network — NPM cannot route by name"
    if shares_network:
        return info.name, info.single_exposed_port or info.single_published_port or "<port>", "same network as NPM — use container name"

    return _detect_host_ip(), info.single_published_port or "<port>", "different network from NPM — use host IP"


# ── Dry Run ────────────────────────────────────────────────────────────────────
def run_dry_run(
    args: argparse.Namespace,
    docker: DockerClient,
    db: NpmDatabase,
) -> None:
    Console.banner("Wake-On-Request — Dry Run Preview")
    print(f"  Directory: {Path.cwd()}\n")

    any_change = False

    # ── Files ──────────────────────────────────────────────────────────────────
    Console.section("Files")
    for local_path, _ in FILES:
        p = Path(local_path)
        if not p.exists():
            if local_path == "npm-custom/server_proxy.conf":
                Console.change(f"Write     {local_path}   ← bundled in install.py")
            else:
                Console.change(f"Download  {local_path}   ← {RAW_BASE}/{p.name}")
            any_change = True
        else:
            Console.ok(f"Exists    {local_path}")

    # ── docker-compose.yml volumes ─────────────────────────────────────────────
    if Path("docker-compose.yml").exists():
        Console.section("docker-compose.yml — Volume Changes")
        patcher = ComposePatcher(Path("docker-compose.yml"))
        compose_clean = True
        for local_path, container_path in FILES:
            vol = f"./{local_path}:{container_path}"
            if not patcher.has_volume(vol):
                Console.change(f"ADD  - {vol}")
                compose_clean = False
                any_change = True
            else:
                Console.ok(f"OK   - {vol}")

        if not patcher.has_volume(VOL_SOCK):
            Console.change(f"ADD  - {VOL_SOCK}")
            compose_clean = False
            any_change = True
        else:
            Console.ok(f"OK   - {VOL_SOCK}")

        if not compose_clean:
            print()
            Console.info("These lines will be inserted under your NPM service's 'volumes:' block.")

    # ── Container Label Status ─────────────────────────────────────────────────
    Console.section("Container Label Status")
    if docker.available:
        db.fetch()
        npm_cid = docker.find_npm_container()
        npm_networks = docker.network_ids_for(npm_cid) if npm_cid else []
        resolver = ComposeResolver()

        for cid in docker.container_ids():
            info = docker.inspect(cid)
            if not info:
                continue

            # Skip NPM itself
            if npm_cid and (
                info.long_id == npm_cid
                or info.long_id.startswith(npm_cid)
                or npm_cid.startswith(info.long_id[:12])
            ):
                continue

            # Resolve compose file
            compose_path = resolver.resolve(
                info.compose_config_files,
                info.compose_working_dir,
                info.mounts,
            )

            # Already configured
            if info.enabled == "true" and info.domain:
                idle = info.idle_timeout or "300"
                start = info.start_timeout or "30"
                if info.restart_problematic:
                    Console.warn(
                        f"{Console.bold(info.name)}  →  domain: {info.domain}  |  "
                        f"idle: {idle}s  |  start: {start}s"
                    )
                    Console.err(
                        f'      restart: "{info.restart}" prevents idle stop → '
                        f'must be changed to "no" manually in docker-compose.yml'
                    )
                else:
                    Console.ok(
                        f"{Console.bold(info.name)}  →  domain: {info.domain}  |  "
                        f"idle: {idle}s  |  start: {start}s"
                    )
                continue

            if info.enabled == "true" and not info.domain:
                Console.warn(
                    f"{Console.bold(info.name)}  →  "
                    f"wakeonrequest.enable=true but MISSING wakeonrequest.domain label!"
                )
                continue

            # Not yet configured
            npm_config = db.find_config_for(info.name, info.ips, info.published_ports)
            fwd_host, fwd_port, fwd_note = _decide_forward_host(info, npm_networks, npm_config)

            status_tag = f"state: {info.status} | restart: {info.restart}"
            if info.network_mode == "host":
                status_tag += " | network: host"

            print()
            print(f"  {Console.yellow('➕')} {Console.bold(info.name)}  [{status_tag}]")

            if info.restart_problematic:
                restart_val = info.restart
                Console.err(f'restart: "{restart_val}" prevents idle stop \u2192 must be changed to "no"')

            print()
            print(f"     {Console.bold('── NPM Proxy Host settings ──')}")
            print(f"     Forward Host : {Console.green(fwd_host)}")
            if fwd_port and fwd_port != "<port>":
                src = npm_config["access_type"] if npm_config else "auto-detected"
                print(f"     Forward Port : {Console.green(fwd_port)}  {Console.blue(f'({src})')}")
            else:
                print(f"     Forward Port : {Console.yellow('<set manually>')}  {Console.blue('(could not auto-detect)')}")
            print(f"     Note         : {Console.blue(fwd_note)}")

            label_domain = (npm_config or {}).get("domain") or info.domain or "<your-domain.example.com>"

            print()
            # Method A block
            if compose_path and compose_path.is_file():
                if "wakeonrequest.enable" in compose_path.read_text():
                    Console.ok(f"Compose File : {Console.green('Already configured')} in {Console.blue(str(compose_path))}")
                else:
                    Console.change(f"Compose File : {Console.yellow('Will patch')} at {Console.blue(str(compose_path))}")
                    print()
                    bold_hdr = Console.bold('\u2500\u2500 Proposed changes for ' + str(compose_path) + ' (Method A) \u2500\u2500')
                    print(f"     {bold_hdr}")
            else:
                checked = str(compose_path) if compose_path else "none"
                Console.warn(f"Compose File : {Console.red('Not found')} (checked: {Console.yellow(checked)})")
                print()
                bold_hdr2 = Console.bold('\u2500\u2500 Add to ' + info.name + "'s docker-compose.yml manually (Method A) \u2500\u2500")
                print(f"     {bold_hdr2}")

            print()
            if info.restart_problematic:
                restart_src = info.restart

                print("     " + Console.yellow('restart: "no"') + "                                  " + Console.blue('# change from: ' + restart_src))
            print(f"     {Console.green('labels:')}")
            print("     " + Console.green('  - "wakeonrequest.enable=true"'))
            print("     " + Console.green('  - "wakeonrequest.domain=' + label_domain + '"') + "  " + Console.blue('# ← your NPM domain'))
            print("     " + Console.green('  - "wakeonrequest.idle_timeout=300"') + "                  " + Console.blue('# stop after 5 min idle'))
            print("     " + Console.green('  - "wakeonrequest.start_timeout=30"') + "                  " + Console.blue('# wait up to 30s on wake'))
            if _is_ip(fwd_host):
                print("     " + Console.green('  - "wakeonrequest.probe_host=' + fwd_host + '"'))
                print("     " + Console.green('  - "wakeonrequest.port=' + fwd_port + '"'))
            print()

            # Method B block (always shown in dry-run)
            print("     " + Console.bold('\u2500\u2500 NPM Advanced Tab Config (Method B) \u2500\u2500'))
            print()
            print("     " + Console.green('set $wake_container     "' + info.name + '";'))
            print("     " + Console.green('set $wake_idle_timeout  300;'))
            print("     " + Console.green('set $wake_start_timeout 30;'))
            if _is_ip(fwd_host):
                print("     " + Console.green('set $wake_probe_host    "' + fwd_host + '";') + "       " + Console.blue('# cross-network probe IP'))
                print("     " + Console.green('set $wake_port          ' + fwd_port + ';') + "    " + Console.blue('# cross-network probe port'))
            print()
    else:
        Console.warn("Docker socket or daemon not available — skipping container scan.")

    # ── NPM Database Status ────────────────────────────────────────────────────
    Console.section("NPM Database Status")
    count = db.count_old_snippets()
    if count is None:
        Console.info("No NPM database found or accessible — skipping database check.")
    elif count > 0:
        Console.change(f"NPM Database: Will clear old Lua snippets from {count} proxy host(s) in Advanced tab.")
    else:
        Console.ok("NPM Database: No old Lua snippets to clean.")

    # ── Summary ────────────────────────────────────────────────────────────────
    print()
    bar = Console._c(Console._BOLD + Console._BLUE, "════════════════════════════════════════")
    print(bar)
    if any_change:
        print(f"  {Console.yellow(Console.bold('Changes pending. To apply, run:'))}")
        print(f"  {Console.bold('  ./install.sh')}")
        print()
        print(f"  {Console.blue('Running without --dry-run will:')}")
        print(f"  {Console.blue('  • Download any missing files from GitHub')}")
        print(f"  {Console.blue('  • Write npm-custom/server_proxy.conf (bundled in this script)')}")
        print(f"  {Console.blue('  • Add the missing volume mounts to docker-compose.yml')}")
        print(f"  {Console.blue('  • Back up docker-compose.yml before editing it')}")
    else:
        print(f"  {Console.green('✨ Already up to date. No changes needed.')}")
    print(f"{bar}\n")


# ── Interactive Container Configuration ────────────────────────────────────────
def configure_containers(
    args: argparse.Namespace,
    docker: DockerClient,
    db: NpmDatabase,
) -> None:
    if not docker.available:
        Console.warn("Docker socket or daemon not available — skipping app container setup.")
        return

    Console.section("App Container Setup")
    db.fetch()

    npm_cid = docker.find_npm_container()
    npm_networks = docker.network_ids_for(npm_cid) if npm_cid else []
    resolver = ComposeResolver()
    any_unmanaged = False

    for cid in docker.container_ids():
        info = docker.inspect(cid)
        if not info:
            continue

        # Skip NPM
        if npm_cid and (
            info.long_id == npm_cid
            or info.long_id.startswith(npm_cid)
            or npm_cid.startswith(info.long_id[:12])
        ):
            continue

        # Already configured
        if info.enabled == "true" and info.domain:
            idle = info.idle_timeout or "300"
            start = info.start_timeout or "30"
            if info.restart_problematic:
                Console.warn(f"{Console.bold(info.name)}  already configured  →  domain: {info.domain}  |  idle: {idle}s  |  start: {start}s")
                Console.err(f'      restart: "{info.restart}" must be changed to "no" manually in docker-compose.yml')
            else:
                Console.ok(f"{Console.bold(info.name)}  already configured  →  domain: {info.domain}  |  idle: {idle}s  |  start: {start}s")
            continue

        any_unmanaged = True
        compose_path = resolver.resolve(
            info.compose_config_files,
            info.compose_working_dir,
            info.mounts,
        )

        npm_config = db.find_config_for(info.name, info.ips, info.published_ports)
        fwd_host, fwd_port, _ = _decide_forward_host(info, npm_networks, npm_config)

        default_domain = (npm_config or {}).get("domain") or info.domain or ""
        default_port = (npm_config or {}).get("port") or info.port_label or info.single_exposed_port or info.single_published_port or ""

        print()
        print(f"  {Console.yellow('➕')} {Console.bold(info.name)}  [state: {info.status} | restart: {info.restart}]")
        if default_domain:
            print(f"     NPM Domain       : {Console.green(default_domain)}")
        print(f"     NPM Forward Host : {Console.green(fwd_host)}")
        if default_port:
            print(f"     NPM Forward Port : {Console.green(default_port)}")
        else:
            print(f"     NPM Forward Port : {Console.yellow('<set manually>')}")
        if info.restart_problematic:
            restart_val = info.restart
            print("     " + Console.red('\u274c restart: "' + restart_val + '" must be changed to "no" manually'))
            print(f"        {Console.blue('(wake-on-request cannot stop containers with auto-restart)')}")

        # Choose method
        print()
        print(f"     Choose configuration method for {Console.bold(info.name)}:")
        print("       [1] Use Docker Labels (Method A — Recommended)")
        print("       [2] Use NPM Advanced Tab (Method B)")
        print("       [3] Skip this container")
        print()
        answer = _prompt("     Enter option [1-3] (default: 1): ", default="1")

        if answer == "3":
            Console.info(f"Skipped {info.name}")
            continue

        method = "B" if answer == "2" else "A"

        # Resolve domain
        if default_domain:
            user_domain = default_domain
        else:
            user_domain = ""
            while not user_domain:
                user_domain = _prompt(f"     NPM domain for {info.name} (e.g. app.example.com): ").strip()

        # Timeouts
        user_idle = _prompt("     Idle timeout in seconds [300]: ", default="300")
        user_start = _prompt("     Start timeout in seconds [30]: ", default="30")

        labels = [
            f"wakeonrequest.enable=true",
            f"wakeonrequest.domain={user_domain}",
            f"wakeonrequest.idle_timeout={user_idle}",
            f"wakeonrequest.start_timeout={user_start}",
        ]
        if _is_ip(fwd_host):
            labels += [
                f"wakeonrequest.probe_host={fwd_host}",
                f"wakeonrequest.port={default_port or '80'}",
            ]

        print()

        if method == "B":
            Console.info(f"Paste this into NPM's Advanced Tab for {Console.bold(user_domain)}:")
            print()
            print("     " + Console.green('set $wake_container     "' + info.name + '";'))
            print("     " + Console.green('set $wake_idle_timeout  ' + user_idle + ';'))
            print("     " + Console.green('set $wake_start_timeout ' + user_start + ';'))
            if _is_ip(fwd_host):
                probe_port = str(default_port) if default_port else '80'
                print("     " + Console.green('set $wake_probe_host    "' + fwd_host + '";') + "       " + Console.blue('# cross-network probe IP'))
                print("     " + Console.green('set $wake_port          ' + probe_port + ';') + "    " + Console.blue('# cross-network probe port'))
            if info.restart_problematic:
                Console.warn(f'Remember to change restart to "no" manually for {info.name} if needed')
            continue

        # Method A — patch compose file
        if compose_path and compose_path.is_file():
            cp = ComposePatcher(compose_path)
            if "wakeonrequest.enable" in compose_path.read_text():
                Console.warn(f"wakeonrequest labels already present in {compose_path} — skipping write.")
            else:
                confirm = _prompt(
                    f"\n     Apply these changes to {compose_path}? [Y/n] ",
                    default="y",
                ).lower()
                if confirm not in ("y", "yes", ""):
                    Console.info(f"Skipped writing to {compose_path}")
                    continue
                cp.backup()
                svc = info.compose_service or info.name
                changed = cp.add_labels_to_service(svc, labels)
                if changed:
                    Console.ok(f"Labels added to {compose_path}")
                else:
                    Console.warn(f"Could not auto-patch {compose_path} — add labels manually.")
                    _print_manual_snippet(info.restart, labels)

                if info.restart_problematic:
                    print()
                    Console.warn(f'Remember to change restart to "no" in {compose_path}')
                    Console.info(f"Apply with: docker compose up -d --force-recreate {info.name}")
                else:
                    print()
                    Console.info(f"Apply with: docker compose up -d --force-recreate {info.name}")
        else:
            if compose_path:
                Console.warn(f"Compose file not accessible at: {compose_path}")
            else:
                Console.warn(f"No compose file found for {info.name} (may have been started with docker run)")
            _print_manual_snippet(info.restart, labels)
            print()
            Console.info(f"Then run: docker compose up -d --force-recreate {info.name}")

    if not any_unmanaged:
        Console.ok("All containers are already configured.")


def _print_manual_snippet(restart: str, labels: list[str]) -> None:
    print()
    print("     " + Console.bold("Add this to the container's docker-compose.yml manually:"))
    print()
    if restart in ("always", "unless-stopped"):
        print("     " + Console.yellow('restart: "no"') + "  " + Console.blue('# change from: ' + restart))
    print("     " + Console.green('labels:'))
    for lbl in labels:
        print("     " + Console.green('  - "' + lbl + '"'))


def _prompt(msg: str, default: str = "") -> str:
    try:
        answer = input(msg).strip()
        return answer if answer else default
    except (EOFError, KeyboardInterrupt):
        return default


# ── Installation ───────────────────────────────────────────────────────────────
def run_install(
    args: argparse.Namespace,
    docker: DockerClient,
    db: NpmDatabase,
) -> None:
    Console.banner("Wake-On-Request Installer")
    print(f"  Directory: {Path.cwd()}\n")

    # ── Download files ─────────────────────────────────────────────────────────
    Console.section("Downloading Files")
    Path("npm-custom").mkdir(parents=True, exist_ok=True)

    # Write bundled server_proxy.conf first
    _write_bundled_server_proxy(Path("npm-custom/server_proxy.conf"))
    Console.ok("Bundled   npm-custom/server_proxy.conf (no download needed)")

    for local_path, _ in FILES:
        p = Path(local_path)
        if local_path == "npm-custom/server_proxy.conf":
            continue  # already written above

        remote_url = f"{RAW_BASE}/{local_path}"
        _backup_file(p)
        print(f"  Downloading {Console.bold(local_path)} ... ", end="", flush=True)
        try:
            with urllib.request.urlopen(remote_url, timeout=30) as resp:
                tmp = p.with_suffix(".tmp")
                tmp.write_bytes(resp.read())
                tmp.replace(p)
            print(Console.green("done"))
        except Exception as exc:
            print(Console.red("FAILED"))
            Console.err(f"Could not download {remote_url}")
            Console.err(f"Error: {exc}")
            Console.err("Check your internet connection or download manually:")
            Console.err(f"  curl -L {remote_url} -o {local_path}")
            sys.exit(1)

    Console.ok("All files ready.")

    # ── Patch docker-compose.yml ───────────────────────────────────────────────
    Console.section("Patching docker-compose.yml")
    patcher = ComposePatcher(Path("docker-compose.yml"))
    volumes_needed = [
        f"./{local_path}:{container_path}"
        for local_path, container_path in FILES
        if not patcher.has_volume(f"./{local_path}:{container_path}")
    ]
    if not patcher.has_volume(VOL_SOCK):
        volumes_needed.append(VOL_SOCK)

    if volumes_needed:
        if not patcher.validate():
            Console.warn("docker-compose.yml is not valid YAML — showing manual instructions:")
            _print_manual_volume_instructions(patcher, volumes_needed)
        elif patcher.volumes_section_count() > 1:
            Console.warn("Complex docker-compose.yml detected — showing manual instructions:")
            _print_manual_volume_instructions(patcher, volumes_needed)
        else:
            patcher.backup()
            patcher.add_volumes(volumes_needed)
            Console.ok("docker-compose.yml patched.")
    else:
        Console.ok("docker-compose.yml already configured — no changes needed.")

    # ── Clean NPM database snippets ────────────────────────────────────────────
    Console.section("Cleaning NPM Database")
    cleaned = db.clear_old_snippets()
    if cleaned is None:
        Console.info("No NPM database found or accessible — skipping cleanup.")
    elif cleaned > 0:
        Console.ok(f"Cleared old Lua snippets from {cleaned} proxy host(s).")
    else:
        Console.ok("No old snippets found — nothing to clean.")

    # ── Interactive container setup (interactive terminals only) ───────────────
    if sys.stdin.isatty() and sys.stdout.isatty():
        configure_containers(args, docker, db)
    else:
        Console.info("Non-interactive environment detected — skipping interactive app configuration.")

    # ── Next Steps ─────────────────────────────────────────────────────────────
    print()
    Console.banner("✨ Installation Complete!", color=Console._BOLD + Console._GREEN)
    print()
    print(f"  {Console.bold('Next Steps:')}")
    print()
    print(f"  {Console.bold('1.')} Restart NPM to load Wake-On-Request:")
    print(f"     {Console.blue('docker compose up -d')}")
    print()
    print(f"  {Console.bold('2.')} For each app, add labels to its docker-compose.yml:")
    print()
    print(f"     {Console.green('labels:')}")
    print("     " + Console.green('  - "wakeonrequest.enable=true"') + "             " + Console.blue('# required'))
    print("     " + Console.green('  - "wakeonrequest.domain=yourapp.example.com"') + "   " + Console.blue('# required'))
    print("     " + Console.green('  - "wakeonrequest.idle_timeout=300"') + "             " + Console.blue('# optional'))
    print("     " + Console.green('  - "wakeonrequest.start_timeout=30"') + "             " + Console.blue('# optional'))
    print("     " + Console.yellow('  restart: "no"') + "                                  " + Console.blue('# required \u2014 allows idle stop'))
    print()
    print(f"  {Console.bold('3.')} Recreate the app container:")
    print(f"     {Console.blue('docker compose up -d --force-recreate your-app')}")
    print()
    print(f"  {Console.bold('4.')} Run dry-run anytime to check status:")
    print(f"     {Console.blue('./install.sh --dry-run')}")
    print()


def _print_manual_volume_instructions(patcher: ComposePatcher, volumes: list[str]) -> None:
    print()
    print(f"  Add these under your NPM service's {Console.yellow('volumes:')} block:")
    for vol in volumes:
        if not patcher.has_volume(vol):
            print(f"      - {vol}")


# ── Main ───────────────────────────────────────────────────────────────────────
def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="install.py",
        description="Wake-On-Request Installer",
        add_help=False,
    )
    parser.add_argument(
        "-h", "--help", action="store_true", help="Show this help message and exit"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Preview what will change, no files written"
    )
    parser.add_argument(
        "--npm", "-npm", metavar="CONTAINER", help="Manually specify the NPM container name/ID"
    )
    parser.add_argument(
        "--path", "-p", metavar="DIR", help="Target NPM directory (defaults to current directory)"
    )
    parser.add_argument(
        "target_dir", nargs="?", default=None, help="Target directory (positional)"
    )
    return parser


def show_usage(parser: argparse.ArgumentParser) -> None:
    print(f"{Console.bold('Wake-On-Request Installer')}")
    print("Usage:")
    print("  ./install.sh [target_dir] [options]")
    print()
    print("Options:")
    print("  --dry-run                Preview what will change, no files written")
    print("  --npm, -npm <container>  Manually specify the Nginx Proxy Manager container name/ID")
    print("  --path, -p <dir>         Target NPM directory (defaults to current directory)")
    print("  -h, --help               Show this help message and exit")
    print()


def main() -> None:
    parser = build_arg_parser()
    args = parser.parse_args()

    if args.help:
        show_usage(parser)
        sys.exit(0)

    # Resolve target directory — accept either a dir or a .sqlite file
    target_dir_str = args.path or args.target_dir or "."
    target_path = Path(target_dir_str).resolve()
    db_override: Optional[Path] = None

    if target_path.is_file() and target_path.suffix in (".sqlite", ".db", ".sqlite3"):
        # User passed the database file directly
        db_override = target_path
        target_dir = target_path.parent
    elif target_path.is_dir():
        target_dir = target_path
    else:
        print(f"{Console.red('❌ Path not found: ' + str(target_path))}")
        print("   Pass a directory (e.g. /path/to/npm-data) or the database file directly.")
        sys.exit(1)

    os.chdir(target_dir)

    # docker-compose.yml check — skip in dry-run if user only supplied the DB path
    if not db_override and not Path("docker-compose.yml").exists():
        if args.dry_run:
            Console.warn("docker-compose.yml not found — compose patching will be skipped.")
        else:
            print(Console.red(f"❌ docker-compose.yml not found in {target_dir}"))
            print("   Run this script from your Nginx Proxy Manager directory.")
            sys.exit(1)

    # Build clients
    docker = DockerClient(npm_override=args.npm or "")
    db = NpmDatabase(docker, target_dir, db_override=db_override)

    # Environment scan
    Console.section("Environment Scan")
    if docker.available:
        Console.ok("Environment scan complete.")
    else:
        Console.warn("Docker socket or daemon not accessible — skipping environment scan.")

    if args.dry_run:
        run_dry_run(args, docker, db)
    else:
        run_install(args, docker, db)


if __name__ == "__main__":
    main()

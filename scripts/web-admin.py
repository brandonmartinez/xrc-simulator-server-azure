#!/usr/bin/env python3
"""xRC Simulator Web Admin - lightweight management UI for the xRC server.

Runs on a configurable port (default 8080) and provides:
- Basic HTTP auth using XRC_ADMIN / XRC_PASSWORD from server.env
- Start/Stop/Restart the xrc-simulator systemd service
- Change the active game
- View service status
- Update the xRC server install from the web UI, with automatic
  backup and rollback on failure
"""

import base64
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from datetime import datetime, timezone
from html.parser import HTMLParser
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import urllib.error
import urllib.request

CONFIG_PATH = "/opt/xrc-simulator/server.env"
INSTALL_DIR = "/opt/xrc-simulator"
BACKUPS_DIR = "/opt/xrc-simulator-backups"
UPDATE_LOCKFILE = "/run/xrc-update.lock"
FS_HELPER = "/usr/local/sbin/xrc-fs-helper"
PRESERVED_FILES = ("server.env", "runserver.sh", "web-admin.py")
ALLOWED_HOST = "xrcsimulator.org"
DOWNLOADS_PAGE = "https://xrcsimulator.org/downloads/"
VERSION_RE = re.compile(r"xRC_Linux_Server_v([0-9]+\.[0-9]+[a-z]?)\.zip")
LATEST_CACHE_TTL = 300  # 5 minutes
MAX_LOG_LINES = 200
TERMINAL_PHASES = ("idle", "success", "failed", "rolled-back")

LOCK = threading.Lock()        # serializes systemctl actions
UPDATE_LOCK = threading.Lock() # ensures only one update at a time
STATE_LOCK = threading.Lock()  # guards UPDATE_STATE
UPDATE_STATE = {
    "phase": "idle",
    "message": "",
    "started_at": None,
    "finished_at": None,
    "success": None,
    "failed_after_phase": None,
    "requested_url": None,
    "log": [],
}
LATEST_CACHE = {"fetched_at": 0.0, "version": None, "url": None}

GAMES = {
    0: "Splash",
    1: "Relic Recovery",
    2: "Rover Ruckus",
    3: "Skystone",
    4: "Infinite Recharge",
    5: "Change Up",
    6: "Bot Royale",
    7: "Ultimate Goal",
    8: "Tipping Point",
    9: "Freight Frenzy",
    10: "Rapid React",
    11: "Spin Up",
    12: "Power Play",
    13: "Charged Up",
    14: "Over Under",
    15: "CENTERSTAGE",
    16: "Crescendo",
    17: "High Stakes",
    18: "INTO THE DEEP",
    19: "REEFSCAPE",
    20: "Push Back",
    21: "DECODE",
    22: "REBUILT",
}


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

MAX_SERVER_NAME_LEN = 64
DEFAULT_SERVER_NAME = "xRC Azure Server"


def _parse_env_value(raw):
    """Parse a server.env value, handling shell-quoted forms."""
    raw = raw.strip()
    if not raw:
        return ""
    # Quoted values were written by us / setup-xrc.sh; unquoted is the legacy
    # format. shlex with posix=True handles both correctly.
    try:
        tokens = shlex.split(raw, posix=True)
    except ValueError:
        return raw
    return tokens[0] if tokens else ""


def read_config():
    """Read server.env and return as a dict."""
    config = {}
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    config[key.strip()] = _parse_env_value(value)
    return config


def write_config(config):
    """Atomically write config dict back to server.env.

    Values are shell-quoted so the file remains safe to `source` even when
    fields (e.g. XRC_SERVER_NAME) contain spaces or special characters.
    """
    dir_path = os.path.dirname(CONFIG_PATH)
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".server.env.")
    try:
        with os.fdopen(fd, "w") as f:
            for key, value in config.items():
                f.write(f"{key}={shlex.quote(str(value))}\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, CONFIG_PATH)
    except Exception:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise


def get_server_name():
    name = read_config().get("XRC_SERVER_NAME", "").strip()
    return name or DEFAULT_SERVER_NAME


def validate_server_name(name):
    """Return (cleaned_name, error_or_None)."""
    if not isinstance(name, str):
        return None, "server name must be a string"
    cleaned = name.strip()
    if not cleaned:
        return None, "server name must not be empty"
    if len(cleaned) > MAX_SERVER_NAME_LEN:
        return None, f"server name must be {MAX_SERVER_NAME_LEN} characters or fewer"
    # Reject control characters; the xRC server browser won't render them
    # and they could break the runserver.sh command line.
    if any(ord(c) < 32 or ord(c) == 127 for c in cleaned):
        return None, "server name must not contain control characters"
    return cleaned, None


def change_server_name(name):
    cleaned, err = validate_server_name(name)
    if err:
        return {"success": False, "error": err}
    config = read_config()
    if config.get("XRC_SERVER_NAME", "") == cleaned:
        # No-op; still restart so the running process picks up any other
        # config changes the user may have made out-of-band.
        return service_action("restart")
    config["XRC_SERVER_NAME"] = cleaned
    write_config(config)
    return service_action("restart")


def get_backup_retention():
    try:
        return max(1, int(read_config().get("XRC_BACKUP_RETENTION", "3")))
    except ValueError:
        return 3


# ---------------------------------------------------------------------------
# Service helpers
# ---------------------------------------------------------------------------

def get_service_status():
    try:
        result = subprocess.run(
            ["sudo", "systemctl", "is-active", "xrc-simulator"],
            capture_output=True, text=True, timeout=10
        )
        state = result.stdout.strip()
    except Exception:
        state = "unknown"

    try:
        result = subprocess.run(
            ["sudo", "journalctl", "-u", "xrc-simulator", "-n", "10", "--no-pager", "-o", "short"],
            capture_output=True, text=True, timeout=10
        )
        logs = result.stdout.strip()
    except Exception:
        logs = ""

    config = read_config()
    try:
        game_num = int(config.get("XRC_GAME", "22"))
    except ValueError:
        game_num = 22
    game_name = GAMES.get(game_num, f"Unknown ({game_num})")

    return {
        "state": state,
        "game": game_num,
        "game_name": game_name,
        "server_name": config.get("XRC_SERVER_NAME", "").strip() or DEFAULT_SERVER_NAME,
        "logs": logs,
    }


def service_action(action):
    if action not in ("start", "stop", "restart"):
        return {"success": False, "error": f"Invalid action: {action}"}
    try:
        result = subprocess.run(
            ["sudo", "systemctl", action, "xrc-simulator"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            return {"success": True}
        return {"success": False, "error": result.stderr.strip() or f"Exit code {result.returncode}"}
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Operation timed out"}
    except Exception as e:
        return {"success": False, "error": str(e)}


def change_game(game_num):
    if not isinstance(game_num, int) or game_num < 0 or game_num > 22:
        return {"success": False, "error": "Game number must be 0-22"}
    config = read_config()
    config["XRC_GAME"] = str(game_num)
    write_config(config)
    return service_action("restart")


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def check_auth(headers):
    config = read_config()
    expected_user = config.get("XRC_ADMIN", "")
    expected_pass = config.get("XRC_PASSWORD", "")

    if not expected_user:
        return False

    auth_header = headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        return False

    try:
        decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        user, _, password = decoded.partition(":")
        return user == expected_user and password == expected_pass
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Update: URL validation and HTTP fetching
# ---------------------------------------------------------------------------

def validate_xrc_url(url):
    """Strictly allow https://xrcsimulator.org/... URLs only."""
    try:
        p = urlparse(url)
    except Exception:
        return False
    return p.scheme == "https" and p.hostname == ALLOWED_HOST


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Re-validates the destination host on every redirect hop."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not validate_xrc_url(newurl):
            raise urllib.error.HTTPError(
                newurl, code,
                f"Redirect to disallowed host: {newurl}",
                headers, fp,
            )
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _opener():
    return urllib.request.build_opener(_SafeRedirectHandler())


class _LinuxServerLinkFinder(HTMLParser):
    """Finds the first anchor whose title matches xRC_Linux_Server_v*.zip."""

    def __init__(self):
        super().__init__()
        self.found_url = None
        self.found_version = None

    def handle_starttag(self, tag, attrs):
        if tag != "a" or self.found_url:
            return
        d = dict(attrs)
        title = d.get("title", "")
        m = VERSION_RE.match(title)
        if not m:
            return
        href = d.get("href", "")
        if href and validate_xrc_url(href):
            self.found_url = href
            self.found_version = m.group(1)


def fetch_latest_release(force=False):
    """Scrape xrcsimulator.org/downloads/ for the latest Linux Server URL.

    Cached for LATEST_CACHE_TTL seconds. Returns (version, url) or (None, None).
    """
    now = time.time()
    if (not force
            and LATEST_CACHE["version"]
            and (now - LATEST_CACHE["fetched_at"]) < LATEST_CACHE_TTL):
        return LATEST_CACHE["version"], LATEST_CACHE["url"]

    if not validate_xrc_url(DOWNLOADS_PAGE):
        return None, None

    try:
        with _opener().open(DOWNLOADS_PAGE, timeout=10) as r:
            html = r.read().decode("utf-8", errors="replace")
    except Exception as e:
        _log(f"latest-fetch failed: {e}")
        return None, None

    parser = _LinuxServerLinkFinder()
    try:
        parser.feed(html)
    except Exception:
        pass

    if parser.found_url and parser.found_version:
        LATEST_CACHE.update(
            fetched_at=now,
            version=parser.found_version,
            url=parser.found_url,
        )
        return parser.found_version, parser.found_url
    return None, None


def derive_version_from_url(url):
    m = VERSION_RE.search(url or "")
    return m.group(1) if m else "unknown"


def get_version_info():
    config = read_config()
    latest, latest_url = fetch_latest_release()
    return {
        "installed": config.get("XRC_INSTALLED_VERSION", "unknown"),
        "installed_url": config.get("XRC_INSTALLED_URL", ""),
        "latest": latest,
        "latest_url": latest_url,
    }


# ---------------------------------------------------------------------------
# Update state machine
# ---------------------------------------------------------------------------

def _set_state(**kwargs):
    with STATE_LOCK:
        UPDATE_STATE.update(kwargs)


def _log(msg):
    ts = datetime.now(timezone.utc).isoformat()
    with STATE_LOCK:
        UPDATE_STATE["log"].append({"ts": ts, "msg": msg})
        if len(UPDATE_STATE["log"]) > MAX_LOG_LINES:
            UPDATE_STATE["log"] = UPDATE_STATE["log"][-MAX_LOG_LINES:]
    sys.stdout.write(f"[update] {msg}\n")
    sys.stdout.flush()


def _phase(phase, message=""):
    _set_state(phase=phase, message=message)
    _log(f"phase={phase} {message}".rstrip())


def update_in_progress():
    with STATE_LOCK:
        return UPDATE_STATE["phase"] not in TERMINAL_PHASES


def get_update_status():
    with STATE_LOCK:
        return {
            "phase": UPDATE_STATE["phase"],
            "message": UPDATE_STATE["message"],
            "started_at": UPDATE_STATE["started_at"],
            "finished_at": UPDATE_STATE["finished_at"],
            "success": UPDATE_STATE["success"],
            "failed_after_phase": UPDATE_STATE["failed_after_phase"],
            "requested_url": UPDATE_STATE["requested_url"],
            "log": list(UPDATE_STATE["log"]),
            "in_progress": UPDATE_STATE["phase"] not in TERMINAL_PHASES,
        }


# ---------------------------------------------------------------------------
# Update worker filesystem helpers
# ---------------------------------------------------------------------------

def _create_lockfile():
    try:
        subprocess.run(["sudo", "touch", UPDATE_LOCKFILE], check=False, timeout=5)
    except Exception as e:
        _log(f"lockfile create failed: {e}")


def _remove_lockfile():
    try:
        subprocess.run(["sudo", "rm", "-f", UPDATE_LOCKFILE], check=False, timeout=5)
    except Exception as e:
        _log(f"lockfile remove failed: {e}")


def _cleanup_stale():
    """Remove staging-*, old-*, failed-*, and dl-* dirs from prior failed runs."""
    if not os.path.isdir(BACKUPS_DIR):
        return
    for name in os.listdir(BACKUPS_DIR):
        if (
            name.startswith("staging-")
            or name.startswith("old-")
            or name.startswith("failed-")
            or name.startswith("dl-")
        ):
            path = os.path.join(BACKUPS_DIR, name)
            try:
                if os.path.isdir(path):
                    shutil.rmtree(path, ignore_errors=True)
                else:
                    os.unlink(path)
                _log(f"cleaned stale: {name}")
            except Exception:
                pass


def _list_backups():
    if not os.path.isdir(BACKUPS_DIR):
        return []
    return sorted(d for d in os.listdir(BACKUPS_DIR) if d.startswith("backup-"))


def _prune_backups():
    keep = get_backup_retention()
    backups = _list_backups()
    excess = len(backups) - keep
    if excess <= 0:
        return
    for name in backups[:excess]:
        path = os.path.join(BACKUPS_DIR, name)
        try:
            shutil.rmtree(path, ignore_errors=True)
            _log(f"pruned old backup: {name}")
        except Exception as e:
            _log(f"failed to prune {name}: {e}")


def _verify_install(staging):
    """Sanity-check that the extracted staging dir is a real xRC install.

    The .x86_64 file is only ~4.8KB on its own (UnityPlayer.so + the
    xRC Simulator_Data/ directory hold the real engine), so checking
    for the binary alone is not enough to catch truncated downloads.
    """
    try:
        entries = os.listdir(staging)
    except FileNotFoundError:
        return False, "staging dir disappeared"
    if not any(f.endswith(".x86_64") for f in entries):
        return False, "no *.x86_64 binary found"
    unity = os.path.join(staging, "UnityPlayer.so")
    if not os.path.isfile(unity) or os.path.getsize(unity) < 1_000_000:
        return False, "UnityPlayer.so missing or implausibly small"
    data_marker = os.path.join(staging, "xRC Simulator_Data", "globalgamemanagers")
    if not os.path.isfile(data_marker):
        return False, "xRC Simulator_Data/globalgamemanagers missing"
    return True, ""


def _copy_install_to_backup(src, dst):
    """Copy live install to backup dir, excluding log files."""
    os.makedirs(dst, exist_ok=True)
    if shutil.which("rsync"):
        cmd = [
            "rsync", "-a",
            "--exclude=log.txt",
            "--exclude=log_old.txt",
            f"{src}/", f"{dst}/",
        ]
    else:
        cmd = ["cp", "-a", f"{src}/.", dst]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"copy failed: {r.stderr.strip() or r.stdout.strip()}")
    if not shutil.which("rsync"):
        for f in ("log.txt", "log_old.txt"):
            try:
                os.unlink(os.path.join(dst, f))
            except FileNotFoundError:
                pass


def _overlay_preserved_files(src, dst):
    """Copy our generated files from live install over the staging dir.

    The xRC zip ships its own top-level runserver.sh which we must
    overwrite with our generated version that sources server.env.
    """
    for name in PRESERVED_FILES:
        s = os.path.join(src, name)
        d = os.path.join(dst, name)
        if os.path.isfile(s):
            shutil.copy2(s, d)
            _log(f"preserved: {name}")


def _make_binaries_executable(d):
    for f in os.listdir(d):
        if f.endswith(".x86_64") or f.endswith(".sh"):
            try:
                os.chmod(os.path.join(d, f), 0o755)
            except Exception:
                pass


def _fs_helper(action, ts):
    """Invoke the privileged install-dir helper. Raises RuntimeError on failure."""
    r = subprocess.run(
        ["sudo", FS_HELPER, action, ts],
        capture_output=True, text=True, timeout=120,
    )
    if r.returncode != 0:
        msg = (r.stderr or r.stdout or "").strip() or f"exit {r.returncode}"
        raise RuntimeError(f"xrc-fs-helper {action} {ts} failed: {msg}")


def _rollback_swap(ts):
    """Reverse the dir-rename swap if the new install fails.

    Uses the privileged helper which moves any live (broken) install
    aside to failed-<ts> before restoring old-<ts>, so the install dir
    is never temporarily absent.
    """
    try:
        _fs_helper("restore", ts)
        _log("rolled back swap")
        return True
    except Exception as e:
        _log(f"rollback failed: {e}")
    return False


# ---------------------------------------------------------------------------
# Update worker — main flow
# ---------------------------------------------------------------------------

def run_update(url):
    """Background worker that performs the full update flow."""
    started = datetime.now(timezone.utc).isoformat()
    with STATE_LOCK:
        UPDATE_STATE.update(
            phase="validating", message="", started_at=started, finished_at=None,
            success=None, failed_after_phase=None, requested_url=url, log=[],
        )
    _log(f"update started; url={url}")

    last_phase = "validating"

    def fail(phase, err, rolled_back=False):
        end = datetime.now(timezone.utc).isoformat()
        _set_state(
            phase="rolled-back" if rolled_back else "failed",
            message=str(err),
            finished_at=end,
            success=False,
            failed_after_phase=phase,
        )
        _log(f"FAILED at phase={phase}: {err}{' (rolled back)' if rolled_back else ''}")

    try:
        # 1. validate URL
        _phase("validating", url)
        if not validate_xrc_url(url):
            fail(last_phase, "URL must be https://xrcsimulator.org/...")
            return

        os.makedirs(BACKUPS_DIR, exist_ok=True)
        _cleanup_stale()

        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        staging_dir = os.path.join(BACKUPS_DIR, f"staging-{ts}")
        backup_dir = os.path.join(BACKUPS_DIR, f"backup-{ts}")
        old_dir = os.path.join(BACKUPS_DIR, f"old-{ts}")

        # 2. download
        last_phase = "downloading"
        _phase("downloading", url)
        fd, zip_path = tempfile.mkstemp(suffix=".zip", dir=BACKUPS_DIR, prefix="dl-")
        os.close(fd)
        try:
            with _opener().open(url, timeout=120) as r, open(zip_path, "wb") as out:
                shutil.copyfileobj(r, out, length=1 << 20)
        except Exception as e:
            try:
                os.unlink(zip_path)
            except FileNotFoundError:
                pass
            fail(last_phase, f"download failed: {e}")
            return

        size = os.path.getsize(zip_path)
        _log(f"downloaded {size} bytes")
        if size < 10 * 1024 * 1024:
            os.unlink(zip_path)
            fail(last_phase, f"downloaded zip too small ({size} bytes)")
            return

        # 3. extract to staging
        last_phase = "extracting"
        _phase("extracting", staging_dir)
        os.makedirs(staging_dir, exist_ok=True)
        try:
            with zipfile.ZipFile(zip_path) as zf:
                zf.extractall(staging_dir)
        except Exception as e:
            try: os.unlink(zip_path)
            except FileNotFoundError: pass
            shutil.rmtree(staging_dir, ignore_errors=True)
            fail(last_phase, f"extract failed: {e}")
            return
        os.unlink(zip_path)

        # 4. verify
        last_phase = "verifying"
        _phase("verifying", staging_dir)
        ok, reason = _verify_install(staging_dir)
        if not ok:
            shutil.rmtree(staging_dir, ignore_errors=True)
            fail(last_phase, f"verification failed: {reason}")
            return
        _make_binaries_executable(staging_dir)

        # 5. stop service (write lockfile so the daily-restart timer skips)
        _create_lockfile()
        last_phase = "stopping-service"
        _phase("stopping-service")
        r = service_action("stop")
        if not r.get("success"):
            shutil.rmtree(staging_dir, ignore_errors=True)
            _remove_lockfile()
            fail(last_phase, r.get("error", "stop failed"))
            return

        # 6. backup
        last_phase = "backing-up"
        _phase("backing-up", backup_dir)
        try:
            _copy_install_to_backup(INSTALL_DIR, backup_dir)
        except Exception as e:
            shutil.rmtree(staging_dir, ignore_errors=True)
            service_action("start")  # don't leave the user stranded
            _remove_lockfile()
            fail(last_phase, f"backup failed: {e}")
            return

        # 7. swap: overlay preserved files into staging, atomic rename
        last_phase = "swapping"
        _phase("swapping")
        swap_partial = False
        try:
            _overlay_preserved_files(INSTALL_DIR, staging_dir)
            _fs_helper("swap-out", ts)
            swap_partial = True
            _fs_helper("swap-in", ts)
            swap_partial = False

            cfg = read_config()
            cfg["XRC_INSTALLED_VERSION"] = derive_version_from_url(url)
            cfg["XRC_INSTALLED_URL"] = url
            write_config(cfg)
            _make_binaries_executable(INSTALL_DIR)
        except Exception as e:
            # try to undo whatever portion of the swap happened
            if swap_partial and os.path.isdir(old_dir) and not os.path.isdir(INSTALL_DIR):
                try:
                    _fs_helper("restore", ts)
                except Exception as re:
                    _log(f"swap-undo failed: {re}")
            shutil.rmtree(staging_dir, ignore_errors=True)
            service_action("start")
            _remove_lockfile()
            fail(last_phase, f"swap failed: {e}", rolled_back=True)
            return

        # 8. start service
        last_phase = "starting-service"
        _phase("starting-service")
        r = service_action("start")
        if not r.get("success"):
            service_action("stop")
            _rollback_swap(ts)
            service_action("start")
            _remove_lockfile()
            fail(last_phase, r.get("error", "start failed"), rolled_back=True)
            return

        # 9. verify is-active after a brief settle
        last_phase = "verifying-service"
        _phase("verifying-service")
        time.sleep(5)
        try:
            r = subprocess.run(
                ["sudo", "systemctl", "is-active", "xrc-simulator"],
                capture_output=True, text=True, timeout=10,
            )
            state = r.stdout.strip()
        except Exception as e:
            state = f"error: {e}"
        if state != "active":
            _log(f"service not active (state={state}); rolling back")
            service_action("stop")
            _rollback_swap(ts)
            service_action("start")
            _remove_lockfile()
            fail(last_phase, f"service did not become active (state={state})", rolled_back=True)
            return

        # 10. prune
        last_phase = "pruning-backups"
        _phase("pruning-backups")
        try:
            _fs_helper("discard-old", ts)
        except Exception as e:
            _log(f"failed to discard old install: {e}")
        _prune_backups()

        _remove_lockfile()
        end = datetime.now(timezone.utc).isoformat()
        _set_state(
            phase="success",
            message=f"Updated to v{derive_version_from_url(url)}",
            finished_at=end,
            success=True,
        )
        _log("update SUCCESS")
    except Exception as e:
        _remove_lockfile()
        fail(last_phase, str(e))


def start_update(url):
    """Try to start an update; returns (started: bool, message: str)."""
    if not UPDATE_LOCK.acquire(blocking=False):
        return False, "An update is already in progress"
    if not validate_xrc_url(url):
        UPDATE_LOCK.release()
        return False, "URL must be https://xrcsimulator.org/..."

    def _runner():
        try:
            run_update(url)
        finally:
            UPDATE_LOCK.release()

    t = threading.Thread(target=_runner, daemon=True, name="xrc-update")
    t.start()
    return True, "Update started"


# ---------------------------------------------------------------------------
# HTML / JS
# ---------------------------------------------------------------------------

HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>xRC Simulator Admin</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #1a1a2e; color: #eee; padding: 2rem; min-height: 100vh; }
.container { max-width: 700px; margin: 0 auto; }
h1 { color: #00d4ff; margin-bottom: 1.5rem; font-size: 1.5rem; }
.card { background: #16213e; border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; border: 1px solid #0f3460; }
.card h2 { color: #00d4ff; font-size: 1.1rem; margin-bottom: 1rem; }
.status-badge { display: inline-block; padding: 0.3rem 0.8rem; border-radius: 4px; font-weight: bold; font-size: 0.9rem; }
.status-active { background: #0f5132; color: #75b798; }
.status-inactive { background: #58151c; color: #ea868f; }
.status-unknown { background: #664d03; color: #ffda6a; }
.btn { display: inline-block; padding: 0.5rem 1.2rem; border: none; border-radius: 4px; font-size: 0.9rem; cursor: pointer; font-weight: 500; margin: 0.3rem; transition: opacity 0.2s; }
.btn:hover { opacity: 0.85; }
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-start { background: #198754; color: #fff; }
.btn-stop { background: #dc3545; color: #fff; }
.btn-restart { background: #fd7e14; color: #fff; }
.btn-primary { background: #0d6efd; color: #fff; }
.btn-secondary { background: #6c757d; color: #fff; }
select, input[type=text] { background: #0f3460; color: #eee; border: 1px solid #1a4080; padding: 0.5rem; border-radius: 4px; font-size: 0.9rem; width: 100%; margin-bottom: 1rem; font-family: inherit; }
.game-info, .version-info { margin: 0.5rem 0 1rem; color: #aaa; font-size: 0.9rem; }
.version-info strong { color: #eee; }
.logs { background: #0d1b2a; padding: 1rem; border-radius: 4px; font-family: 'Courier New', monospace; font-size: 0.8rem; white-space: pre-wrap; word-break: break-all; max-height: 200px; overflow-y: auto; color: #adb5bd; margin-top: 1rem; }
.msg { padding: 0.5rem 1rem; border-radius: 4px; margin-top: 1rem; font-size: 0.9rem; }
.msg-ok { background: #0f5132; color: #75b798; }
.msg-err { background: #58151c; color: #ea868f; }
.msg-info { background: #084298; color: #9ec5fe; }
.actions { margin-top: 0.5rem; }
.phase-pill { display: inline-block; padding: 0.2rem 0.6rem; border-radius: 4px; background: #0f3460; color: #9ec5fe; font-size: 0.8rem; margin-right: 0.5rem; }
.muted { color: #888; font-size: 0.85rem; }
</style>
</head>
<body>
<div class="container">
<h1>&#127918; xRC Simulator Admin</h1>

<div class="card">
  <h2>Server Status</h2>
  <div id="status">Loading...</div>
  <div class="actions">
    <button class="btn btn-start" id="btn-start" onclick="doAction('start')">Start</button>
    <button class="btn btn-stop" id="btn-stop" onclick="doAction('stop')">Stop</button>
    <button class="btn btn-restart" id="btn-restart" onclick="doAction('restart')">Restart</button>
  </div>
  <div id="action-msg"></div>
</div>

<div class="card">
  <h2>Server Name</h2>
  <div class="game-info">Shown in the xRC server browser. Saving will restart the server.</div>
  <input type="text" id="server-name" maxlength="64" placeholder="xRC Azure Server">
  <button class="btn btn-primary" id="btn-server-name" onclick="changeServerName()">Save &amp; Restart</button>
  <div id="server-name-msg"></div>
</div>

<div class="card">
  <h2>Change Game</h2>
  <div class="game-info">Current game: <strong id="current-game">&mdash;</strong></div>
  <select id="game-select"></select>
  <button class="btn btn-primary" id="btn-game" onclick="changeGame()">Apply &amp; Restart</button>
  <div id="game-msg"></div>
</div>

<div class="card">
  <h2>Update Server</h2>
  <div class="version-info">
    Installed: <strong id="installed-version">&mdash;</strong>
    &nbsp;&middot;&nbsp;
    Latest: <strong id="latest-version">&mdash;</strong>
    <button class="btn btn-secondary" id="btn-refresh-version" onclick="refreshVersion()" style="float:right;font-size:0.75rem;padding:0.2rem 0.6rem;">Refresh</button>
  </div>
  <label class="muted" for="update-url">Download URL (must be on xrcsimulator.org)</label>
  <input type="text" id="update-url" placeholder="https://xrcsimulator.org/Downloads/xRC_Linux_Server_vXX.Xx.zip">
  <button class="btn btn-primary" id="btn-update" onclick="startUpdate()">Update Now</button>
  <div id="update-msg"></div>
  <div id="update-progress" style="display:none;margin-top:1rem;">
    <div><span class="phase-pill" id="update-phase">&mdash;</span><span id="update-summary" class="muted"></span></div>
    <div class="logs" id="update-log"></div>
  </div>
</div>

<div class="card">
  <h2>Recent Logs</h2>
  <div class="logs" id="logs">Loading...</div>
</div>
</div>

<script>
const GAMES = __GAMES_JSON__;
let updateActive = false;
let updatePollTimer = null;

function populateGames() {
  const sel = document.getElementById('game-select');
  for (const [num, name] of Object.entries(GAMES)) {
    const opt = document.createElement('option');
    opt.value = num;
    opt.textContent = num + ' - ' + name;
    sel.appendChild(opt);
  }
}

function setServiceButtonsDisabled(disabled) {
  for (const id of ['btn-start','btn-stop','btn-restart','btn-game','btn-server-name']) {
    const el = document.getElementById(id);
    if (el) el.disabled = disabled;
  }
}

async function fetchStatus() {
  try {
    const r = await fetch('/api/status');
    if (!r.ok) throw new Error('Failed');
    const d = await r.json();
    const badge = d.state === 'active' ? 'status-active' :
                  d.state === 'inactive' ? 'status-inactive' : 'status-unknown';
    document.getElementById('status').innerHTML =
      '<span class="status-badge ' + badge + '">' + d.state + '</span>';
    document.getElementById('current-game').textContent = d.game + ' - ' + d.game_name;
    document.getElementById('game-select').value = d.game;
    const nameInput = document.getElementById('server-name');
    // Don't clobber the user's in-progress typing.
    if (nameInput && document.activeElement !== nameInput) {
      nameInput.value = d.server_name || '';
    }
    document.getElementById('logs').textContent = d.logs || '(no logs)';
  } catch(e) {
    document.getElementById('status').innerHTML = '<span class="status-badge status-unknown">error</span>';
  }
}

async function doAction(action) {
  const msgEl = document.getElementById('action-msg');
  msgEl.innerHTML = '<div class="msg">Working...</div>';
  try {
    const r = await fetch('/api/' + action, { method: 'POST' });
    const d = await r.json();
    if (r.status === 409) {
      msgEl.innerHTML = '<div class="msg msg-err">Update in progress; try again when it completes.</div>';
      return;
    }
    if (d.success) {
      msgEl.innerHTML = '<div class="msg msg-ok">Success: ' + action + '</div>';
    } else {
      msgEl.innerHTML = '<div class="msg msg-err">Error: ' + (d.error || 'unknown') + '</div>';
    }
    setTimeout(fetchStatus, 1500);
  } catch(e) {
    msgEl.innerHTML = '<div class="msg msg-err">Request failed</div>';
  }
}

async function changeGame() {
  const num = parseInt(document.getElementById('game-select').value, 10);
  const msgEl = document.getElementById('game-msg');
  msgEl.innerHTML = '<div class="msg">Changing game &amp; restarting...</div>';
  try {
    const r = await fetch('/api/game', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ game: num })
    });
    if (r.status === 409) {
      msgEl.innerHTML = '<div class="msg msg-err">Update in progress; try again when it completes.</div>';
      return;
    }
    const d = await r.json();
    if (d.success) {
      msgEl.innerHTML = '<div class="msg msg-ok">Game changed to ' + num + ' - ' + (GAMES[num] || '?') + '</div>';
    } else {
      msgEl.innerHTML = '<div class="msg msg-err">Error: ' + (d.error || 'unknown') + '</div>';
    }
    setTimeout(fetchStatus, 2000);
  } catch(e) {
    msgEl.innerHTML = '<div class="msg msg-err">Request failed</div>';
  }
}

async function changeServerName() {
  const name = document.getElementById('server-name').value.trim();
  const msgEl = document.getElementById('server-name-msg');
  if (!name) {
    msgEl.innerHTML = '<div class="msg msg-err">Server name must not be empty.</div>';
    return;
  }
  msgEl.innerHTML = '<div class="msg">Saving &amp; restarting...</div>';
  try {
    const r = await fetch('/api/server-name', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name })
    });
    if (r.status === 409) {
      msgEl.innerHTML = '<div class="msg msg-err">Update in progress; try again when it completes.</div>';
      return;
    }
    const d = await r.json();
    if (d.success) {
      msgEl.innerHTML = '<div class="msg msg-ok">Server name updated.</div>';
    } else {
      msgEl.innerHTML = '<div class="msg msg-err">Error: ' + (d.error || 'unknown') + '</div>';
    }
    setTimeout(fetchStatus, 2000);
  } catch(e) {
    msgEl.innerHTML = '<div class="msg msg-err">Request failed</div>';
  }
}

async function fetchVersion(force) {
  try {
    const url = '/api/version' + (force ? '?refresh=1' : '');
    const r = await fetch(url);
    if (!r.ok) throw new Error('Failed');
    const d = await r.json();
    document.getElementById('installed-version').textContent =
      d.installed + (d.installed_url ? '' : '');
    document.getElementById('latest-version').textContent =
      d.latest ? d.latest : '(unknown)';
    const input = document.getElementById('update-url');
    if (!input.value && d.latest_url) input.value = d.latest_url;
  } catch(e) {
    document.getElementById('latest-version').textContent = '(fetch failed)';
  }
}

function refreshVersion() {
  document.getElementById('latest-version').textContent = 'Loading...';
  fetchVersion(true);
}

async function startUpdate() {
  const url = document.getElementById('update-url').value.trim();
  const msgEl = document.getElementById('update-msg');
  if (!url) {
    msgEl.innerHTML = '<div class="msg msg-err">Please provide a download URL.</div>';
    return;
  }
  if (!/^https:\\/\\/xrcsimulator\\.org\\//.test(url)) {
    msgEl.innerHTML = '<div class="msg msg-err">URL must be on https://xrcsimulator.org/</div>';
    return;
  }
  if (!confirm('Update the xRC server now? The game will briefly stop while the new build is installed. A rollback will happen automatically if anything fails.')) {
    return;
  }
  msgEl.innerHTML = '<div class="msg msg-info">Starting update...</div>';
  try {
    const r = await fetch('/api/update', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: url })
    });
    const d = await r.json();
    if (r.status === 409) {
      msgEl.innerHTML = '<div class="msg msg-err">An update is already in progress.</div>';
    } else if (r.status === 202 || d.started) {
      msgEl.innerHTML = '<div class="msg msg-ok">Update started.</div>';
    } else {
      msgEl.innerHTML = '<div class="msg msg-err">Error: ' + (d.error || 'unknown') + '</div>';
    }
    pollUpdate();
  } catch(e) {
    msgEl.innerHTML = '<div class="msg msg-err">Request failed</div>';
  }
}

async function pollUpdate() {
  try {
    const r = await fetch('/api/update/status');
    const d = await r.json();
    renderUpdate(d);
    if (d.in_progress) {
      updateActive = true;
      setServiceButtonsDisabled(true);
      document.getElementById('btn-update').disabled = true;
      if (!updatePollTimer) {
        updatePollTimer = setInterval(pollUpdate, 1500);
      }
    } else {
      if (updateActive) {
        // transition: update just finished
        updateActive = false;
        setServiceButtonsDisabled(false);
        document.getElementById('btn-update').disabled = false;
        fetchStatus();
        fetchVersion(true);
      }
      if (updatePollTimer) {
        clearInterval(updatePollTimer);
        updatePollTimer = null;
      }
    }
  } catch(e) {
    // ignore transient poll errors
  }
}

function renderUpdate(d) {
  const box = document.getElementById('update-progress');
  if (d.phase === 'idle' && (!d.log || d.log.length === 0)) {
    box.style.display = 'none';
    return;
  }
  box.style.display = 'block';
  document.getElementById('update-phase').textContent = d.phase;
  const summary = d.message ? ' ' + d.message : '';
  const finished = d.success === true ? ' (success)' :
                   d.success === false ? ' (failed)' : '';
  document.getElementById('update-summary').textContent = summary + finished;
  const logEl = document.getElementById('update-log');
  logEl.textContent = (d.log || []).map(l => l.ts + '  ' + l.msg).join('\\n');
  logEl.scrollTop = logEl.scrollHeight;
}

populateGames();
fetchStatus();
fetchVersion(false);
pollUpdate();
setInterval(fetchStatus, 10000);
</script>
</body>
</html>"""


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class AdminHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stdout.write(f"{self.address_string()} - {format % args}\n")
        sys.stdout.flush()

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html, status=200):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def require_auth(self):
        if not check_auth(self.headers):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="xRC Admin"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        return True

    def _conflict_if_updating(self):
        if update_in_progress():
            self.send_json(
                {"success": False, "error": "Update in progress"},
                status=409,
            )
            return True
        return False

    def do_GET(self):
        if not self.require_auth():
            return

        parsed = urlparse(self.path)
        path = parsed.path

        if path in ("/", ""):
            games_json = json.dumps(GAMES)
            page = HTML_PAGE.replace("__GAMES_JSON__", games_json)
            self.send_html(page)
        elif path == "/api/status":
            self.send_json(get_service_status())
        elif path == "/api/version":
            force = "refresh=1" in (parsed.query or "")
            if force:
                # bust the cache for this request
                LATEST_CACHE["fetched_at"] = 0.0
            self.send_json(get_version_info())
        elif path == "/api/update/status":
            self.send_json(get_update_status())
        else:
            self.send_json({"error": "Not found"}, 404)

    def do_POST(self):
        if not self.require_auth():
            return

        path = urlparse(self.path).path

        if path in ("/api/start", "/api/stop", "/api/restart"):
            if self._conflict_if_updating():
                return
            action = path.split("/")[-1]
            with LOCK:
                result = service_action(action)
            self.send_json(result)
        elif path == "/api/game":
            if self._conflict_if_updating():
                return
            content_type = self.headers.get("Content-Type", "")
            if "application/json" not in content_type:
                self.send_json({"success": False, "error": "Content-Type must be application/json"}, 400)
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length))
                game_num = body.get("game")
                if not isinstance(game_num, int):
                    game_num = int(game_num)
            except (ValueError, TypeError, json.JSONDecodeError):
                self.send_json({"success": False, "error": "Invalid request body"}, 400)
                return

            with LOCK:
                result = change_game(game_num)
            self.send_json(result)
        elif path == "/api/server-name":
            if self._conflict_if_updating():
                return
            content_type = self.headers.get("Content-Type", "")
            if "application/json" not in content_type:
                self.send_json({"success": False, "error": "Content-Type must be application/json"}, 400)
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length))
                name = body.get("name", "")
            except (ValueError, TypeError, json.JSONDecodeError):
                self.send_json({"success": False, "error": "Invalid request body"}, 400)
                return

            with LOCK:
                result = change_server_name(name)
            self.send_json(result)
        elif path == "/api/update":
            content_type = self.headers.get("Content-Type", "")
            if "application/json" not in content_type:
                self.send_json({"success": False, "error": "Content-Type must be application/json"}, 400)
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length))
                url = body.get("url", "")
            except (ValueError, TypeError, json.JSONDecodeError):
                self.send_json({"success": False, "error": "Invalid request body"}, 400)
                return

            if not isinstance(url, str) or not url:
                self.send_json({"success": False, "error": "url is required"}, 400)
                return

            started, msg = start_update(url)
            if not started:
                status = 409 if "in progress" in msg else 400
                self.send_json({"success": False, "started": False, "error": msg}, status=status)
                return
            self.send_json({"success": True, "started": True, "message": msg}, status=202)
        else:
            self.send_json({"error": "Not found"}, 404)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    bind_addr = os.environ.get("WEB_ADMIN_BIND", "0.0.0.0")
    port = int(os.environ.get("WEB_ADMIN_PORT", "8080"))

    server = HTTPServer((bind_addr, port), AdminHandler)
    print(f"xRC Web Admin listening on {bind_addr}:{port}")
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()

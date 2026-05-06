#!/usr/bin/env python3
"""xRC Simulator Web Admin - lightweight management UI for the xRC server.

Runs on a configurable port (default 8080) and provides:
- Basic HTTP auth using XRC_ADMIN / XRC_PASSWORD from server.env
- Start/Stop/Restart the xrc-simulator systemd service
- Change the active game
- View service status
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

CONFIG_PATH = "/opt/xrc-simulator/server.env"
LOCK = threading.Lock()

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


def read_config():
    """Read server.env and return as a dict."""
    config = {}
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    config[key.strip()] = value.strip()
    return config


def write_config(config):
    """Atomically write config dict back to server.env."""
    dir_path = os.path.dirname(CONFIG_PATH)
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".server.env.")
    try:
        with os.fdopen(fd, "w") as f:
            for key, value in config.items():
                f.write(f"{key}={value}\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, CONFIG_PATH)
    except Exception:
        os.unlink(tmp_path)
        raise


def get_service_status():
    """Get xrc-simulator service status."""
    try:
        result = subprocess.run(
            ["sudo", "systemctl", "is-active", "xrc-simulator"],
            capture_output=True, text=True, timeout=10
        )
        state = result.stdout.strip()
    except Exception:
        state = "unknown"

    # Get recent log lines
    try:
        result = subprocess.run(
            ["sudo", "journalctl", "-u", "xrc-simulator", "-n", "10", "--no-pager", "-o", "short"],
            capture_output=True, text=True, timeout=10
        )
        logs = result.stdout.strip()
    except Exception:
        logs = ""

    config = read_config()
    game_num = int(config.get("XRC_GAME", "22"))
    game_name = GAMES.get(game_num, f"Unknown ({game_num})")

    return {
        "state": state,
        "game": game_num,
        "game_name": game_name,
        "logs": logs,
    }


def service_action(action):
    """Run systemctl action on xrc-simulator."""
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
    """Change the game number in server.env and restart the service."""
    if not isinstance(game_num, int) or game_num < 0 or game_num > 22:
        return {"success": False, "error": "Game number must be 0-22"}

    config = read_config()
    config["XRC_GAME"] = str(game_num)
    write_config(config)

    # Restart to pick up the new game
    return service_action("restart")


def check_auth(headers):
    """Validate Basic auth against server.env credentials."""
    config = read_config()
    expected_user = config.get("XRC_ADMIN", "")
    expected_pass = config.get("XRC_PASSWORD", "")

    if not expected_user:
        # No credentials configured — deny access
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
select { background: #0f3460; color: #eee; border: 1px solid #1a4080; padding: 0.5rem; border-radius: 4px; font-size: 0.9rem; width: 100%; margin-bottom: 1rem; }
.game-info { margin: 0.5rem 0 1rem; color: #aaa; font-size: 0.9rem; }
.logs { background: #0d1b2a; padding: 1rem; border-radius: 4px; font-family: 'Courier New', monospace; font-size: 0.8rem; white-space: pre-wrap; word-break: break-all; max-height: 200px; overflow-y: auto; color: #adb5bd; margin-top: 1rem; }
.msg { padding: 0.5rem 1rem; border-radius: 4px; margin-top: 1rem; font-size: 0.9rem; }
.msg-ok { background: #0f5132; color: #75b798; }
.msg-err { background: #58151c; color: #ea868f; }
.actions { margin-top: 0.5rem; }
</style>
</head>
<body>
<div class="container">
<h1>&#127918; xRC Simulator Admin</h1>

<div class="card">
  <h2>Server Status</h2>
  <div id="status">Loading...</div>
  <div class="actions">
    <button class="btn btn-start" onclick="doAction('start')">Start</button>
    <button class="btn btn-stop" onclick="doAction('stop')">Stop</button>
    <button class="btn btn-restart" onclick="doAction('restart')">Restart</button>
  </div>
  <div id="action-msg"></div>
</div>

<div class="card">
  <h2>Change Game</h2>
  <div class="game-info">Current game: <strong id="current-game">—</strong></div>
  <select id="game-select"></select>
  <button class="btn btn-primary" onclick="changeGame()">Apply &amp; Restart</button>
  <div id="game-msg"></div>
</div>

<div class="card">
  <h2>Recent Logs</h2>
  <div class="logs" id="logs">Loading...</div>
</div>
</div>

<script>
const GAMES = __GAMES_JSON__;

function populateGames() {
  const sel = document.getElementById('game-select');
  for (const [num, name] of Object.entries(GAMES)) {
    const opt = document.createElement('option');
    opt.value = num;
    opt.textContent = num + ' - ' + name;
    sel.appendChild(opt);
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

populateGames();
fetchStatus();
setInterval(fetchStatus, 10000);
</script>
</body>
</html>"""


class AdminHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Log to stdout for journalctl
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

    def do_GET(self):
        if not self.require_auth():
            return

        path = urlparse(self.path).path

        if path == "/" or path == "":
            games_json = json.dumps(GAMES)
            page = HTML_PAGE.replace("__GAMES_JSON__", games_json)
            self.send_html(page)
        elif path == "/api/status":
            self.send_json(get_service_status())
        else:
            self.send_json({"error": "Not found"}, 404)

    def do_POST(self):
        if not self.require_auth():
            return

        path = urlparse(self.path).path

        if path in ("/api/start", "/api/stop", "/api/restart"):
            action = path.split("/")[-1]
            with LOCK:
                result = service_action(action)
            self.send_json(result)
        elif path == "/api/game":
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
        else:
            self.send_json({"error": "Not found"}, 404)


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

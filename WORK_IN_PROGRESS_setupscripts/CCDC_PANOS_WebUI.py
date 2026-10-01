#!/usr/bin/env python3
"""
CCDC PAN-OS Training - Web Dashboard

Browser-based interface for triggering the dirty-state setup and cleanup
scripts.  Serves on localhost:5000 by default.  The original CLI scripts
(CCDC_PANOS_Run.py, etc.) remain fully functional as a fallback.

Usage:
    pip install flask
    python3 CCDC_PANOS_WebUI.py

    # Custom access PIN (default: ccdc2024)
    PANOS_UI_PIN=mypin python3 CCDC_PANOS_WebUI.py
"""

import contextlib
import importlib.util
import io
import os
import queue
import secrets
import sys
import threading
import time

from flask import (
    Flask, Response, jsonify, redirect,
    render_template_string, request, session, url_for,
)

# ---------------------------------------------------------------------------
# Module loading — explicit paths, no package structure required
# ---------------------------------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_HERE)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


_panos_lib = _load(
    "panos_lib",
    os.path.join(_REPO, "General_Scripts", "SetupScripts", "panos", "panos_lib.py"),
)
PanosAPI = _panos_lib.PanosAPI

_dirty = _load(
    "CCDC_PANOS_Setup_DirtyFirewall",
    os.path.join(_HERE, "CCDC_PANOS_Setup_DirtyFirewall.py"),
)
# Cleanup.py imports DirtyFirewall under this fully-qualified name
sys.modules[
    "CCDC_Red_Team_Tools.WORK_IN_PROGRESS_setupscripts.CCDC_PANOS_Setup_DirtyFirewall"
] = _dirty

_cleanup = _load(
    "CCDC_PANOS_Cleanup",
    os.path.join(_HERE, "CCDC_PANOS_Cleanup.py"),
)

run_setup = _dirty.run_setup
run_cleanup = _cleanup.run_cleanup

# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)

UI_PIN = os.environ.get("PANOS_UI_PIN", "ccdc2024")

# {session_id: {"api": PanosAPI, "queue": Queue | None}}
_sessions: dict = {}
_sessions_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------

_LOGIN = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>PAN-OS Dashboard</title>
  <style>
    body{font-family:monospace;background:#1a1a2e;color:#e0e0e0;
         display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .box{background:#16213e;padding:2rem;border-radius:8px;min-width:320px}
    h1{color:#e94560;margin-top:0}
    input{width:100%;padding:.5rem;background:#0f3460;color:#e0e0e0;
          border:1px solid #e94560;border-radius:4px;font-family:monospace;box-sizing:border-box}
    button{margin-top:1rem;width:100%;padding:.6rem;background:#e94560;color:#fff;
           border:none;border-radius:4px;cursor:pointer;font-family:monospace;font-size:1rem}
    button:hover{background:#c73652}
    .err{color:#e94560;margin-top:.5rem}
  </style>
</head>
<body>
  <div class="box">
    <h1>CCDC PAN-OS Dashboard</h1>
    <form method="POST" action="/login">
      <label>Access PIN</label><br>
      <input type="password" name="pin" autofocus>
      <button type="submit">Enter</button>
      {% if error %}<p class="err">{{ error }}</p>{% endif %}
    </form>
  </div>
</body>
</html>"""

_DASH = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>PAN-OS Dashboard</title>
  <style>
    *{box-sizing:border-box}
    body{font-family:monospace;background:#1a1a2e;color:#e0e0e0;margin:0;padding:1.5rem}
    h1{color:#e94560;margin-top:0}
    h2{color:#a8a8c0;margin:0 0 1rem;font-size:.95rem;font-weight:normal}
    .card{background:#16213e;padding:1.5rem;border-radius:8px;margin-bottom:1.5rem}
    label{display:block;margin-bottom:.2rem;color:#a8a8c0;font-size:.82rem}
    input[type=text],input[type=password]{
      width:100%;padding:.4rem .6rem;background:#0f3460;color:#e0e0e0;
      border:1px solid #334;border-radius:4px;font-family:monospace;font-size:.9rem}
    .row{display:flex;gap:1rem}
    .row>div{flex:1}
    .toggle{color:#7ec8e3;cursor:pointer;font-size:.8rem;margin-top:.35rem;display:inline-block}
    .btn{padding:.5rem 1.1rem;border:none;border-radius:4px;
         cursor:pointer;font-family:monospace;font-size:.9rem}
    .btn-connect{background:#0f3460;color:#e0e0e0;border:1px solid #7ec8e3}
    .btn-connect:hover{background:#1a4a80}
    .btn-setup{background:#e94560;color:#fff}
    .btn-setup:hover{background:#c73652}
    .btn-cleanup{background:#2a9d5c;color:#fff}
    .btn-cleanup:hover{background:#22824d}
    .btn:disabled{opacity:.4;cursor:not-allowed}
    .status{font-size:.82rem;margin-top:.4rem;min-height:1em}
    .ok{color:#2a9d5c}.err{color:#e94560}
    #actions{display:none}
    #log{background:#0a0a1a;border:1px solid #334;border-radius:4px;
         padding:1rem;min-height:160px;max-height:480px;overflow-y:auto;
         white-space:pre-wrap;font-size:.8rem;line-height:1.55}
    .action-row{display:flex;gap:1rem;align-items:center;flex-wrap:wrap}
  </style>
</head>
<body>
  <h1>CCDC PAN-OS Training Dashboard</h1>

  <div class="card">
    <h2>Firewall Connection</h2>
    <div style="margin-bottom:.9rem">
      <label>Management IP</label>
      <input type="text" id="fw_ip" placeholder="192.168.1.1">
    </div>
    <div id="cred-pass">
      <div class="row">
        <div><label>Username</label><input type="text" id="username" value="admin"></div>
        <div><label>Password</label><input type="password" id="password"></div>
      </div>
      <span class="toggle" onclick="toggleCred()">&#x1f511; Use API key instead</span>
    </div>
    <div id="cred-key" style="display:none">
      <label>API Key</label>
      <input type="text" id="apikey" placeholder="LUFRPT14MW5...">
      <span class="toggle" onclick="toggleCred()">&#x1f464; Use username / password instead</span>
    </div>
    <div style="margin-top:.9rem">
      <button class="btn btn-connect" onclick="connect()">Connect</button>
    </div>
    <div class="status" id="conn-status"></div>
  </div>

  <div class="card" id="actions">
    <h2>Actions</h2>
    <div class="action-row">
      <button class="btn btn-setup"   id="btn-setup"   onclick="run('setup')">Apply Dirty State</button>
      <button class="btn btn-cleanup" id="btn-cleanup" onclick="run('cleanup')">Run Cleanup</button>
    </div>
    <div class="status" id="action-status"></div>
  </div>

  <div class="card">
    <h2>Output</h2>
    <div id="log"></div>
  </div>

  <script>
    let credMode = 'pass';

    function toggleCred() {
      credMode = credMode === 'pass' ? 'key' : 'pass';
      document.getElementById('cred-pass').style.display = credMode === 'pass' ? '' : 'none';
      document.getElementById('cred-key').style.display  = credMode === 'key'  ? '' : 'none';
    }

    async function connect() {
      const ip = document.getElementById('fw_ip').value.trim();
      if (!ip) { setStatus('conn-status', 'Enter a firewall IP.', 'err'); return; }
      const body = { ip };
      if (credMode === 'pass') {
        body.username = document.getElementById('username').value.trim();
        body.password = document.getElementById('password').value;
      } else {
        body.apikey = document.getElementById('apikey').value.trim();
      }
      setStatus('conn-status', 'Connecting...', '');
      const res  = await fetch('/connect', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
      const data = await res.json();
      setStatus('conn-status', data.message, data.ok ? 'ok' : 'err');
      if (data.ok) document.getElementById('actions').style.display = '';
    }

    function run(action) {
      const msg = action === 'setup'
        ? 'Apply misconfigurations to the firewall and commit?'
        : 'Reverse all dirty-state changes and commit?';
      if (!confirm(msg)) return;

      document.getElementById('btn-setup').disabled   = true;
      document.getElementById('btn-cleanup').disabled = true;
      document.getElementById('log').textContent = '';
      setStatus('action-status', 'Running…', '');

      fetch('/run/' + action, { method:'POST' });

      const src = new EventSource('/stream/' + action);
      src.onmessage = e => {
        if (e.data === '__DONE__') {
          src.close();
          document.getElementById('btn-setup').disabled   = false;
          document.getElementById('btn-cleanup').disabled = false;
          setStatus('action-status', 'Done.', 'ok');
        } else {
          const log = document.getElementById('log');
          log.textContent += e.data + '\\n';
          log.scrollTop    = log.scrollHeight;
        }
      };
      src.onerror = () => {
        src.close();
        document.getElementById('btn-setup').disabled   = false;
        document.getElementById('btn-cleanup').disabled = false;
        setStatus('action-status', 'Connection lost.', 'err');
      };
    }

    function setStatus(id, msg, cls) {
      const el = document.getElementById(id);
      el.textContent = msg;
      el.className = 'status' + (cls ? ' ' + cls : '');
    }
  </script>
</body>
</html>"""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sid() -> str:
    if "sid" not in session:
        session["sid"] = secrets.token_hex(16)
    return session["sid"]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    if session.get("authed"):
        return redirect(url_for("dashboard"))
    return render_template_string(_LOGIN, error=None)


@app.route("/login", methods=["POST"])
def login():
    if request.form.get("pin") == UI_PIN:
        session["authed"] = True
        return redirect(url_for("dashboard"))
    return render_template_string(_LOGIN, error="Incorrect PIN.")


@app.route("/dashboard")
def dashboard():
    if not session.get("authed"):
        return redirect(url_for("index"))
    return render_template_string(_DASH)


@app.route("/connect", methods=["POST"])
def connect():
    if not session.get("authed"):
        return jsonify({"ok": False, "message": "Not authenticated."}), 403
    data = request.get_json() or {}
    ip = (data.get("ip") or "").strip()
    if not ip:
        return jsonify({"ok": False, "message": "No IP provided."})
    try:
        if data.get("apikey"):
            api = PanosAPI(ip, data["apikey"].strip())
            api.call({"type": "op", "cmd": "<show><system><info></info></system></show>"})
            msg = "Connected using API key."
        else:
            username = (data.get("username") or "").strip()
            password = data.get("password") or ""
            api = PanosAPI.from_credentials(ip, username, password)
            msg = f"Connected as {username} — API key generated."
    except (ValueError, ConnectionError) as exc:
        return jsonify({"ok": False, "message": str(exc)})
    except Exception as exc:
        return jsonify({"ok": False, "message": f"Unexpected error: {exc}"})

    sid = _sid()
    with _sessions_lock:
        _sessions[sid] = {"api": api, "queue": None}
    return jsonify({"ok": True, "message": msg})


class _QueueWriter(io.TextIOBase):
    """Redirects print() output to a Queue, one line per queue item."""

    def __init__(self, q: queue.Queue):
        self._q = q

    def write(self, s: str) -> int:
        for line in s.splitlines():
            self._q.put(line)
        return len(s)


def _worker(sid: str, action: str) -> None:
    with _sessions_lock:
        entry = _sessions.get(sid)
    if not entry:
        return
    q: queue.Queue = queue.Queue()
    with _sessions_lock:
        _sessions[sid]["queue"] = q
    try:
        with contextlib.redirect_stdout(_QueueWriter(q)):
            if action == "setup":
                run_setup(entry["api"])
            else:
                run_cleanup(entry["api"])
    except Exception as exc:
        q.put(f"[!] Fatal error: {exc}")
    finally:
        q.put("__DONE__")


@app.route("/run/<action>", methods=["POST"])
def run_action(action: str):
    if not session.get("authed"):
        return jsonify({"ok": False}), 403
    if action not in ("setup", "cleanup"):
        return jsonify({"ok": False, "message": "Unknown action."}), 400
    sid = _sid()
    with _sessions_lock:
        if sid not in _sessions:
            return jsonify({"ok": False, "message": "Not connected."})
        _sessions[sid]["queue"] = None  # reset so /stream waits for new queue
    threading.Thread(target=_worker, args=(sid, action), daemon=True).start()
    return jsonify({"ok": True})


@app.route("/stream/<action>")
def stream_action(action: str):
    if not session.get("authed"):
        return Response("Not authenticated", status=403)
    sid = _sid()

    def generate():
        # Wait up to 5 s for the worker thread to register its queue
        q = None
        for _ in range(50):
            with _sessions_lock:
                entry = _sessions.get(sid)
            if entry and entry.get("queue") is not None:
                q = entry["queue"]
                break
            time.sleep(0.1)

        if q is None:
            yield "data: [!] Action not started — click a button first.\n\n"
            yield "data: __DONE__\n\n"
            return

        while True:
            try:
                line = q.get(timeout=120)
            except queue.Empty:
                yield "data: [!] Timed out waiting for output.\n\n"
                yield "data: __DONE__\n\n"
                return
            yield f"data: {line}\n\n"
            if line == "__DONE__":
                return

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print("╔══════════════════════════════════════════════════════╗")
    print("║       CCDC PAN-OS Training — Web Dashboard           ║")
    print("╚══════════════════════════════════════════════════════╝")
    print(f"\n  Open: http://localhost:5000")
    print(f"  PIN:  {UI_PIN}  (override with PANOS_UI_PIN env var)\n")
    app.run(host="127.0.0.1", port=5000, threaded=True)

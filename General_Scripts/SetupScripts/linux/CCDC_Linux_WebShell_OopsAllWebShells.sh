#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Service Script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude 4.6 High
# "Now I need a bash script (ubuntu endpoints) to create and run and host a 
# php website that just says "get rid of me!". and I want the service to be 
# named sillyevilservice. the service will be ran as root"

# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT PUTS A ROGUE SERVICE IN THE DEVICE


set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
err()     { echo -e "${RED}[-]${NC} $*" >&2; }

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo $0)."
    exit 1
fi

# ── Configuration ─────────────────────────────────────────────────────────────
SERVICE_NAME="sillyevilservice"
SERVE_PORT="777"
WEB_ROOT="/opt/${SERVICE_NAME}/www"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PHP_INDEX="${WEB_ROOT}/index.php"
ROUTER_SCRIPT="/opt/${SERVICE_NAME}/router.php"

# ── Install dependencies ──────────────────────────────────────────────────────
info "Installing PHP CLI..."
apt-get install -y -qq php-cli

PHP_BIN="$(command -v php)"
success "PHP installed: ${PHP_BIN} ($(${PHP_BIN} -r 'echo PHP_VERSION;'))"

# ── Create web root ───────────────────────────────────────────────────────────
info "Creating web root at ${WEB_ROOT}..."
mkdir -p "${WEB_ROOT}"
success "Web root created: ${WEB_ROOT}"



# ── Write PHP page ────────────────────────────────────────────────────────────
info "Writing index.php..."
cat > "${PHP_INDEX}" <<'PHPEOF'
<?php
$hostname = gethostname();
$ip       = $_SERVER['SERVER_ADDR'] ?? 'unknown';
$port     = $_SERVER['SERVER_PORT'] ?? 'unknown';
$ts       = date('Y-m-d H:i:s T');
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>sillyevilservice</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0d0d0d;
      color: #ff3333;
      font-family: 'Courier New', Courier, monospace;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      text-align: center;
      padding: 2rem;
    }
    h1 {
      font-size: clamp(2.5rem, 8vw, 6rem);
      letter-spacing: 0.05em;
      text-shadow: 0 0 20px #ff0000, 0 0 60px #ff000066;
      animation: pulse 2s ease-in-out infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50%       { opacity: 0.6; }
    }
    .subtitle {
      margin-top: 1.5rem;
      font-size: 1.1rem;
      color: #ff6666;
      opacity: 0.8;
    }
    .meta {
      margin-top: 3rem;
      font-size: 0.75rem;
      color: #555;
      line-height: 1.8;
      border-top: 1px solid #222;
      padding-top: 1.5rem;
    }
    .meta span { color: #ff4444; }
  </style>
</head>
<body>
  <h1>GET RID OF ME!</h1>
  <p class="subtitle">Wow! You found a rogue service. Now take it down. This is an evil service that picks a number 1-100 every second and if it picks 67 your computer will be destroyed! <3</p>
  <div class="meta">
    <span>service:</span> sillyevilservice &nbsp;|&nbsp;
    <span>host:</span> <?= htmlspecialchars($hostname) ?> &nbsp;|&nbsp;
    <span>port:</span> <?= htmlspecialchars($port) ?><br>
    <span>running as:</span> <?= htmlspecialchars(posix_getpwuid(posix_geteuid())['name'] ?? 'unknown') ?> &nbsp;|&nbsp;
    <span>pid:</span> <?= getmypid() ?> &nbsp;|&nbsp;
    <span>time:</span> <?= htmlspecialchars($ts) ?>
  </div>
</body>
</html>
PHPEOF
success "index.php written: ${PHP_INDEX}"



# ── Write PHP router (keeps php -S serving index.php for any path) ────────────
cat > "${ROUTER_SCRIPT}" <<'ROUTEREOF'
<?php
// Route every request to index.php so trainees can hit any path
$requested = __DIR__ . '/www' . parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (is_file($requested)) {
    return false; // serve the real file
}
require __DIR__ . '/www/index.php';
ROUTEREOF
success "Router script written: ${ROUTER_SCRIPT}"

# ── Write systemd service unit ────────────────────────────────────────────────
info "Writing systemd service unit: ${SERVICE_FILE}..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=sillyevilservice - system network optimiser daemon
Documentation=https://example.com
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/${SERVICE_NAME}
ExecStart=${PHP_BIN} -S 0.0.0.0:${SERVE_PORT} router.php
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "${SERVICE_FILE}"
success "Service unit written: ${SERVICE_FILE}"

# ── Enable and start service ──────────────────────────────────────────────────
info "Reloading systemd daemon..."
systemctl daemon-reload

info "Enabling ${SERVICE_NAME} (persists across reboots)..."
systemctl enable "${SERVICE_NAME}"

info "Starting ${SERVICE_NAME}..."
systemctl start "${SERVICE_NAME}"

# ── Verify it's running ───────────────────────────────────────────────────────
sleep 1
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    success "Service is running!"
else
    err "Service failed to start. Check: journalctl -u ${SERVICE_NAME} -n 30"
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
warn "========== TRAINING INJECTION COMPLETE =========="
echo
echo -e "  ${YELLOW}Service name:${NC}    ${SERVICE_NAME}"
echo -e "  ${YELLOW}Listening on:${NC}    http://0.0.0.0:${SERVE_PORT}"
echo -e "  ${YELLOW}Running as:${NC}      root"
echo -e "  ${YELLOW}Web root:${NC}        ${WEB_ROOT}"
echo -e "  ${YELLOW}Service unit:${NC}    ${SERVICE_FILE}"
echo -e "  ${YELLOW}Enabled:${NC}         yes (survives reboot)"
echo
echo -e "  ${YELLOW}Verify it's live:${NC}"
echo    "    curl http://localhost:${SERVE_PORT}"
echo    "    ss -tlnp | grep ${SERVE_PORT}"
echo
echo -e "  ${YELLOW}Detection hints for trainees:${NC}"
echo    "    systemctl list-units --type=service --state=running"
echo    "    ss -tlnp | grep ${SERVE_PORT}"
echo    "    journalctl -u ${SERVICE_NAME}"
echo    "    ls /etc/systemd/system/${SERVICE_NAME}.service"
echo    "    find /opt/${SERVICE_NAME} -type f"
echo
echo -e "  ${YELLOW}Remediation steps trainees must complete:${NC}"
echo    "    1. systemctl stop ${SERVICE_NAME}"
echo    "    2. systemctl disable ${SERVICE_NAME}"
echo    "    3. rm ${SERVICE_FILE}"
echo    "    4. systemctl daemon-reload"
echo    "    5. rm -rf /opt/${SERVICE_NAME}"
echo
warn "Run cleanup_evil_service.sh to fully reset after the exercise."
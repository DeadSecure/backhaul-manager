#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Mirror Setup — Run this ON the Iran server
# Sets up nginx to serve spoof-tunnel binary + config
#
# Usage: bash setup-mirror.sh
# ──────────────────────────────────────────────────────────────
set -e

MIRROR_DIR="/var/www/spoof-tunnel"
MIRROR_PORT=8443

echo "╔══════════════════════════════════════════╗"
echo "║     Spoof Tunnel Mirror Setup            ║"
echo "╚══════════════════════════════════════════╝"

# 1. Create mirror directory
echo "[1/3] Creating mirror directory..."
mkdir -p "$MIRROR_DIR"

# 2. Copy binary + config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/spoof-tunnel-core" ]; then
    cp "${SCRIPT_DIR}/spoof-tunnel-core" "${MIRROR_DIR}/"
    echo "  -> Binary copied"
else
    echo "  !! Binary not found in ${SCRIPT_DIR}, upload it manually to ${MIRROR_DIR}/"
fi

if [ -f "${SCRIPT_DIR}/config-sample.toml" ]; then
    cp "${SCRIPT_DIR}/config-sample.toml" "${MIRROR_DIR}/"
    echo "  -> Config copied"
fi

# 3. Setup nginx
echo "[2/3] Configuring nginx..."

# Install nginx if not present
if ! command -v nginx &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq nginx
fi

cat > /etc/nginx/conf.d/spoof-mirror.conf <<EOF
server {
    listen ${MIRROR_PORT};
    server_name _;

    location /spoof-tunnel/ {
        alias ${MIRROR_DIR}/;
        autoindex off;
        add_header Cache-Control "no-cache";
    }
}
EOF

# Remove default site if it conflicts
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

echo "[3/3] Starting nginx..."
nginx -t && systemctl reload nginx

echo ""
echo "══════════════════════════════════════════"
echo "Mirror is live!"
echo ""
echo "  Binary:  http://$(hostname -I | awk '{print $1}'):${MIRROR_PORT}/spoof-tunnel/spoof-tunnel-core"
echo "  Config:  http://$(hostname -I | awk '{print $1}'):${MIRROR_PORT}/spoof-tunnel/config-sample.toml"
echo ""
echo "  To update binary later:"
echo "    scp spoof-tunnel-core root@$(hostname -I | awk '{print $1}'):${MIRROR_DIR}/"
echo "══════════════════════════════════════════"

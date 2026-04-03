#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Spoof Tunnel Core — One-Line Installer
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/spoof-tunnel-manager/tunnel-core/install.sh) install
#   bash install.sh uninstall
#   bash install.sh status
#   bash install.sh logs
# ──────────────────────────────────────────────────────────────
set -e

BINARY_NAME="spoof-tunnel-core"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/spoof-tunnel"
SERVICE_NAME="spoof-tunnel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REPO_RAW="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/spoof-tunnel-manager/tunnel-core"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║       Spoof Tunnel Core Installer        ║"
    echo "║         High-Performance L3 Tunnel       ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

do_install() {
    check_root
    print_banner

    # 1. Download binary directly
    echo -e "${YELLOW}[1/4] Downloading binary...${NC}"
    curl -sL "${REPO_RAW}/${BINARY_NAME}" -o "/tmp/${BINARY_NAME}"
    chmod +x "/tmp/${BINARY_NAME}"
    mv "/tmp/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    echo -e "${GREEN}  -> ${INSTALL_DIR}/${BINARY_NAME}${NC}"

    # 2. Create config directory + sample config
    echo -e "${YELLOW}[2/4] Setting up config...${NC}"
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "${CONFIG_DIR}/config.toml" ]; then
        curl -sL "${REPO_RAW}/config-sample.toml" -o "${CONFIG_DIR}/config.toml"
        echo -e "${GREEN}  -> Sample config downloaded to ${CONFIG_DIR}/config.toml${NC}"
        echo -e "${YELLOW}  !! Edit ${CONFIG_DIR}/config.toml before starting !!${NC}"
    else
        echo -e "${GREEN}  -> Config already exists, skipping${NC}"
    fi

    # 3. Create systemd service
    echo -e "${YELLOW}[3/4] Creating systemd service...${NC}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Spoof Tunnel Core - High Performance L3 Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BINARY_NAME} --config ${CONFIG_DIR}/config.toml
Restart=always
RestartSec=3
LimitNOFILE=65535
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/dev/net/tun
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${GREEN}  -> ${SERVICE_FILE}${NC}"

    # 4. Enable service
    echo -e "${YELLOW}[4/4] Enabling service...${NC}"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    echo -e "${GREEN}  -> Service enabled${NC}"

    echo ""
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}Installation complete!${NC}"
    echo ""
    echo -e "  Edit config:   ${YELLOW}nano ${CONFIG_DIR}/config.toml${NC}"
    echo -e "  Start:         ${YELLOW}systemctl start ${SERVICE_NAME}${NC}"
    echo -e "  Stop:          ${YELLOW}systemctl stop ${SERVICE_NAME}${NC}"
    echo -e "  Status:        ${YELLOW}systemctl status ${SERVICE_NAME}${NC}"
    echo -e "  Logs:          ${YELLOW}journalctl -u ${SERVICE_NAME} -f${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
}

do_uninstall() {
    check_root
    echo -e "${YELLOW}Stopping and removing Spoof Tunnel...${NC}"

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -f "${INSTALL_DIR}/${BINARY_NAME}"

    echo -e "${RED}Binary and service removed.${NC}"
    echo -e "${YELLOW}Config kept at ${CONFIG_DIR}/ (remove manually if needed)${NC}"
}

do_status() {
    systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || echo -e "${RED}Service not found${NC}"
}

do_logs() {
    journalctl -u "$SERVICE_NAME" -f --no-pager
}

case "${1}" in
    install)    do_install ;;
    uninstall)  do_uninstall ;;
    status)     do_status ;;
    logs)       do_logs ;;
    *)
        echo "Usage: $0 {install|uninstall|status|logs}"
        exit 1
        ;;
esac

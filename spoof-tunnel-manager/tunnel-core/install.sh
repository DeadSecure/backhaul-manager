#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Spoof Tunnel Core — Interactive Manager
# ──────────────────────────────────────────────────────────────
set -e

BINARY_NAME="spoof-tunnel-core"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/spoof-tunnel"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_NAME="spoof-tunnel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

MIRROR_URL="http://79.175.188.86:8443/spoof-tunnel"
GITHUB_URL="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/spoof-tunnel-manager/tunnel-core"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║        Spoof Tunnel Core Manager             ║"
    echo "║        High-Performance L3 IPX Tunnel        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Run as root${NC}"
        exit 1
    fi
}

# Download with mirror fallback
download_file() {
    local filename="$1"
    local output="$2"
    if curl -sf --connect-timeout 5 --max-time 30 "${MIRROR_URL}/${filename}" -o "$output" 2>/dev/null; then
        echo -e "${GREEN}  Downloaded from Iran mirror${NC}"
        return 0
    fi
    if curl -sfL --connect-timeout 10 --max-time 60 "${GITHUB_URL}/${filename}" -o "$output" 2>/dev/null; then
        echo -e "${GREEN}  Downloaded from GitHub${NC}"
        return 0
    fi
    echo -e "${RED}  Download failed from both sources${NC}"
    return 1
}

get_status() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${GREEN}RUNNING${NC}"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${YELLOW}STOPPED (enabled)${NC}"
    elif [ -f "${INSTALL_DIR}/${BINARY_NAME}" ]; then
        echo -e "${RED}INSTALLED (not enabled)${NC}"
    else
        echo -e "${RED}NOT INSTALLED${NC}"
    fi
}

# ════════════════════════════════════════
# 1. Install
# ════════════════════════════════════════
do_install() {
    check_root
    echo -e "\n${YELLOW}[1/3] Downloading binary...${NC}"
    if ! download_file "$BINARY_NAME" "/tmp/${BINARY_NAME}"; then
        return 1
    fi
    chmod +x "/tmp/${BINARY_NAME}"
    mv "/tmp/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    echo -e "${GREEN}  -> ${INSTALL_DIR}/${BINARY_NAME}${NC}"

    echo -e "${YELLOW}[2/3] Creating systemd service...${NC}"
    mkdir -p "$CONFIG_DIR"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Spoof Tunnel Core - High Performance L3 Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BINARY_NAME} --config ${CONFIG_FILE}
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
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo -e "${GREEN}  -> Service created & enabled${NC}"

    echo -e "${YELLOW}[3/3] Config setup...${NC}"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}  No config found. Let's configure now.${NC}"
        do_configure
    else
        echo -e "${GREEN}  -> Config exists at ${CONFIG_FILE}${NC}"
    fi

    echo -e "\n${GREEN}Installation complete! Use option 3 to start.${NC}"
}

# ════════════════════════════════════════
# 2. Configure (Interactive)
# ════════════════════════════════════════
do_configure() {
    check_root
    echo -e "\n${CYAN}── Tunnel Configuration ──${NC}\n"

    # Role
    echo -e "${BOLD}Select role:${NC}"
    echo "  1) Server (Foreign/Kharej)"
    echo "  2) Client (Iran)"
    read -rp "Choice [1/2]: " role_choice
    if [ "$role_choice" = "1" ]; then
        MODE="server"
    else
        MODE="client"
    fi

    # TUN
    read -rp "TUN interface name [spoof0]: " TUN_NAME
    TUN_NAME="${TUN_NAME:-spoof0}"

    read -rp "TUN local IP/mask [10.10.12.1/24]: " LOCAL_ADDR
    LOCAL_ADDR="${LOCAL_ADDR:-10.10.12.1/24}"

    read -rp "TUN remote IP/mask [10.10.12.2/24]: " REMOTE_ADDR
    REMOTE_ADDR="${REMOTE_ADDR:-10.10.12.2/24}"

    read -rp "Tunnel port [2222]: " TUNNEL_PORT
    TUNNEL_PORT="${TUNNEL_PORT:-2222}"

    read -rp "MTU [1320]: " MTU
    MTU="${MTU:-1320}"

    # IPX
    echo ""
    echo -e "${CYAN}── IPX Spoof Settings ──${NC}"
    read -rp "This server's public IP (listen_ip): " LISTEN_IP
    read -rp "Remote server's public IP (dst_ip): " DST_IP
    read -rp "Spoofed source IP (spoof_src_ip): " SPOOF_SRC
    read -rp "Expected incoming source IP (spoof_dst_ip): " SPOOF_DST
    read -rp "Network interface [eth0]: " NET_IFACE
    NET_IFACE="${NET_IFACE:-eth0}"

    # Heartbeat
    echo ""
    read -rp "Heartbeat interval (sec) [10]: " HB_INTERVAL
    HB_INTERVAL="${HB_INTERVAL:-10}"
    read -rp "Heartbeat timeout (sec) [25]: " HB_TIMEOUT
    HB_TIMEOUT="${HB_TIMEOUT:-25}"

    # Workers
    read -rp "Workers (0=auto): " WORKERS
    WORKERS="${WORKERS:-0}"
    read -rp "Channel size [10000]: " CH_SIZE
    CH_SIZE="${CH_SIZE:-10000}"

    # Write config
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
[transport]
type = "tun"
heartbeat_interval = ${HB_INTERVAL}
heartbeat_timeout = ${HB_TIMEOUT}

[tun]
encapsulation = "ipx"
name = "${TUN_NAME}"
local_addr = "${LOCAL_ADDR}"
remote_addr = "${REMOTE_ADDR}"
health_port = ${TUNNEL_PORT}
mtu = ${MTU}

[ipx]
mode = "${MODE}"
profile = "udp"
listen_ip = "${LISTEN_IP}"
dst_ip = "${DST_IP}"
spoof_src_ip = "${SPOOF_SRC}"
spoof_dst_ip = "${SPOOF_DST}"
interface = "${NET_IFACE}"

[security]
enable_encryption = false

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = ${WORKERS}
channel_size = ${CH_SIZE}
so_sndbuf = 0
batch_size = 2048

[logging]
log_level = "info"
EOF

    echo -e "\n${GREEN}Config saved to ${CONFIG_FILE}${NC}"
    echo -e "${YELLOW}Review:${NC}"
    echo "  Mode:       ${MODE}"
    echo "  TUN:        ${TUN_NAME} (${LOCAL_ADDR} <-> ${REMOTE_ADDR})"
    echo "  Listen:     ${LISTEN_IP}:${TUNNEL_PORT}"
    echo "  Dest:       ${DST_IP}:${TUNNEL_PORT}"
    echo "  Spoof Src:  ${SPOOF_SRC}"
    echo "  Spoof Dst:  ${SPOOF_DST}"
}

# ════════════════════════════════════════
# Service controls
# ════════════════════════════════════════
do_start() {
    check_root
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}No config found! Run Configure first.${NC}"
        return 1
    fi
    systemctl start "$SERVICE_NAME"
    sleep 1
    systemctl status "$SERVICE_NAME" --no-pager -l | head -15
}

do_stop() {
    check_root
    systemctl stop "$SERVICE_NAME"
    echo -e "${YELLOW}Service stopped${NC}"
}

do_restart() {
    check_root
    systemctl restart "$SERVICE_NAME"
    sleep 1
    systemctl status "$SERVICE_NAME" --no-pager -l | head -15
}

do_status() {
    echo -e "\n${CYAN}── Service Status ──${NC}"
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || echo -e "${RED}Service not found${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "\n${CYAN}── Current Config ──${NC}"
        grep -E "^(mode|listen_ip|dst_ip|spoof_src|spoof_dst|health_port|mtu|workers)" "$CONFIG_FILE" 2>/dev/null || cat "$CONFIG_FILE"
    fi
}

do_logs() {
    journalctl -u "$SERVICE_NAME" -f --no-pager -n 50
}

do_edit_config() {
    if [ -f "$CONFIG_FILE" ]; then
        ${EDITOR:-nano} "$CONFIG_FILE"
        echo -e "${YELLOW}Restart service to apply changes: systemctl restart ${SERVICE_NAME}${NC}"
    else
        echo -e "${RED}No config file found. Run Configure first.${NC}"
    fi
}

do_uninstall() {
    check_root
    echo -e "${RED}This will remove Spoof Tunnel completely.${NC}"
    read -rp "Are you sure? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        return
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "${INSTALL_DIR}/${BINARY_NAME}"

    echo -e "${RED}Binary and service removed.${NC}"
    read -rp "Remove config too? (y/N): " rm_config
    if [ "$rm_config" = "y" ] || [ "$rm_config" = "Y" ]; then
        rm -rf "$CONFIG_DIR"
        echo -e "${RED}Config removed.${NC}"
    else
        echo -e "${YELLOW}Config kept at ${CONFIG_DIR}/${NC}"
    fi
}

# ════════════════════════════════════════
# Main Menu
# ════════════════════════════════════════
show_menu() {
    print_banner
    echo -e "  Status: $(get_status)"
    echo ""
    echo -e "  ${BOLD}1)${NC} Install"
    echo -e "  ${BOLD}2)${NC} Configure Tunnel"
    echo -e "  ${BOLD}3)${NC} Start"
    echo -e "  ${BOLD}4)${NC} Stop"
    echo -e "  ${BOLD}5)${NC} Restart"
    echo -e "  ${BOLD}6)${NC} Status & Info"
    echo -e "  ${BOLD}7)${NC} View Logs"
    echo -e "  ${BOLD}8)${NC} Edit Config File"
    echo -e "  ${BOLD}9)${NC} Uninstall"
    echo -e "  ${BOLD}0)${NC} Exit"
    echo ""
    read -rp "  Select option: " choice
}

# Direct command mode
if [ -n "$1" ]; then
    case "$1" in
        install)    do_install ;;
        configure)  do_configure ;;
        start)      do_start ;;
        stop)       do_stop ;;
        restart)    do_restart ;;
        status)     do_status ;;
        logs)       do_logs ;;
        edit)       do_edit_config ;;
        uninstall)  do_uninstall ;;
        *)          echo "Usage: $0 {install|configure|start|stop|restart|status|logs|edit|uninstall}" ;;
    esac
    exit 0
fi

# Interactive menu loop
while true; do
    show_menu
    case "$choice" in
        1) do_install; read -rp "Press Enter..." ;;
        2) do_configure; read -rp "Press Enter..." ;;
        3) do_start; read -rp "Press Enter..." ;;
        4) do_stop; read -rp "Press Enter..." ;;
        5) do_restart; read -rp "Press Enter..." ;;
        6) do_status; read -rp "Press Enter..." ;;
        7) do_logs ;;
        8) do_edit_config; read -rp "Press Enter..." ;;
        9) do_uninstall; read -rp "Press Enter..." ;;
        0) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
    esac
done

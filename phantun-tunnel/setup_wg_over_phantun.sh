#!/bin/bash

# ==========================================
#  WireGuard over Phantun Setup v1.0
#  Architecture: TCP (App) -> WireGuard (UDP) -> Phantun (Fake TCP)
#
#  Prereq: Phantun already installed and running
#  Result: Private IPs for Nginx upstream
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WG_IFACE="wg_ph"
WG_PORT=51820
WG_DIR="/etc/wireguard"
PHANTUN_BIN="/usr/local/bin"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

log_info()  { echo -e "${GREEN}[OK]${NC} $1"; }
log_step()  { echo -e "${CYAN}>>>${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1"; }

# ==========================================
# Install WireGuard
# ==========================================
install_wireguard() {
    if command -v wg &>/dev/null; then
        log_info "WireGuard already installed"
        return 0
    fi

    log_step "Installing WireGuard..."
    apt-get update -qq
    apt-get install -y -qq wireguard wireguard-tools > /dev/null 2>&1

    if command -v wg &>/dev/null; then
        log_info "WireGuard installed"
    else
        log_err "WireGuard installation failed"
        exit 1
    fi
}

# ==========================================
# Generate Keys
# ==========================================
generate_keys() {
    mkdir -p "$WG_DIR"
    if [ ! -f "${WG_DIR}/${WG_IFACE}_private" ]; then
        wg genkey | tee "${WG_DIR}/${WG_IFACE}_private" | wg pubkey > "${WG_DIR}/${WG_IFACE}_public"
        chmod 600 "${WG_DIR}/${WG_IFACE}_private"
        log_info "Keys generated"
    else
        log_info "Keys already exist"
    fi
}

# ==========================================
# Setup KHAREJ (Server)
# ==========================================
setup_server() {
    echo ""
    echo -e "${BLUE}=== WireGuard Server (KHAREJ) ===${NC}"
    echo ""

    install_wireguard
    generate_keys

    PRIVATE_KEY=$(cat "${WG_DIR}/${WG_IFACE}_private")
    PUBLIC_KEY=$(cat "${WG_DIR}/${WG_IFACE}_public")

    read -p "Enter Tunnel ID (same as Phantun) [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "Enter WireGuard private IP for THIS server [10.10.10.1]: " WG_IP
    WG_IP=${WG_IP:-10.10.10.1}

    read -p "Enter WireGuard port [51820]: " WG_PORT
    WG_PORT=${WG_PORT:-51820}

    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo -e "${YELLOW}  YOUR PUBLIC KEY (copy to IRAN server):${NC}"
    echo ""
    echo -e "  ${GREEN}${PUBLIC_KEY}${NC}"
    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo ""

    read -p "Paste IRAN server's public key: " PEER_KEY
    if [ -z "$PEER_KEY" ]; then
        log_err "Peer key required! Run this script on IRAN first to get the key."
        return 1
    fi

    # Create WireGuard config
    log_step "Creating WireGuard config..."
    cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${WG_IP}/24
ListenPort = ${WG_PORT}
MTU = 1280

[Peer]
PublicKey = ${PEER_KEY}
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
EOF

    # Update Phantun server to forward to WireGuard
    log_step "Updating Phantun to forward to WireGuard..."
    SVC_FILE="/etc/systemd/system/phantun-server-${TUN_ID}.service"

    if [ -f "$SVC_FILE" ]; then
        # Read current TCP port from service file
        CURRENT_TCP_PORT=$(grep -oP '\-\-local \K[0-9]+' "$SVC_FILE" || echo "4567")

        cat > "$SVC_FILE" <<EOF
[Unit]
Description=Phantun Server Tunnel ${TUN_ID} (WG)
After=network.target

[Service]
Type=simple
Environment=RUST_LOG=info
ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=${PHANTUN_BIN}/phantun_server --local ${CURRENT_TCP_PORT} --remote 127.0.0.1:${WG_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        log_info "Phantun updated: forwarding to 127.0.0.1:${WG_PORT}"
    else
        log_err "Phantun service file not found: ${SVC_FILE}"
        echo "Make sure Phantun is set up first (tunnel ID: ${TUN_ID})"
        return 1
    fi

    # Start services
    log_step "Starting services..."
    systemctl daemon-reload
    systemctl restart "phantun-server-${TUN_ID}"
    sleep 1

    # Enable and start WireGuard
    systemctl enable "wg-quick@${WG_IFACE}" 2>/dev/null
    wg-quick down "$WG_IFACE" 2>/dev/null
    wg-quick up "$WG_IFACE"

    sleep 2

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Server Setup Complete!${NC}"
    echo -e "${GREEN}  WireGuard IP  : ${WG_IP}${NC}"
    echo -e "${GREEN}  WG Listen Port: ${WG_PORT}${NC}"
    echo -e "${GREEN}  Phantun TCP   : ${CURRENT_TCP_PORT}${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${CYAN}  WireGuard status:${NC}"
    wg show "$WG_IFACE" 2>/dev/null || echo "  Not running yet"
    echo ""
}

# ==========================================
# Setup IRAN (Client)
# ==========================================
setup_client() {
    echo ""
    echo -e "${BLUE}=== WireGuard Client (IRAN) ===${NC}"
    echo ""

    install_wireguard
    generate_keys

    PRIVATE_KEY=$(cat "${WG_DIR}/${WG_IFACE}_private")
    PUBLIC_KEY=$(cat "${WG_DIR}/${WG_IFACE}_public")

    read -p "Enter Tunnel ID (same as Phantun) [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "Enter WireGuard private IP for THIS server [10.10.10.2]: " WG_IP
    WG_IP=${WG_IP:-10.10.10.2}

    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo -e "${YELLOW}  YOUR PUBLIC KEY (copy to KHAREJ server):${NC}"
    echo ""
    echo -e "  ${GREEN}${PUBLIC_KEY}${NC}"
    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo ""

    read -p "Paste KHAREJ server's public key: " PEER_KEY
    if [ -z "$PEER_KEY" ]; then
        log_err "Peer key required! Run this script on KHAREJ first to get the key."
        return 1
    fi

    # Get Phantun client local port
    SVC_FILE="/etc/systemd/system/phantun-client-${TUN_ID}.service"
    if [ -f "$SVC_FILE" ]; then
        PHANTUN_LOCAL=$(grep -oP '\-\-local \K[^\s]+' "$SVC_FILE" || echo "127.0.0.1:4567")
        log_info "Phantun client local: ${PHANTUN_LOCAL}"
    else
        log_err "Phantun service file not found: ${SVC_FILE}"
        echo "Make sure Phantun is set up first (tunnel ID: ${TUN_ID})"
        return 1
    fi

    # WireGuard endpoint = Phantun client's local listen address
    WG_ENDPOINT="${PHANTUN_LOCAL}"

    # Create WireGuard config
    log_step "Creating WireGuard config..."
    cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${WG_IP}/24
MTU = 1280

[Peer]
PublicKey = ${PEER_KEY}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
EOF

    # Enable and start WireGuard
    log_step "Starting WireGuard..."
    systemctl enable "wg-quick@${WG_IFACE}" 2>/dev/null
    wg-quick down "$WG_IFACE" 2>/dev/null
    wg-quick up "$WG_IFACE"

    sleep 2

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Client Setup Complete!${NC}"
    echo -e "${GREEN}  WireGuard IP : ${WG_IP}${NC}"
    echo -e "${GREEN}  Endpoint     : ${WG_ENDPOINT} (via Phantun)${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${CYAN}  WireGuard status:${NC}"
    wg show "$WG_IFACE" 2>/dev/null || echo "  Not running yet"
    echo ""

    echo -e "${YELLOW}  Test: ping 10.10.10.1${NC}"
    echo -e "${YELLOW}  If ping works, Nginx upstream = 10.10.10.1:PORT${NC}"
}

# ==========================================
# Test
# ==========================================
test_wg() {
    echo ""
    echo -e "${BLUE}=== WireGuard Test ===${NC}"
    echo ""

    echo -e "${CYAN}Interface status:${NC}"
    wg show "$WG_IFACE" 2>/dev/null || echo "  WireGuard interface not found"

    echo ""
    echo -e "${CYAN}IP addresses:${NC}"
    ip -br addr show "$WG_IFACE" 2>/dev/null || echo "  No interface"

    echo ""
    echo -e "${CYAN}Ping test:${NC}"
    echo "Which IP to ping?"
    echo "  1) 10.10.10.1 (Kharej)"
    echo "  2) 10.10.10.2 (Iran)"
    read -p "Select: " ping_opt

    case $ping_opt in
        1) TARGET="10.10.10.1" ;;
        2) TARGET="10.10.10.2" ;;
        *) TARGET="10.10.10.1" ;;
    esac

    echo ""
    ping -c 5 -W 3 "$TARGET"

    echo ""
    echo -e "${CYAN}Phantun service:${NC}"
    systemctl list-units --type=service --state=running | grep phantun || echo "  No Phantun running"
}

# ==========================================
# Uninstall
# ==========================================
uninstall_wg() {
    echo ""
    log_step "Removing WireGuard..."

    wg-quick down "$WG_IFACE" 2>/dev/null
    systemctl disable "wg-quick@${WG_IFACE}" 2>/dev/null

    rm -f "${WG_DIR}/${WG_IFACE}.conf"
    rm -f "${WG_DIR}/${WG_IFACE}_private"
    rm -f "${WG_DIR}/${WG_IFACE}_public"

    log_info "WireGuard removed (Phantun untouched)"
}

# ==========================================
# Menu
# ==========================================
clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  WireGuard over Phantun v1.0${NC}"
echo -e "${GREEN}  App -> WG (UDP) -> Phantun (Fake TCP)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "1) Setup KHAREJ (Server)"
echo "2) Setup IRAN (Client)"
echo "3) Test Connection"
echo "4) Show WireGuard Status"
echo "5) Uninstall WireGuard"
echo "0) Exit"
echo ""
read -p "Select: " opt

case $opt in
    1) setup_server ;;
    2) setup_client ;;
    3) test_wg ;;
    4) wg show "$WG_IFACE" 2>/dev/null && ip -br addr show "$WG_IFACE" || echo "Not configured" ;;
    5) uninstall_wg ;;
    *) exit 0 ;;
esac

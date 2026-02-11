#!/bin/bash

# ==========================================
#  WireGuard over udp2raw v1.0
#  Architecture: App -> WireGuard (Private IP) -> UDP -> udp2raw (disguise) -> Server
#  MTU optimized for XTLS Reality / v2ray
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

UDP2RAW_BIN="/usr/local/bin/udp2raw"
UDP2RAW_URL="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"

WG_IFACE="wg_u2r"
WG_PORT=51820
WG_DIR="/etc/wireguard"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

log_info()  { echo -e "${GREEN}[OK]${NC} $1"; }
log_step()  { echo -e "${CYAN}>>>${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1"; }

# ==========================================
# Install Dependencies
# ==========================================
install_deps() {
    # udp2raw
    if [ ! -f "$UDP2RAW_BIN" ]; then
        log_step "Installing udp2raw..."
        apt-get update -qq
        apt-get install -y -qq curl tar > /dev/null 2>&1

        TMP_DIR=$(mktemp -d)
        curl -4L --connect-timeout 30 --max-time 120 -o "${TMP_DIR}/udp2raw.tar.gz" "$UDP2RAW_URL"

        FILE_SIZE=$(stat -c%s "${TMP_DIR}/udp2raw.tar.gz" 2>/dev/null || echo 0)
        if [ "$FILE_SIZE" -lt 100000 ]; then
            log_err "udp2raw download failed"
            rm -rf "$TMP_DIR"
            return 1
        fi

        tar xzf "${TMP_DIR}/udp2raw.tar.gz" -C "${TMP_DIR}/"
        if [ -f "${TMP_DIR}/udp2raw_amd64" ]; then
            cp "${TMP_DIR}/udp2raw_amd64" "$UDP2RAW_BIN"
        elif [ -f "${TMP_DIR}/udp2raw" ]; then
            cp "${TMP_DIR}/udp2raw" "$UDP2RAW_BIN"
        fi
        chmod +x "$UDP2RAW_BIN"
        rm -rf "$TMP_DIR"
        log_info "udp2raw installed"
    else
        log_info "udp2raw already installed"
    fi

    # WireGuard
    if ! command -v wg &>/dev/null; then
        log_step "Installing WireGuard..."
        apt-get update -qq
        apt-get install -y -qq wireguard wireguard-tools > /dev/null 2>&1
        log_info "WireGuard installed"
    else
        log_info "WireGuard already installed"
    fi
}

# ==========================================
# Select udp2raw Mode
# ==========================================
select_mode() {
    echo ""
    echo "Select udp2raw mode:"
    echo "  1) UDP   (recommended)"
    echo "  2) ICMP  (disguise as ping)"
    echo ""
    read -p "Mode [1]: " mode_opt
    case $mode_opt in
        2) RAW_MODE="icmp" ;;
        *) RAW_MODE="udp" ;;
    esac
    log_info "Mode: ${RAW_MODE}"
}

# ==========================================
# Generate WireGuard Keys
# ==========================================
gen_wg_keys() {
    mkdir -p "$WG_DIR"
    PRIV_KEY=$(wg genkey)
    PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)
    echo "$PRIV_KEY" > "${WG_DIR}/${WG_IFACE}_private"
    echo "$PUB_KEY" > "${WG_DIR}/${WG_IFACE}_public"
    chmod 600 "${WG_DIR}/${WG_IFACE}_private"
}

# ==========================================
# Setup KHAREJ (Server)
# ==========================================
setup_server() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  KHAREJ Server: WireGuard + udp2raw${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    install_deps || return 1
    select_mode

    read -p "Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "udp2raw listen port [4096]: " RAW_PORT
    RAW_PORT=${RAW_PORT:-4096}

    read -p "udp2raw password [tunnel123]: " PASSWORD
    PASSWORD=${PASSWORD:-tunnel123}

    read -p "WireGuard private IP [10.77.${TUN_ID}.1]: " WG_IP
    WG_IP=${WG_IP:-10.77.${TUN_ID}.1}

    PEER_IP="10.77.${TUN_ID}.2"

    read -p "WireGuard MTU [1200]: " WG_MTU
    WG_MTU=${WG_MTU:-1200}

    # Generate keys
    gen_wg_keys
    log_info "Server public key: ${PUB_KEY}"
    echo ""
    echo -e "${YELLOW}  Copy this key for the client setup!${NC}"
    echo -e "${GREEN}  Server Public Key: ${PUB_KEY}${NC}"
    echo ""
    read -p "Enter CLIENT public key (or press Enter to set later): " CLIENT_PUB

    echo ""
    echo -e "${BLUE}========= Config =========${NC}"
    echo -e "  udp2raw  : 0.0.0.0:${RAW_PORT} (${RAW_MODE}) -> 127.0.0.1:${WG_PORT}"
    echo -e "  WG IP    : ${WG_IP}/24"
    echo -e "  Peer     : ${PEER_IP}"
    echo -e "  MTU      : ${WG_MTU}"
    echo -e "${BLUE}==========================${NC}"
    read -p "Press ENTER to apply..."

    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # WireGuard config
    log_step "Creating WireGuard config..."
    cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${WG_IP}/24
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}
EOF

    if [ -n "$CLIENT_PUB" ]; then
        cat >> "${WG_DIR}/${WG_IFACE}.conf" <<EOF

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${PEER_IP}/32, 10.77.${TUN_ID}.0/24
PersistentKeepalive = 25
EOF
    fi

    # udp2raw service: forwards to WireGuard
    log_step "Creating udp2raw service..."
    cat > "/etc/systemd/system/udp2raw-wg-server-${TUN_ID}.service" <<EOF
[Unit]
Description=udp2raw WG Server ${TUN_ID} (${RAW_MODE})
After=network.target
Before=wg-quick@${WG_IFACE}.service

[Service]
Type=simple
ExecStart=${UDP2RAW_BIN} -s -l 0.0.0.0:${RAW_PORT} -r 127.0.0.1:${WG_PORT} --raw-mode ${RAW_MODE} -a -k "${PASSWORD}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "udp2raw-wg-server-${TUN_ID}"
    systemctl restart "udp2raw-wg-server-${TUN_ID}"

    sleep 2

    # Start WireGuard
    log_step "Starting WireGuard..."
    wg-quick down "$WG_IFACE" 2>/dev/null
    wg-quick up "$WG_IFACE"

    systemctl enable "wg-quick@${WG_IFACE}"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Server Ready!${NC}"
    echo -e "${GREEN}  WireGuard IP : ${WG_IP}${NC}"
    echo -e "${GREEN}  udp2raw      : port ${RAW_PORT} (${RAW_MODE})${NC}"
    echo -e "${GREEN}  Public Key   : ${PUB_KEY}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    if [ -z "$CLIENT_PUB" ]; then
        echo -e "${YELLOW}  Add client peer later:${NC}"
        echo -e "  wg set ${WG_IFACE} peer CLIENT_PUB_KEY allowed-ips ${PEER_IP}/32 persistent-keepalive 25"
    fi
    echo -e "${YELLOW}  Service: udp2raw-wg-server-${TUN_ID}${NC}"
    echo ""
    wg show "$WG_IFACE" 2>/dev/null
}

# ==========================================
# Setup IRAN (Client)
# ==========================================
setup_client() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  IRAN Client: WireGuard + udp2raw${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    install_deps || return 1
    select_mode

    read -p "Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "KHAREJ server public IP: " REMOTE_IP
    if [ -z "$REMOTE_IP" ]; then
        log_err "Remote IP required"
        return 1
    fi

    read -p "udp2raw remote port (same as server) [4096]: " RAW_PORT
    RAW_PORT=${RAW_PORT:-4096}

    read -p "udp2raw password (same as server) [tunnel123]: " PASSWORD
    PASSWORD=${PASSWORD:-tunnel123}

    read -p "WireGuard private IP [10.77.${TUN_ID}.2]: " WG_IP
    WG_IP=${WG_IP:-10.77.${TUN_ID}.2}

    PEER_IP="10.77.${TUN_ID}.1"

    read -p "WireGuard MTU [1200]: " WG_MTU
    WG_MTU=${WG_MTU:-1200}

    # Generate keys
    gen_wg_keys
    log_info "Client public key: ${PUB_KEY}"
    echo ""

    read -p "Enter SERVER public key: " SERVER_PUB
    if [ -z "$SERVER_PUB" ]; then
        log_err "Server public key required"
        return 1
    fi

    # Local port for udp2raw client
    LOCAL_RAW_PORT=14096

    echo ""
    echo -e "${BLUE}========= Config =========${NC}"
    echo -e "  udp2raw  : 127.0.0.1:${LOCAL_RAW_PORT} -> ${REMOTE_IP}:${RAW_PORT} (${RAW_MODE})"
    echo -e "  WG IP    : ${WG_IP}/24"
    echo -e "  Peer     : ${PEER_IP}"
    echo -e "  MTU      : ${WG_MTU}"
    echo -e "${BLUE}==========================${NC}"
    read -p "Press ENTER to apply..."

    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # udp2raw client service
    log_step "Creating udp2raw service..."
    cat > "/etc/systemd/system/udp2raw-wg-client-${TUN_ID}.service" <<EOF
[Unit]
Description=udp2raw WG Client ${TUN_ID} (${RAW_MODE})
After=network.target
Before=wg-quick@${WG_IFACE}.service

[Service]
Type=simple
ExecStart=${UDP2RAW_BIN} -c -l 127.0.0.1:${LOCAL_RAW_PORT} -r ${REMOTE_IP}:${RAW_PORT} --raw-mode ${RAW_MODE} -a -k "${PASSWORD}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "udp2raw-wg-client-${TUN_ID}"
    systemctl restart "udp2raw-wg-client-${TUN_ID}"

    sleep 3

    # WireGuard config — endpoint is udp2raw local port
    log_step "Creating WireGuard config..."
    cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${WG_IP}/24
MTU = ${WG_MTU}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = 127.0.0.1:${LOCAL_RAW_PORT}
AllowedIPs = ${PEER_IP}/32, 10.77.${TUN_ID}.0/24
PersistentKeepalive = 25
EOF

    # Start WireGuard
    log_step "Starting WireGuard..."
    wg-quick down "$WG_IFACE" 2>/dev/null
    wg-quick up "$WG_IFACE"

    systemctl enable "wg-quick@${WG_IFACE}"

    sleep 3

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Client Ready!${NC}"
    echo -e "${GREEN}  WireGuard IP : ${WG_IP}${NC}"
    echo -e "${GREEN}  Peer IP      : ${PEER_IP}${NC}"
    echo -e "${GREEN}  Public Key   : ${PUB_KEY}${NC}"
    echo -e "${GREEN}  Endpoint     : 127.0.0.1:${LOCAL_RAW_PORT} (via udp2raw)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}  Set this key on server:${NC}"
    echo -e "  wg set ${WG_IFACE} peer ${PUB_KEY} allowed-ips ${WG_IP}/32 persistent-keepalive 25"
    echo ""
    echo -e "${YELLOW}  Test: ping ${PEER_IP}${NC}"
    echo -e "${YELLOW}  Nginx/v2ray upstream: ${PEER_IP}:PORT${NC}"
    echo ""
    wg show "$WG_IFACE" 2>/dev/null
}

# ==========================================
# Add Peer (for server after client setup)
# ==========================================
add_peer() {
    echo ""
    echo -e "${BLUE}=== Add Peer to WireGuard ===${NC}"
    echo ""

    read -p "Client public key: " CLIENT_PUB
    if [ -z "$CLIENT_PUB" ]; then
        log_err "Key required"
        return
    fi

    read -p "Client WireGuard IP [10.77.1.2]: " CLIENT_IP
    CLIENT_IP=${CLIENT_IP:-10.77.1.2}

    wg set "$WG_IFACE" peer "$CLIENT_PUB" allowed-ips "${CLIENT_IP}/32" persistent-keepalive 25

    # Save to config
    wg-quick save "$WG_IFACE" 2>/dev/null

    log_info "Peer added!"
    echo ""
    wg show "$WG_IFACE"
}

# ==========================================
# Test
# ==========================================
test_tunnel() {
    echo ""
    echo -e "${BLUE}=== Connection Test ===${NC}"
    echo ""

    echo -e "${CYAN}udp2raw:${NC}"
    systemctl status udp2raw-wg-server-* --no-pager -l 2>/dev/null | head -5
    systemctl status udp2raw-wg-client-* --no-pager -l 2>/dev/null | head -5

    echo ""
    echo -e "${CYAN}WireGuard:${NC}"
    wg show "$WG_IFACE" 2>/dev/null || echo "  Not running"

    echo ""
    read -p "Ping peer IP [10.77.1.1]: " PING_IP
    PING_IP=${PING_IP:-10.77.1.1}
    ping -c 5 -W 3 "$PING_IP"
}

# ==========================================
# Remove Tunnels (keep binaries)
# ==========================================
clean_tunnels() {
    echo ""
    echo -e "${YELLOW}=== REMOVE TUNNELS ===${NC}"
    echo "Removes: WireGuard + udp2raw services (keeps binaries)"
    read -p "Are you sure? (yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then return; fi

    # WireGuard
    wg-quick down "$WG_IFACE" 2>/dev/null
    systemctl disable "wg-quick@${WG_IFACE}" 2>/dev/null
    rm -f "${WG_DIR}/${WG_IFACE}.conf"
    rm -f "${WG_DIR}/${WG_IFACE}_private"
    rm -f "${WG_DIR}/${WG_IFACE}_public"

    # udp2raw services
    for i in $(seq 1 10); do
        systemctl stop "udp2raw-wg-server-${i}" 2>/dev/null
        systemctl stop "udp2raw-wg-client-${i}" 2>/dev/null
        systemctl disable "udp2raw-wg-server-${i}" 2>/dev/null
        systemctl disable "udp2raw-wg-client-${i}" 2>/dev/null
        rm -f "/etc/systemd/system/udp2raw-wg-server-${i}.service"
        rm -f "/etc/systemd/system/udp2raw-wg-client-${i}.service"
    done

    systemctl daemon-reload
    log_info "Tunnels removed (binaries kept)"
}

# ==========================================
# Full Uninstall
# ==========================================
full_uninstall() {
    echo ""
    echo -e "${RED}=== FULL UNINSTALL ===${NC}"
    echo "Removes EVERYTHING including binaries"
    read -p "Are you sure? (yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then return; fi

    clean_tunnels
    rm -f "$UDP2RAW_BIN"
    log_info "Everything removed!"
}

# ==========================================
# Menu
# ==========================================
clear
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  WireGuard over udp2raw  v1.0${NC}"
echo -e "${GREEN}  Private IP + DPI Bypass${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo "1) Setup KHAREJ (Server)"
echo "2) Setup IRAN (Client)"
echo "3) Add Peer Key"
echo "4) Test Connection"
echo "5) Remove Tunnels (keep binaries)"
echo "6) Full Uninstall"
echo "0) Exit"
echo ""
read -p "Select: " opt

case $opt in
    1) setup_server ;;
    2) setup_client ;;
    3) add_peer ;;
    4) test_tunnel ;;
    5) clean_tunnels ;;
    6) full_uninstall ;;
    *) exit 0 ;;
esac

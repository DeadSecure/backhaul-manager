#!/bin/bash

# ==========================================
#  IPIP + FOU Tunnel Setup v1.0
#  Architecture: TCP (App) -> IPIP (Private IP) -> FOU (UDP) -> Network
#
#  This gives private IPs for Nginx upstream
#  FOU makes IPIP look like normal UDP traffic (less DPI detection)
#
#  IRAN  = has Nginx with upstream
#  KHAREJ = receives traffic, forwards to backend
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

log_info()  { echo -e "${GREEN}[OK]${NC} $1"; }
log_step()  { echo -e "${CYAN}>>>${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1"; }

# ==========================================
# Setup KHAREJ (Server)
# ==========================================
setup_server() {
    echo ""
    echo -e "${BLUE}=== KHAREJ Server (IPIP + FOU) ===${NC}"
    echo ""

    read -p "Enter Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "Enter IRAN server public IP: " REMOTE_IP
    if [ -z "$REMOTE_IP" ]; then
        log_err "Remote IP required"
        return 1
    fi

    read -p "Enter FOU UDP port [6000]: " FOU_PORT
    FOU_PORT=${FOU_PORT:-6000}

    read -p "Enter private IP for THIS server [10.10.${TUN_ID}.1]: " MY_IP
    MY_IP=${MY_IP:-10.10.${TUN_ID}.1}

    read -p "Enter private IP for IRAN server [10.10.${TUN_ID}.2]: " PEER_IP
    PEER_IP=${PEER_IP:-10.10.${TUN_ID}.2}

    # Detect local public IP
    LOCAL_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    log_info "Detected local IP: ${LOCAL_IP}"
    read -p "Use this IP? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        read -p "Enter local public IP: " LOCAL_IP
    fi

    IFACE_NAME="ipip_ph${TUN_ID}"

    echo ""
    echo -e "${BLUE}========= Config =========${NC}"
    echo -e "  Tunnel     : ${IFACE_NAME}"
    echo -e "  Local IP   : ${LOCAL_IP}"
    echo -e "  Remote IP  : ${REMOTE_IP}"
    echo -e "  FOU Port   : ${FOU_PORT}"
    echo -e "  Private IP : ${MY_IP}/30"
    echo -e "  Peer IP    : ${PEER_IP}/30"
    echo -e "${BLUE}==========================${NC}"
    read -p "Press ENTER to apply..."

    # Load modules
    log_step "Loading kernel modules..."
    modprobe fou
    modprobe ipip

    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # Clean up existing
    ip link del "$IFACE_NAME" 2>/dev/null
    ip fou del port "$FOU_PORT" 2>/dev/null

    # Setup FOU receiver
    log_step "Setting up FOU on port ${FOU_PORT}..."
    ip fou add port "$FOU_PORT" ipproto 4

    # Create IPIP tunnel with FOU encapsulation
    log_step "Creating IPIP tunnel..."
    ip link add "$IFACE_NAME" type ipip \
        remote "$REMOTE_IP" \
        local "$LOCAL_IP" \
        encap fou \
        encap-sport auto \
        encap-dport "$FOU_PORT"

    ip addr add "${MY_IP}/30" dev "$IFACE_NAME"
    ip link set "$IFACE_NAME" up mtu 1400

    # Create persistent service
    log_step "Creating systemd service..."
    cat > "/etc/systemd/system/ipip-fou-${TUN_ID}.service" <<EOF
[Unit]
Description=IPIP+FOU Tunnel ${TUN_ID} (Server)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Load modules
ExecStartPre=/sbin/modprobe fou
ExecStartPre=/sbin/modprobe ipip
ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1

# Clean old
ExecStartPre=-/sbin/ip link del ${IFACE_NAME}
ExecStartPre=-/sbin/ip fou del port ${FOU_PORT}

# Setup
ExecStart=/bin/bash -c '\
    ip fou add port ${FOU_PORT} ipproto 4 && \
    ip link add ${IFACE_NAME} type ipip \
        remote ${REMOTE_IP} local ${LOCAL_IP} \
        encap fou encap-sport auto encap-dport ${FOU_PORT} && \
    ip addr add ${MY_IP}/30 dev ${IFACE_NAME} && \
    ip link set ${IFACE_NAME} up mtu 1400'

# Cleanup
ExecStop=/sbin/ip link del ${IFACE_NAME}
ExecStop=/sbin/ip fou del port ${FOU_PORT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "ipip-fou-${TUN_ID}"

    log_info "Tunnel created!"
    echo ""
    ip -br addr show "$IFACE_NAME"
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Server ready!${NC}"
    echo -e "${GREEN}  Private IP: ${MY_IP}${NC}"
    echo -e "${GREEN}  Service: ipip-fou-${TUN_ID}${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}  Now run on IRAN server with same FOU port${NC}"
}

# ==========================================
# Setup IRAN (Client)
# ==========================================
setup_client() {
    echo ""
    echo -e "${BLUE}=== IRAN Server (IPIP + FOU) ===${NC}"
    echo ""

    read -p "Enter Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "Enter KHAREJ server public IP: " REMOTE_IP
    if [ -z "$REMOTE_IP" ]; then
        log_err "Remote IP required"
        return 1
    fi

    read -p "Enter FOU UDP port (same as server) [6000]: " FOU_PORT
    FOU_PORT=${FOU_PORT:-6000}

    read -p "Enter private IP for THIS server [10.10.${TUN_ID}.2]: " MY_IP
    MY_IP=${MY_IP:-10.10.${TUN_ID}.2}

    read -p "Enter private IP for KHAREJ server [10.10.${TUN_ID}.1]: " PEER_IP
    PEER_IP=${PEER_IP:-10.10.${TUN_ID}.1}

    # Detect local IP
    LOCAL_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    log_info "Detected local IP: ${LOCAL_IP}"
    read -p "Use this IP? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        read -p "Enter local public IP: " LOCAL_IP
    fi

    IFACE_NAME="ipip_ph${TUN_ID}"

    echo ""
    echo -e "${BLUE}========= Config =========${NC}"
    echo -e "  Tunnel     : ${IFACE_NAME}"
    echo -e "  Local IP   : ${LOCAL_IP}"
    echo -e "  Remote IP  : ${REMOTE_IP}"
    echo -e "  FOU Port   : ${FOU_PORT}"
    echo -e "  Private IP : ${MY_IP}/30"
    echo -e "  Peer IP    : ${PEER_IP}/30"
    echo -e "${BLUE}==========================${NC}"
    read -p "Press ENTER to apply..."

    # Load modules
    log_step "Loading kernel modules..."
    modprobe fou
    modprobe ipip

    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # Clean up
    ip link del "$IFACE_NAME" 2>/dev/null
    ip fou del port "$FOU_PORT" 2>/dev/null

    # Setup FOU receiver
    log_step "Setting up FOU on port ${FOU_PORT}..."
    ip fou add port "$FOU_PORT" ipproto 4

    # Create IPIP tunnel
    log_step "Creating IPIP tunnel..."
    ip link add "$IFACE_NAME" type ipip \
        remote "$REMOTE_IP" \
        local "$LOCAL_IP" \
        encap fou \
        encap-sport auto \
        encap-dport "$FOU_PORT"

    ip addr add "${MY_IP}/30" dev "$IFACE_NAME"
    ip link set "$IFACE_NAME" up mtu 1400

    # Create persistent service
    log_step "Creating systemd service..."
    cat > "/etc/systemd/system/ipip-fou-${TUN_ID}.service" <<EOF
[Unit]
Description=IPIP+FOU Tunnel ${TUN_ID} (Client)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStartPre=/sbin/modprobe fou
ExecStartPre=/sbin/modprobe ipip
ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1

ExecStartPre=-/sbin/ip link del ${IFACE_NAME}
ExecStartPre=-/sbin/ip fou del port ${FOU_PORT}

ExecStart=/bin/bash -c '\
    ip fou add port ${FOU_PORT} ipproto 4 && \
    ip link add ${IFACE_NAME} type ipip \
        remote ${REMOTE_IP} local ${LOCAL_IP} \
        encap fou encap-sport auto encap-dport ${FOU_PORT} && \
    ip addr add ${MY_IP}/30 dev ${IFACE_NAME} && \
    ip link set ${IFACE_NAME} up mtu 1400'

ExecStop=/sbin/ip link del ${IFACE_NAME}
ExecStop=/sbin/ip fou del port ${FOU_PORT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "ipip-fou-${TUN_ID}"

    log_info "Tunnel created!"
    echo ""
    ip -br addr show "$IFACE_NAME"
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Client ready!${NC}"
    echo -e "${GREEN}  Private IP: ${MY_IP}${NC}"
    echo -e "${GREEN}  Peer IP:    ${PEER_IP}${NC}"
    echo -e "${GREEN}  Service: ipip-fou-${TUN_ID}${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}  Test: ping ${PEER_IP}${NC}"
    echo -e "${YELLOW}  Nginx upstream: ${PEER_IP}:PORT${NC}"
}

# ==========================================
# Test
# ==========================================
test_tunnel() {
    echo ""
    echo -e "${BLUE}=== Tunnel Test ===${NC}"
    echo ""

    read -p "Enter Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    IFACE_NAME="ipip_ph${TUN_ID}"

    echo -e "${CYAN}Interface:${NC}"
    ip -br addr show "$IFACE_NAME" 2>/dev/null || echo "  Not found"

    echo ""
    echo -e "${CYAN}Tunnel details:${NC}"
    ip tunnel show "$IFACE_NAME" 2>/dev/null || echo "  Not found"

    echo ""
    echo -e "${CYAN}FOU ports:${NC}"
    ip fou show 2>/dev/null || echo "  No FOU ports"

    echo ""
    read -p "Enter peer IP to ping [10.10.1.1]: " PING_IP
    PING_IP=${PING_IP:-10.10.1.1}

    echo -e "${CYAN}Ping test:${NC}"
    ping -c 5 -W 3 "$PING_IP"

    echo ""
    echo -e "${CYAN}Service status:${NC}"
    systemctl status "ipip-fou-${TUN_ID}" --no-pager -l 2>/dev/null || echo "  Service not found"
}

# ==========================================
# Uninstall Single Tunnel
# ==========================================
uninstall_tunnel() {
    read -p "Enter Tunnel ID to remove: " TUN_ID
    if [ -z "$TUN_ID" ]; then return; fi

    IFACE_NAME="ipip_ph${TUN_ID}"

    log_step "Removing tunnel ${TUN_ID}..."

    # IPIP+FOU
    systemctl stop "ipip-fou-${TUN_ID}" 2>/dev/null
    systemctl disable "ipip-fou-${TUN_ID}" 2>/dev/null
    rm -f "/etc/systemd/system/ipip-fou-${TUN_ID}.service"
    ip link del "$IFACE_NAME" 2>/dev/null

    # FOU port
    ip fou del port 6000 2>/dev/null
    ip fou del port 443 2>/dev/null

    systemctl daemon-reload
    log_info "Tunnel ${TUN_ID} removed"
}

# ==========================================
# CLEAN EVERYTHING
# ==========================================
clean_all() {
    echo ""
    echo -e "${RED}=== CLEAN ALL TUNNELS ===${NC}"
    echo ""
    echo "This will remove:"
    echo "  - All IPIP+FOU tunnels"
    echo "  - All Phantun tunnels"
    echo "  - All WireGuard (wg_ph) tunnels"
    echo "  - Related iptables rules"
    echo "  - Phantun binaries"
    echo ""
    read -p "Are you sure? (yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        return
    fi

    log_step "Removing IPIP+FOU tunnels..."
    for i in $(seq 1 10); do
        systemctl stop "ipip-fou-${i}" 2>/dev/null
        systemctl disable "ipip-fou-${i}" 2>/dev/null
        rm -f "/etc/systemd/system/ipip-fou-${i}.service"
        ip link del "ipip_ph${i}" 2>/dev/null
    done
    # Remove all FOU ports
    ip fou del port 6000 2>/dev/null
    ip fou del port 443 2>/dev/null
    ip fou del port 80 2>/dev/null

    log_step "Removing Phantun tunnels..."
    for i in $(seq 1 10); do
        systemctl stop "phantun-server-${i}" 2>/dev/null
        systemctl stop "phantun-client-${i}" 2>/dev/null
        systemctl stop "phantun-${i}" 2>/dev/null
        systemctl disable "phantun-server-${i}" 2>/dev/null
        systemctl disable "phantun-client-${i}" 2>/dev/null
        systemctl disable "phantun-${i}" 2>/dev/null
        rm -f "/etc/systemd/system/phantun-server-${i}.service"
        rm -f "/etc/systemd/system/phantun-client-${i}.service"
        rm -f "/etc/systemd/system/phantun-${i}.service"
    done

    log_step "Removing WireGuard (wg_ph)..."
    wg-quick down wg_ph 2>/dev/null
    systemctl disable "wg-quick@wg_ph" 2>/dev/null
    rm -f /etc/wireguard/wg_ph.conf
    rm -f /etc/wireguard/wg_ph_private
    rm -f /etc/wireguard/wg_ph_public

    log_step "Removing Phantun binaries..."
    rm -f /usr/local/bin/phantun_server
    rm -f /usr/local/bin/phantun_client
    rm -f /usr/local/bin/phantun.server
    rm -f /usr/local/bin/phantun.client

    log_step "Cleaning iptables rules..."
    # Phantun DNAT/MASQUERADE rules
    iptables -t nat -D PREROUTING -p tcp --dport 4567 -j DNAT --to-destination 192.168.201.2 2>/dev/null
    iptables -t nat -D POSTROUTING -s 192.168.200.0/24 -j MASQUERADE 2>/dev/null
    # Clean Phantun config dir
    rm -rf /etc/phantun

    log_step "Removing TUN interfaces..."
    for i in $(seq 1 10); do
        ip link del "tun_ph${i}" 2>/dev/null
    done

    systemctl daemon-reload

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Everything cleaned!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    echo -e "${CYAN}Remaining tunnel interfaces:${NC}"
    ip link show | grep -E "(ipip_ph|tun_ph|wg_ph)" || echo "  None"
    echo ""
    echo -e "${CYAN}Remaining services:${NC}"
    systemctl list-units --type=service --all | grep -E "(phantun|ipip-fou|wg_ph)" || echo "  None"
}

# ==========================================
# Menu
# ==========================================
clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  IPIP + FOU Tunnel Manager v1.1${NC}"
echo -e "${GREEN}  Simple Private IP Tunnel${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "1) Setup KHAREJ (Server)"
echo "2) Setup IRAN (Client)"
echo "3) Test Connection"
echo "4) Uninstall Single Tunnel"
echo "5) CLEAN EVERYTHING (remove all)"
echo "0) Exit"
echo ""
read -p "Select: " opt

case $opt in
    1) setup_server ;;
    2) setup_client ;;
    3) test_tunnel ;;
    4) uninstall_tunnel ;;
    5) clean_all ;;
    *) exit 0 ;;
esac

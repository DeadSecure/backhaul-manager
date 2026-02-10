#!/bin/bash

# ==========================================
#  Phantun Simple Test Script v1.0
#  Goal: Test basic UDP-to-TCP tunnel connectivity
#  Architecture: UDP <-> Phantun (Fake TCP) <-> UDP
#
#  IRAN  = Client (sends UDP, Phantun wraps to TCP)
#  KHAREJ = Server (receives TCP, Phantun unwraps to UDP)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PHANTUN_BIN="/usr/local/bin"
PHANTUN_VERSION="v0.8.1"
PHANTUN_ZIP_URL="https://github.com/dndx/phantun/releases/download/${PHANTUN_VERSION}/phantun_x86_64-unknown-linux-musl.zip"

# ==========================================
# Root Check
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

# ==========================================
# Helper Functions
# ==========================================
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

get_main_interface() {
    ip route show default | awk '/default/ {print $5}' | head -1
}

# ==========================================
# Install Phantun
# ==========================================
install_phantun() {
    log_step "Installing Phantun ${PHANTUN_VERSION}..."

    # Install dependencies
    apt-get update -qq
    apt-get install -y -qq curl unzip iptables > /dev/null 2>&1

    # Check if already installed
    if [ -f "${PHANTUN_BIN}/phantun_server" ] && [ -f "${PHANTUN_BIN}/phantun_client" ]; then
        INSTALLED_VER=$("${PHANTUN_BIN}/phantun_server" --version 2>/dev/null || echo "unknown")
        log_info "Phantun already installed: ${INSTALLED_VER}"
        read -p "Reinstall? (y/N): " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    # Download
    log_step "Downloading Phantun..."
    TMP_DIR=$(mktemp -d)
    curl -4L --connect-timeout 30 --max-time 120 -o "${TMP_DIR}/phantun.zip" "$PHANTUN_ZIP_URL"

    # Verify size (should be > 1MB)
    FILE_SIZE=$(stat -c%s "${TMP_DIR}/phantun.zip" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        log_err "Download failed or file too small (${FILE_SIZE} bytes)"
        log_warn "You can manually download and place files at:"
        log_warn "  ${PHANTUN_BIN}/phantun_server"
        log_warn "  ${PHANTUN_BIN}/phantun_client"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # Extract
    log_step "Extracting..."
    unzip -o "${TMP_DIR}/phantun.zip" -d "${TMP_DIR}/"

    # Find and install binaries
    # The zip contains 'phantun_server' and 'phantun_client'
    # or 'server' and 'client' depending on version
    if [ -f "${TMP_DIR}/phantun_server" ]; then
        cp "${TMP_DIR}/phantun_server" "${PHANTUN_BIN}/phantun_server"
        cp "${TMP_DIR}/phantun_client" "${PHANTUN_BIN}/phantun_client"
    elif [ -f "${TMP_DIR}/server" ]; then
        cp "${TMP_DIR}/server" "${PHANTUN_BIN}/phantun_server"
        cp "${TMP_DIR}/client" "${PHANTUN_BIN}/phantun_client"
    else
        log_err "Could not find binaries in archive. Contents:"
        ls -la "${TMP_DIR}/"
        rm -rf "$TMP_DIR"
        return 1
    fi

    chmod +x "${PHANTUN_BIN}/phantun_server" "${PHANTUN_BIN}/phantun_client"
    rm -rf "$TMP_DIR"

    # Verify
    if [ -f "${PHANTUN_BIN}/phantun_server" ] && [ -f "${PHANTUN_BIN}/phantun_client" ]; then
        log_info "Phantun installed successfully!"
    else
        log_err "Installation failed"
        return 1
    fi
}

# ==========================================
# Setup KHAREJ (Server)
# ==========================================
setup_server() {
    log_step "=== KHAREJ Server Setup ==="

    read -p "Enter TCP listen port [4567]: " TCP_PORT
    TCP_PORT=${TCP_PORT:-4567}

    # Tunnel ID (for naming)
    read -p "Enter Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    IFACE=$(get_main_interface)
    log_info "Main interface detected: ${IFACE}"
    read -p "Use this interface? (Y/n): " use_iface
    if [[ "$use_iface" =~ ^[Nn]$ ]]; then
        read -p "Enter interface name: " IFACE
    fi

    TUN_NAME="tun_ph${TUN_ID}"

    echo ""
    echo -e "${BLUE}========= Server Config =========${NC}"
    echo -e "  TCP Port    : ${TCP_PORT}"
    echo -e "  TUN Name    : ${TUN_NAME}"
    echo -e "  Interface   : ${IFACE}"
    echo -e "  Phantun IP  : 192.168.201.2 (default)"
    echo -e "${BLUE}=================================${NC}"
    echo ""
    read -p "Press ENTER to apply..."

    # 1. Enable IP forwarding
    log_step "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 2. Setup iptables DNAT rule
    log_step "Adding iptables DNAT rule..."
    # Remove old rule if exists
    iptables -t nat -D PREROUTING -p tcp -i "$IFACE" --dport "$TCP_PORT" -j DNAT --to-destination 192.168.201.2 2>/dev/null
    # Add new rule
    iptables -t nat -A PREROUTING -p tcp -i "$IFACE" --dport "$TCP_PORT" -j DNAT --to-destination 192.168.201.2

    # 3. Create systemd service
    log_step "Creating systemd service..."
    cat > "/etc/systemd/system/phantun-server-${TUN_ID}.service" <<EOF
[Unit]
Description=Phantun Server Tunnel ${TUN_ID}
After=network.target

[Service]
Type=simple
Environment=RUST_LOG=info
ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=${PHANTUN_BIN}/phantun_server --local ${TCP_PORT} --remote 127.0.0.1:${TCP_PORT} --tun ${TUN_NAME}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 4. Save iptables rules
    log_step "Saving iptables rules..."
    mkdir -p /etc/phantun
    cat > "/etc/phantun/iptables-server-${TUN_ID}.sh" <<EOF
#!/bin/bash
# Phantun Server DNAT rules - Tunnel ${TUN_ID}
iptables -t nat -D PREROUTING -p tcp -i ${IFACE} --dport ${TCP_PORT} -j DNAT --to-destination 192.168.201.2 2>/dev/null
iptables -t nat -A PREROUTING -p tcp -i ${IFACE} --dport ${TCP_PORT} -j DNAT --to-destination 192.168.201.2
EOF
    chmod +x "/etc/phantun/iptables-server-${TUN_ID}.sh"

    # 5. Enable and start
    systemctl daemon-reload
    systemctl enable "phantun-server-${TUN_ID}"
    systemctl restart "phantun-server-${TUN_ID}"

    sleep 2

    # 6. Check status
    if systemctl is-active --quiet "phantun-server-${TUN_ID}"; then
        log_info "Server is RUNNING"
    else
        log_err "Server failed to start. Check logs:"
        echo "  journalctl -u phantun-server-${TUN_ID} -n 20 --no-pager"
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Server setup complete!${NC}"
    echo -e "${GREEN}  Listen TCP Port: ${TCP_PORT}${NC}"
    echo -e "${GREEN}  Service: phantun-server-${TUN_ID}${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}  Now run this script on IRAN server${NC}"
    echo -e "${YELLOW}  and choose 'Client Mode'${NC}"
}

# ==========================================
# Setup IRAN (Client)
# ==========================================
setup_client() {
    log_step "=== IRAN Client Setup ==="

    read -p "Enter KHAREJ server IP: " REMOTE_IP
    if [ -z "$REMOTE_IP" ]; then
        log_err "Remote IP is required"
        return 1
    fi

    read -p "Enter TCP port (same as server) [4567]: " TCP_PORT
    TCP_PORT=${TCP_PORT:-4567}

    read -p "Enter Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    IFACE=$(get_main_interface)
    log_info "Main interface detected: ${IFACE}"
    read -p "Use this interface? (Y/n): " use_iface
    if [[ "$use_iface" =~ ^[Nn]$ ]]; then
        read -p "Enter interface name: " IFACE
    fi

    TUN_NAME="tun_ph${TUN_ID}"

    echo ""
    echo -e "${BLUE}========= Client Config =========${NC}"
    echo -e "  Remote IP   : ${REMOTE_IP}"
    echo -e "  TCP Port    : ${TCP_PORT}"
    echo -e "  TUN Name    : ${TUN_NAME}"
    echo -e "  Interface   : ${IFACE}"
    echo -e "  Phantun IP  : 192.168.200.2 (default)"
    echo -e "${BLUE}=================================${NC}"
    echo ""
    read -p "Press ENTER to apply..."

    # 1. Enable IP forwarding
    log_step "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 2. Setup iptables MASQUERADE for outgoing
    log_step "Adding iptables MASQUERADE rule..."
    iptables -t nat -D POSTROUTING -o "$IFACE" -s 192.168.200.0/24 -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o "$IFACE" -s 192.168.200.0/24 -j MASQUERADE

    # 3. Create systemd service
    log_step "Creating systemd service..."
    cat > "/etc/systemd/system/phantun-client-${TUN_ID}.service" <<EOF
[Unit]
Description=Phantun Client Tunnel ${TUN_ID}
After=network.target

[Service]
Type=simple
Environment=RUST_LOG=info
ExecStartPre=/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=${PHANTUN_BIN}/phantun_client --local 127.0.0.1:${TCP_PORT} --remote ${REMOTE_IP}:${TCP_PORT} --tun ${TUN_NAME}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 4. Save iptables rules
    log_step "Saving iptables rules..."
    mkdir -p /etc/phantun
    cat > "/etc/phantun/iptables-client-${TUN_ID}.sh" <<EOF
#!/bin/bash
# Phantun Client MASQUERADE rules - Tunnel ${TUN_ID}
iptables -t nat -D POSTROUTING -o ${IFACE} -s 192.168.200.0/24 -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -o ${IFACE} -s 192.168.200.0/24 -j MASQUERADE
EOF
    chmod +x "/etc/phantun/iptables-client-${TUN_ID}.sh"

    # 5. Enable and start
    systemctl daemon-reload
    systemctl enable "phantun-client-${TUN_ID}"
    systemctl restart "phantun-client-${TUN_ID}"

    sleep 2

    # 6. Check status
    if systemctl is-active --quiet "phantun-client-${TUN_ID}"; then
        log_info "Client is RUNNING"
    else
        log_err "Client failed to start. Check logs:"
        echo "  journalctl -u phantun-client-${TUN_ID} -n 20 --no-pager"
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Client setup complete!${NC}"
    echo -e "${GREEN}  Connecting to: ${REMOTE_IP}:${TCP_PORT}${NC}"
    echo -e "${GREEN}  Service: phantun-client-${TUN_ID}${NC}"
    echo -e "${GREEN}============================================${NC}"
}

# ==========================================
# Test Connectivity
# ==========================================
test_connection() {
    log_step "=== Connection Test ==="
    echo ""
    echo "This test checks if Phantun tunnel is working."
    echo "Run this on BOTH servers to check."
    echo ""

    echo -e "${BLUE}--- Active Phantun Services ---${NC}"
    systemctl list-units --type=service --state=running | grep phantun || echo "  No running Phantun services found"

    echo ""
    echo -e "${BLUE}--- TUN Interfaces ---${NC}"
    ip -br addr show | grep tun_ph || echo "  No Phantun TUN interfaces found"

    echo ""
    echo -e "${BLUE}--- Service Logs (last 10 lines) ---${NC}"
    read -p "Enter Tunnel ID to check [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    # Check both server and client service
    for TYPE in server client; do
        SVC="phantun-${TYPE}-${TUN_ID}"
        if systemctl is-active --quiet "$SVC" 2>/dev/null; then
            echo -e "\n${GREEN}[${TYPE}] Service is ACTIVE${NC}"
            journalctl -u "$SVC" -n 10 --no-pager 2>/dev/null
        fi
    done

    echo ""
    echo -e "${BLUE}--- iptables NAT Rules ---${NC}"
    iptables -t nat -L -n --line-numbers 2>/dev/null | grep -E "(DNAT|MASQUERADE|192.168.20)" || echo "  No Phantun-related NAT rules"

    echo ""
    echo -e "${YELLOW}--- Quick UDP Test ---${NC}"
    echo "To test end-to-end connectivity manually:"
    echo ""
    echo "  On KHAREJ (server), run:"
    echo -e "    ${CYAN}nc -u -l -p 4567${NC}"
    echo ""
    echo "  On IRAN (client), run:"
    echo -e "    ${CYAN}echo 'Hello Phantun' | nc -u 127.0.0.1 4567${NC}"
    echo ""
    echo "  If you see 'Hello Phantun' on KHAREJ, the tunnel works!"
}

# ==========================================
# Uninstall
# ==========================================
uninstall_tunnel() {
    log_step "=== Uninstall Phantun Tunnel ==="

    read -p "Enter Tunnel ID to remove: " TUN_ID
    if [ -z "$TUN_ID" ]; then return; fi

    echo "Stopping services..."
    systemctl stop "phantun-server-${TUN_ID}" 2>/dev/null
    systemctl stop "phantun-client-${TUN_ID}" 2>/dev/null
    systemctl disable "phantun-server-${TUN_ID}" 2>/dev/null
    systemctl disable "phantun-client-${TUN_ID}" 2>/dev/null

    echo "Removing service files..."
    rm -f "/etc/systemd/system/phantun-server-${TUN_ID}.service"
    rm -f "/etc/systemd/system/phantun-client-${TUN_ID}.service"

    echo "Removing iptables scripts..."
    rm -f "/etc/phantun/iptables-server-${TUN_ID}.sh"
    rm -f "/etc/phantun/iptables-client-${TUN_ID}.sh"

    systemctl daemon-reload

    # Clean up iptables rules (best effort)
    iptables -t nat -D PREROUTING -p tcp --dport "$((4500 + TUN_ID))" -j DNAT --to-destination 192.168.201.2 2>/dev/null
    iptables -t nat -D POSTROUTING -s 192.168.200.0/24 -j MASQUERADE 2>/dev/null

    log_info "Tunnel ${TUN_ID} removed."
}

# ==========================================
# Show Status
# ==========================================
show_status() {
    echo ""
    echo -e "${BLUE}========= Phantun Status =========${NC}"
    echo ""

    echo -e "${CYAN}Running Services:${NC}"
    systemctl list-units --type=service --state=running | grep phantun || echo "  None"

    echo ""
    echo -e "${CYAN}TUN Interfaces:${NC}"
    ip -br addr show | grep tun_ph || echo "  None"

    echo ""
    echo -e "${CYAN}NAT Rules:${NC}"
    iptables -t nat -L -n 2>/dev/null | grep -E "(DNAT|MASQUERADE)" | grep -E "(192.168.20|phantun)" || echo "  None"

    echo ""
}

# ==========================================
# Main Menu
# ==========================================
clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   Phantun Tunnel Manager v1.0${NC}"
echo -e "${GREEN}   UDP <-> Fake TCP Tunnel${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "1) Install Phantun Binary"
echo "2) Setup KHAREJ Server (Server Mode)"
echo "3) Setup IRAN Server (Client Mode)"
echo "4) Test Connection"
echo "5) Show Status"
echo "6) Uninstall Tunnel"
echo "0) Exit"
echo ""
read -p "Select option: " menu_opt

case $menu_opt in
    1) install_phantun ;;
    2) install_phantun && setup_server ;;
    3) install_phantun && setup_client ;;
    4) test_connection ;;
    5) show_status ;;
    6) uninstall_tunnel ;;
    *) exit 0 ;;
esac

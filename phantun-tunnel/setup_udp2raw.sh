#!/bin/bash

# ==========================================
#  udp2raw Tunnel Manager v1.0
#  Modes: ICMP / UDP (no FakeTCP)
#  Architecture: UDP App -> udp2raw (ICMP/UDP disguise) -> Server
#
#  Use with IPIP+FOU or WireGuard on top for private IPs
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

UDP2RAW_BIN="/usr/local/bin/udp2raw"
UDP2RAW_URL="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

log_info()  { echo -e "${GREEN}[OK]${NC} $1"; }
log_step()  { echo -e "${CYAN}>>>${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1"; }

# ==========================================
# Install udp2raw
# ==========================================
install_udp2raw() {
    if [ -f "$UDP2RAW_BIN" ]; then
        log_info "udp2raw already installed"
        "$UDP2RAW_BIN" --version 2>/dev/null | head -1
        read -p "Reinstall? (y/N): " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    log_step "Installing udp2raw..."
    apt-get update -qq
    apt-get install -y -qq curl tar > /dev/null 2>&1

    TMP_DIR=$(mktemp -d)
    log_step "Downloading..."
    curl -4L --connect-timeout 30 --max-time 120 -o "${TMP_DIR}/udp2raw.tar.gz" "$UDP2RAW_URL"

    FILE_SIZE=$(stat -c%s "${TMP_DIR}/udp2raw.tar.gz" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -lt 100000 ]; then
        log_err "Download failed (${FILE_SIZE} bytes)"
        log_info "Manual download: $UDP2RAW_URL"
        log_info "Place binary at: $UDP2RAW_BIN"
        rm -rf "$TMP_DIR"
        return 1
    fi

    log_step "Extracting..."
    tar xzf "${TMP_DIR}/udp2raw.tar.gz" -C "${TMP_DIR}/"

    # Find the right binary (x86_64)
    if [ -f "${TMP_DIR}/udp2raw_amd64" ]; then
        cp "${TMP_DIR}/udp2raw_amd64" "$UDP2RAW_BIN"
    elif [ -f "${TMP_DIR}/udp2raw" ]; then
        cp "${TMP_DIR}/udp2raw" "$UDP2RAW_BIN"
    else
        log_err "Binary not found. Contents:"
        ls -la "${TMP_DIR}/"
        rm -rf "$TMP_DIR"
        return 1
    fi

    chmod +x "$UDP2RAW_BIN"
    rm -rf "$TMP_DIR"

    if [ -f "$UDP2RAW_BIN" ]; then
        log_info "udp2raw installed!"
    else
        log_err "Installation failed"
        return 1
    fi
}

# ==========================================
# Select Mode
# ==========================================
select_mode() {
    echo ""
    echo "Select raw mode:"
    echo "  1) ICMP  (disguise as ping traffic)"
    echo "  2) UDP   (disguise as normal UDP)"
    echo ""
    read -p "Mode [1]: " mode_opt
    case $mode_opt in
        2) RAW_MODE="udp" ;;
        *) RAW_MODE="icmp" ;;
    esac
    log_info "Mode: ${RAW_MODE}"
}

# ==========================================
# Setup KHAREJ (Server)
# ==========================================
setup_server() {
    echo ""
    echo -e "${BLUE}=== KHAREJ Server (udp2raw) ===${NC}"
    echo ""

    install_udp2raw || return 1
    select_mode

    read -p "Enter Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "Enter listen port for udp2raw [4096]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-4096}

    read -p "Enter local UDP target port [5555]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-5555}

    read -p "Enter password [tunnel123]: " PASSWORD
    PASSWORD=${PASSWORD:-tunnel123}

    echo ""
    echo -e "${BLUE}========= Server Config =========${NC}"
    echo -e "  Mode       : ${RAW_MODE}"
    echo -e "  Listen     : 0.0.0.0:${LISTEN_PORT}"
    echo -e "  Forward to : 127.0.0.1:${TARGET_PORT}"
    echo -e "  Password   : ${PASSWORD}"
    echo -e "${BLUE}=================================${NC}"
    read -p "Press ENTER to apply..."

    # Create systemd service
    log_step "Creating service..."
    cat > "/etc/systemd/system/udp2raw-server-${TUN_ID}.service" <<EOF
[Unit]
Description=udp2raw Server ${TUN_ID} (${RAW_MODE})
After=network.target

[Service]
Type=simple
ExecStart=${UDP2RAW_BIN} -s -l 0.0.0.0:${LISTEN_PORT} -r 127.0.0.1:${TARGET_PORT} --raw-mode ${RAW_MODE} -a -k "${PASSWORD}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "udp2raw-server-${TUN_ID}"
    systemctl restart "udp2raw-server-${TUN_ID}"

    sleep 2

    if systemctl is-active --quiet "udp2raw-server-${TUN_ID}"; then
        log_info "Server RUNNING"
    else
        log_err "Failed to start. Logs:"
        journalctl -u "udp2raw-server-${TUN_ID}" -n 10 --no-pager
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  udp2raw Server ready!${NC}"
    echo -e "${GREEN}  Mode        : ${RAW_MODE}${NC}"
    echo -e "${GREEN}  Listen      : ${LISTEN_PORT}${NC}"
    echo -e "${GREEN}  Forward to  : 127.0.0.1:${TARGET_PORT}${NC}"
    echo -e "${GREEN}  Service     : udp2raw-server-${TUN_ID}${NC}"
    echo -e "${GREEN}============================================${NC}"
}

# ==========================================
# Setup IRAN (Client)
# ==========================================
setup_client() {
    echo ""
    echo -e "${BLUE}=== IRAN Client (udp2raw) ===${NC}"
    echo ""

    install_udp2raw || return 1
    select_mode

    read -p "Enter Tunnel ID [1]: " TUN_ID
    TUN_ID=${TUN_ID:-1}

    read -p "Enter KHAREJ server public IP: " REMOTE_IP
    if [ -z "$REMOTE_IP" ]; then
        log_err "Remote IP required"
        return 1
    fi

    read -p "Enter remote udp2raw port (same as server) [4096]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-4096}

    read -p "Enter local listen port [5555]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-5555}

    read -p "Enter password (same as server) [tunnel123]: " PASSWORD
    PASSWORD=${PASSWORD:-tunnel123}

    echo ""
    echo -e "${BLUE}========= Client Config =========${NC}"
    echo -e "  Mode       : ${RAW_MODE}"
    echo -e "  Remote     : ${REMOTE_IP}:${REMOTE_PORT}"
    echo -e "  Local      : 127.0.0.1:${LOCAL_PORT}"
    echo -e "  Password   : ${PASSWORD}"
    echo -e "${BLUE}=================================${NC}"
    read -p "Press ENTER to apply..."

    # Create systemd service
    log_step "Creating service..."
    cat > "/etc/systemd/system/udp2raw-client-${TUN_ID}.service" <<EOF
[Unit]
Description=udp2raw Client ${TUN_ID} (${RAW_MODE})
After=network.target

[Service]
Type=simple
ExecStart=${UDP2RAW_BIN} -c -l 127.0.0.1:${LOCAL_PORT} -r ${REMOTE_IP}:${REMOTE_PORT} --raw-mode ${RAW_MODE} -a -k "${PASSWORD}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "udp2raw-client-${TUN_ID}"
    systemctl restart "udp2raw-client-${TUN_ID}"

    sleep 2

    if systemctl is-active --quiet "udp2raw-client-${TUN_ID}"; then
        log_info "Client RUNNING"
    else
        log_err "Failed to start. Logs:"
        journalctl -u "udp2raw-client-${TUN_ID}" -n 10 --no-pager
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  udp2raw Client ready!${NC}"
    echo -e "${GREEN}  Mode       : ${RAW_MODE}${NC}"
    echo -e "${GREEN}  Remote     : ${REMOTE_IP}:${REMOTE_PORT}${NC}"
    echo -e "${GREEN}  Local      : 127.0.0.1:${LOCAL_PORT}${NC}"
    echo -e "${GREEN}  Service    : udp2raw-client-${TUN_ID}${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}  UDP tunnel ready on 127.0.0.1:${LOCAL_PORT}${NC}"
    echo -e "${YELLOW}  Test: echo test | nc -u 127.0.0.1 ${LOCAL_PORT}${NC}"
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

    echo -e "${CYAN}udp2raw services:${NC}"
    systemctl status "udp2raw-server-${TUN_ID}" --no-pager -l 2>/dev/null | head -5
    systemctl status "udp2raw-client-${TUN_ID}" --no-pager -l 2>/dev/null | head -5

    echo ""
    echo -e "${CYAN}udp2raw logs (last 10):${NC}"
    for TYPE in server client; do
        SVC="udp2raw-${TYPE}-${TUN_ID}"
        if systemctl is-active --quiet "$SVC" 2>/dev/null; then
            echo -e "\n${GREEN}[${TYPE}] ACTIVE${NC}"
            journalctl -u "$SVC" -n 10 --no-pager 2>/dev/null
        fi
    done

    echo ""
    echo -e "${YELLOW}To test the UDP tunnel:${NC}"
    echo "  Server: nc -u -l -p TARGET_PORT"
    echo "  Client: echo 'test' | nc -u -w2 127.0.0.1 LOCAL_PORT"
}

# ==========================================
# Remove Tunnels (keep binary)
# ==========================================
clean_tunnels() {
    echo ""
    echo -e "${YELLOW}=== REMOVE TUNNELS ===${NC}"
    echo ""
    echo "This removes: services + tunnels (keeps udp2raw binary)"
    read -p "Are you sure? (yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then return; fi

    for i in $(seq 1 10); do
        systemctl stop "udp2raw-server-${i}" 2>/dev/null
        systemctl stop "udp2raw-client-${i}" 2>/dev/null
        systemctl stop "ipip-u2r-${i}" 2>/dev/null
        systemctl disable "udp2raw-server-${i}" 2>/dev/null
        systemctl disable "udp2raw-client-${i}" 2>/dev/null
        systemctl disable "ipip-u2r-${i}" 2>/dev/null
        rm -f "/etc/systemd/system/udp2raw-server-${i}.service"
        rm -f "/etc/systemd/system/udp2raw-client-${i}.service"
        rm -f "/etc/systemd/system/ipip-u2r-${i}.service"
        ip link del "ipip_u2r${i}" 2>/dev/null
    done

    ip fou del port 5555 2>/dev/null
    ip fou del port 6000 2>/dev/null
    systemctl daemon-reload

    log_info "Tunnels removed (binary kept at ${UDP2RAW_BIN})"
}

# ==========================================
# Full Uninstall (remove everything + binary)
# ==========================================
full_uninstall() {
    echo ""
    echo -e "${RED}=== FULL UNINSTALL ===${NC}"
    echo ""
    echo "This removes EVERYTHING: tunnels + udp2raw binary"
    read -p "Are you sure? (yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then return; fi

    clean_tunnels
    rm -f "$UDP2RAW_BIN"

    log_info "Everything removed including binary!"
}

# ==========================================
# Menu
# ==========================================
clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  udp2raw Tunnel Manager v1.2${NC}"
echo -e "${GREEN}  ICMP / UDP Mode${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "1) Setup KHAREJ Server"
echo "2) Setup IRAN Client"
echo "3) Test Connection"
echo "4) Remove Tunnels (keep binary)"
echo "5) Full Uninstall (remove all)"
echo "0) Exit"
echo ""
read -p "Select: " opt

case $opt in
    1) setup_server ;;
    2) setup_client ;;
    3) test_tunnel ;;
    4) clean_tunnels ;;
    5) full_uninstall ;;
    *) exit 0 ;;
esac

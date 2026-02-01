#!/bin/bash

# ==========================================
# GRE over Phantun Manager (FOU + GRE)
# Architecture: IPv4 (GRE) > UDP (FOU) > TCP (Phantun)
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/gre-phantun-setup.log"
PHANTUN_BIN_DIR="/usr/local/bin"
PHANTUN_URL="https://github.com/dndx/phantun/releases/latest/download/phantun-x86_64-unknown-linux-musl"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ==========================================
# Prerequisite Installation
# ==========================================

install_prerequisites() {
    echo -e "${BLUE}--- Installing Prerequisites ---${NC}"
    
    # 1. Check tools
    if ! command -v curl &> /dev/null; then
        echo "Installing curl..."
        apt-get update && apt-get install -y curl
    fi

    # 2. Check Unzip
    if ! command -v unzip &> /dev/null; then
        echo "Installing unzip..."
        apt-get update && apt-get install -y unzip
    fi

    # 3. Install Phantun
    echo "Checking Phantun..."
    PHANTUN_URL="https://github.com/dndx/phantun/releases/download/v0.8.1/phantun_x86_64-unknown-linux-musl.zip"
    
    # Remove old garbage
    rm -f "$PHANTUN_BIN_DIR/phantun" "$PHANTUN_BIN_DIR/phantun.zip"

    echo "Downloading Phantun from GitHub..."
    curl -4L -o "$PHANTUN_BIN_DIR/phantun.zip" "$PHANTUN_URL"
    
    # Verify Download Size (Minimum 1MB)
    FILE_SIZE=$(stat -c%s "$PHANTUN_BIN_DIR/phantun.zip" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        echo -e "${RED}Error: Downloaded file is too small ($FILE_SIZE bytes). Check internet/URL.${NC}"
        rm -f "$PHANTUN_BIN_DIR/phantun.zip"
        return 1
    fi
    
    # Extract
    unzip -o "$PHANTUN_BIN_DIR/phantun.zip" -d "$PHANTUN_BIN_DIR/"
    
    # Locate Binary (It might be named phantun_server/client or just phantun)
    # Based on v0.8.1, it contains 'server' and 'client' binaries or similar. 
    # Let's find any executable that is not the zip
    if [ -f "$PHANTUN_BIN_DIR/server" ]; then
        mv "$PHANTUN_BIN_DIR/server" "$PHANTUN_BIN_DIR/phantun.server"
        mv "$PHANTUN_BIN_DIR/client" "$PHANTUN_BIN_DIR/phantun.client"
    elif [ -f "$PHANTUN_BIN_DIR/phantun_server" ]; then
        mv "$PHANTUN_BIN_DIR/phantun_server" "$PHANTUN_BIN_DIR/phantun.server"
        mv "$PHANTUN_BIN_DIR/phantun_client" "$PHANTUN_BIN_DIR/phantun.client"
    fi
    # If standard 'phantun' binary exists (older versions)
    if [ -f "$PHANTUN_BIN_DIR/phantun" ]; then
         ln -sf "$PHANTUN_BIN_DIR/phantun" "$PHANTUN_BIN_DIR/phantun.server"
         ln -sf "$PHANTUN_BIN_DIR/phantun" "$PHANTUN_BIN_DIR/phantun.client"
    fi

    chmod +x "$PHANTUN_BIN_DIR/phantun.server" "$PHANTUN_BIN_DIR/phantun.client"

    echo -e "${GREEN}Phantun installed successfully.${NC}"

    echo -e "${YELLOW}Enabling IP Forwarding...${NC}"
    # Validation
    if [ ! -f "$PHANTUN_BIN_DIR/phantun.server" ]; then
         echo -e "${RED}Error: Installation failed. Binaries not found.${NC}"
         return 1
    fi
}

check_binary() {
    if [ ! -f "$PHANTUN_BIN_DIR/phantun.server" ]; then
        echo -e "${YELLOW}Phantun binary not found. Installing...${NC}"
        install_prerequisites
    fi
    
    # Check again
    if [ ! -f "$PHANTUN_BIN_DIR/phantun.server" ]; then
         echo -e "${RED}Critical Error: Phantun installation failed.${NC}"
         exit 1
    fi
}

# ==========================================
# Tunnel Setup Logic
# ==========================================

setup_tunnel() {
    check_binary
    echo -e "${BLUE}--- Setup GRE + Phantun Tunnel ---${NC}"

    # 1. Role Selection
    echo "1) IRAN Server (Client Mode)"
    echo "2) KHAREJ Server (Server Mode)"
    read -p "Select Role: " role_opt
    if [ "$role_opt" == "1" ]; then
        ROLE="IRAN"
        PHANTUN_MODE="client"
    elif [ "$role_opt" == "2" ]; then
        ROLE="KHAREJ"
        PHANTUN_MODE="server"
    else
        echo "Invalid Role."
        return
    fi

    # 2. Config Inputs
    read -p "Enter Tunnel Assignment # (ID) [1-99]: " TUN_ID
    if [[ ! "$TUN_ID" =~ ^[0-9]+$ ]]; then TUN_ID=1; fi

    # Calculate Ports
    # Base: 4500 (TCP)
    TCP_PORT=$((4500 + TUN_ID))

    # IP Addressing (10.10.ID.x)
    TUN_IP_IRAN="10.10.${TUN_ID}.1"
    TUN_IP_KHAREJ="10.10.${TUN_ID}.2"
    TUN_NETMASK="255.255.255.252"

    TUN_NAME="ph_tun${TUN_ID}"

    if [ "$ROLE" == "IRAN" ]; then
        read -p "Enter Remote Server (Kharej) IP: " REMOTE_IP
        
        # Client Mode:
        # --remote: Target Server
        # --tun: Interface Name
        # --tun-local: My IP (Client IP)
        # --tun-peer: Peer IP (Server IP)
        PHANTUN_ARGS="--remote $REMOTE_IP:$TCP_PORT --tun $TUN_NAME --tun-local $TUN_IP_IRAN --tun-peer $TUN_IP_KHAREJ"
        
    else # KHAREJ
        # Server Mode:
        # --local: Listen Port (TCP)
        # --tun: Interface Name
        # --tun-local: My IP (Server IP)
        # --tun-peer: Peer IP (Client IP)
        # --remote: Required by binary but unused in pure TUN routing. Point to dummy.
        PHANTUN_ARGS="--local 0.0.0.0:$TCP_PORT --remote 127.0.0.1:12345 --tun $TUN_NAME --tun-local $TUN_IP_KHAREJ --tun-peer $TUN_IP_IRAN"
    fi

    echo -e "\n${BLUE}Plan for Tunnel $TUN_ID ($ROLE):${NC}"
    echo -e "   Interface  : $TUN_NAME"
    echo -e "   Local IP   : $(echo $PHANTUN_ARGS | grep -oP 'tun-local \K[^ ]+')"
    echo -e "   Remote IP  : $(echo $PHANTUN_ARGS | grep -oP 'tun-peer \K[^ ]+')"
    echo -e "   TCP Port   : $TCP_PORT"
    echo ""
    read -p "Press ENTER to install..."

    log "Configuring Tunnel $TUN_ID..."

    # 3. Create Systemd Service for Phantun (Native TUN Mode)
    cat > "/etc/systemd/system/phantun-${TUN_ID}.service" <<EOF
[Unit]
Description=Phantun Tunnel ${TUN_ID}
After=network.target

[Service]
Type=simple
ExecStart=$PHANTUN_BIN_DIR/phantun.${PHANTUN_MODE} $PHANTUN_ARGS
Restart=always
RestartSec=3
# Optimize buffers for high speed
ExecStartPre=/sbin/sysctl -w net.core.rmem_max=2500000
ExecStartPre=/sbin/sysctl -w net.core.wmem_max=2500000

[Install]
WantedBy=multi-user.target
EOF

    # 4. Remove Legacy GRE Service if exists
    systemctl disable "gre-net-${TUN_ID}" 2>/dev/null
    systemctl stop "gre-net-${TUN_ID}" 2>/dev/null
    rm -f "/etc/systemd/system/gre-net-${TUN_ID}.service"
    rm -f "/usr/local/bin/tun-up-${TUN_ID}.sh"

    # 5. Enable & Start
    systemctl daemon-reload
    systemctl enable "phantun-${TUN_ID}"
    systemctl restart "phantun-${TUN_ID}"

    echo -e "${GREEN}✅ Tunnel $TUN_ID Installed!${NC}"
    echo "Check status: systemctl status phantun-${TUN_ID}"
}

# ==========================================
# Uninstall Logic
# ==========================================

uninstall_tunnel() {
    read -p "Enter Tunnel ID to remove: " TUN_ID
    if [[ -z "$TUN_ID" ]]; then return; fi
    
    echo "Stopping services..."
    systemctl stop "gre-net-${TUN_ID}" "phantun-${TUN_ID}" 2>/dev/null
    systemctl disable "gre-net-${TUN_ID}" "phantun-${TUN_ID}" 2>/dev/null
    
    echo "Removing files..."
    rm -f "/etc/systemd/system/gre-net-${TUN_ID}.service"
    rm -f "/etc/systemd/system/phantun-${TUN_ID}.service"
    rm -f "/usr/local/bin/tun-up-${TUN_ID}.sh"
    
    systemctl daemon-reload
    
    # Cleanup runtime
    ip link del "gre_tun${TUN_ID}" 2>/dev/null
    # FOU cleanup requires knowing the port, trying best guess
    UDP_FOU_PORT=$((5500 + TUN_ID))
    ip fou del port $UDP_FOU_PORT 2>/dev/null
    
    echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
}

# ==========================================
# Main Menu
# ==========================================

clear
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}    GRE + Phantun Tunnel Setup v2.0 (TUN)   ${NC}"
echo -e "${GREEN}====================================${NC}"
echo "1) Install Prerequisites (Phantun)"
echo "2) Add New Tunnel connection"
echo "3) Uninstall Tunnel"
echo "4) Exit"
read -p "Select option: " menu_opt

case $menu_opt in
    1) install_prerequisites ;;
    2) setup_tunnel ;;
    3) uninstall_tunnel ;;
    *) exit 0 ;;
esac

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
    # Base: 4500 (TCP), 5500 (UDP FOU)
    TCP_PORT=$((4500 + TUN_ID))
    UDP_FOU_PORT=$((5500 + TUN_ID))

    # IP Addressing (10.10.ID.x)
    GRE_IP_IRAN="10.10.${TUN_ID}.1"
    GRE_IP_KHAREJ="10.10.${TUN_ID}.2"

    if [ "$ROLE" == "IRAN" ]; then
        read -p "Enter Remote Server (Kharej) IP: " REMOTE_IP
        
        PHANTUN_LOCAL="127.0.0.1:$UDP_FOU_PORT"
        PHANTUN_REMOTE="$REMOTE_IP:$TCP_PORT"
        
        MY_GRE_IP="$GRE_IP_IRAN"
        PEER_GRE_IP="$GRE_IP_KHAREJ"
        
        # In Phantun Client: Listen on UDP (Local), Forward to TCP (Remote)
        # But wait, we want the Phantun Client to listen on 127.0.0.1 UDP so FOU can send to it?
        # Phantun Client: --local <local_socket_addr> --remote <remote_socket_addr>
        # Local is where it LISTENS. Remote is where it SENDS.
        # Flow: Kernel (GRE) -> FOU (UDP) -> Phantun Client (UDP Listen) -> Internet (TCP) -> Kharej
        PHANTUN_ARGS="--local $PHANTUN_LOCAL --remote $PHANTUN_REMOTE"
        
    else # KHAREJ
        PHANTUN_LOCAL="0.0.0.0:$TCP_PORT"
        PHANTUN_REMOTE="127.0.0.1:$UDP_FOU_PORT"
        
        MY_GRE_IP="$GRE_IP_KHAREJ"
        PEER_GRE_IP="$GRE_IP_IRAN"
        
        # In Phantun Server: Listen on TCP (Local), Forward to UDP (Remote)
        # Flow: Internet (TCP) -> Phantun Server (TCP Listen) -> FOU (UDP) -> Kernel (GRE)
        # Note: Phantun Server needs to send TO the FOU port.
        PHANTUN_ARGS="--local $PHANTUN_LOCAL --remote $PHANTUN_REMOTE"
    fi

    echo -e "\n${BLUE}Plan for Tunnel $TUN_ID ($ROLE):${NC}"
    echo -e "   GRE IP      : $MY_GRE_IP <-> $PEER_GRE_IP"
    echo -e "   Phantun Listen : $PHANTUN_LOCAL"
    echo -e "   Phantun Target : $PHANTUN_REMOTE"
    echo -e "   FOU Port       : $UDP_FOU_PORT"
    echo -e "   TCP Port       : $TCP_PORT (Public)"
    echo ""
    read -p "Press ENTER to install..."

    log "Configuring Tunnel $TUN_ID..."

    # 3. Create Systemd Service for Phantun
    cat > "/etc/systemd/system/phantun-${TUN_ID}.service" <<EOF
[Unit]
Description=Phantun Tunnel ${TUN_ID}
After=network.target

[Service]
Type=simple
ExecStart=$PHANTUN_BIN_DIR/phantun.${PHANTUN_MODE} $PHANTUN_ARGS
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 4. Create Network Script (FOU + GRE)
    cat > "/usr/local/bin/tun-up-${TUN_ID}.sh" <<EOF
#!/bin/bash
# Load modules
modprobe ip_gre
modprobe fou

# Clean up
ip link del gre_tun${TUN_ID} 2>/dev/null
ip fou del port $UDP_FOU_PORT 2>/dev/null

# Setup FOU
# We tell kernel: UDP packets on $UDP_FOU_PORT are GRE (47)
ip fou add port $UDP_FOU_PORT ipproto 47

# Setup GRE
# We create a GRE interface that encapsulates into FOU (UDP)
# Remote 127.0.0.1 because Phantun handles the transport
# On Client (Iran): Kernel sends to 127.0.0.1:$UDP_FOU_PORT (Phantun listens there)
# On Server (Kharej): Phantun sends to 127.0.0.1:$UDP_FOU_PORT (Kernel listens there)

# Wait... for Client (Iran):
# Kernel -> FOU Encap -> UDP (Dest 127.0.0.1:$UDP_FOU_PORT) -> Phantun Client picks up
# For this to work, we need 'encap fou encap-dport $UDP_FOU_PORT'
# IMPORTANT: 'local' and 'remote' on GRE interface logic:
# When encap is used, 'remote' is the UNDERLYING destination. 
# Here, we want the underlying packet to go to 127.0.0.1 so Phantun can catch it.

ip link add name gre_tun${TUN_ID} type gre \\
    local 127.0.0.1 \\
    remote 127.0.0.1 \\
    ttl 255 \\
    encap fou \\
    encap-sport auto \\
    encap-dport $UDP_FOU_PORT

ip addr add $MY_GRE_IP/30 dev gre_tun${TUN_ID}
ip link set gre_tun${TUN_ID} up
ip link set gre_tun${TUN_ID} mtu 1400
EOF
    chmod +x "/usr/local/bin/tun-up-${TUN_ID}.sh"

    # 5. Create Systemd for Network
    cat > "/etc/systemd/system/gre-net-${TUN_ID}.service" <<EOF
[Unit]
Description=GRE Network Setup for Tunnel ${TUN_ID}
After=phantun-${TUN_ID}.service
Requires=phantun-${TUN_ID}.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tun-up-${TUN_ID}.sh
RemainAfterExit=yes
ExecStop=/sbin/ip link del gre_tun${TUN_ID}

[Install]
WantedBy=multi-user.target
EOF

    # 6. Enable & Start
    systemctl daemon-reload
    systemctl enable "phantun-${TUN_ID}" "gre-net-${TUN_ID}"
    systemctl restart "phantun-${TUN_ID}" "gre-net-${TUN_ID}"

    echo -e "${GREEN}✅ Tunnel $TUN_ID Installed!${NC}"
    echo "Check status: systemctl status gre-net-${TUN_ID}"
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
echo -e "${GREEN}    GRE + Phantun Tunnel Setup      ${NC}"
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

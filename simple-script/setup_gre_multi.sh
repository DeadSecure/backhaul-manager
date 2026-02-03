#!/bin/bash

# ==========================================
# Standard GRE Multi-Tunnel Manager
# Architecture: IPv4 > GRE (IPv4)
# Supports: Multiple Servers (Hub & Spoke)
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/gre-setup.log"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

get_public_ip() {
    local ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    echo "${ip:-Unknown}"
}

# ==========================================
# Core Functions
# ==========================================

enable_modules() {
    log "Enabling Kernel Modules..."
    modprobe ip_gre
    
    # Enable IP Forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-gre-forward.conf
    sysctl -p /etc/sysctl.d/99-gre-forward.conf >> "$LOG_FILE" 2>&1
}

setup_gre_tunnel() {
    local id=$1
    local local_public_ip=$2
    local remote_public_ip=$3
    
    # Addressing Scheme for Inner GRE (IPv4 payload):
    # 172.24.{ID}.1 (Iran) <-> 172.24.{ID}.2 (Kharej)
    
    local gre_if="gre${id}"
    local gre_ip_local="172.24.${id}.1"
    local gre_ip_remote="172.24.${id}.2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        local temp=$gre_ip_local
        gre_ip_local=$gre_ip_remote
        gre_ip_remote=$temp
    fi
    
    log "Setting up GRE Tunnel ($gre_if)..."
    log "   Public Local  : $local_public_ip"
    log "   Public Remote : $remote_public_ip"
    log "   Inner Local   : $gre_ip_local"
    log "   Inner Remote  : $gre_ip_remote"

    # 1. Create Script
    cat > "/usr/local/bin/gre-up-${id}.sh" <<EOF
#!/bin/bash
ip tunnel del $gre_if 2>/dev/null || true
ip tunnel add $gre_if mode gre remote $remote_public_ip local $local_public_ip ttl 255
ip link set $gre_if up
ip addr add $gre_ip_local/30 dev $gre_if
# MTU Calculation: 1500 (Eth) - 20 (IP) - 4 (GRE) = 1476.
ip link set $gre_if mtu 1476
EOF
    chmod +x "/usr/local/bin/gre-up-${id}.sh"

    # 2. Run it
    "/usr/local/bin/gre-up-${id}.sh" >> "$LOG_FILE" 2>&1
    
    # 3. Create Persistent Service
    cat > "/etc/systemd/system/gre-tunnel-${id}.service" <<EOF
[Unit]
Description=Standard GRE Tunnel ${id}
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gre-up-${id}.sh
RemainAfterExit=yes
ExecStop=/sbin/ip tunnel del $gre_if

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "gre-tunnel-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "gre-tunnel-${id}" >> "$LOG_FILE" 2>&1
}

setup_keepalive() {
    local id=$1
    # Check current role to determine target IP
    local target_ip="172.24.${id}.2" # Default target is Remote (Kharej)
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        target_ip="172.24.${id}.1" # If we are Kharej, target is Iran
    fi
    
    log "Setting up Keepalive for $target_ip..."
    
    cat > "/usr/local/bin/keepalive-gre-${id}.sh" <<EOF
#!/bin/bash
TARGET="$target_ip"
ID="$id"
while true; do
    # Try pinging 3 times, wait 2 seconds between
    if ! ping -c 3 -W 2 \$TARGET > /dev/null; then
        echo "\$(date): Connection lost to \$TARGET. Restarting tunnel \$ID..."
        systemctl restart gre-tunnel-\$ID
        sleep 5
    fi
    sleep 5
done
EOF
    chmod +x "/usr/local/bin/keepalive-gre-${id}.sh"
    
    cat > "/etc/systemd/system/keepalive-gre-${id}.service" <<EOF
[Unit]
Description=Keepalive for GRE Tunnel ${id}
After=gre-tunnel-${id}.service

[Service]
ExecStart=/usr/local/bin/keepalive-gre-${id}.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "keepalive-gre-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "keepalive-gre-${id}" >> "$LOG_FILE" 2>&1
}


# ==========================================
# UI Functions
# ==========================================

install_tunnel() {
    echo -e "${BLUE}--- Install New Standard GRE Tunnel ---${NC}"
    
    # Role Selection
    echo "1) IRAN Server (Hub)"
    echo "2) KHAREJ Server (Spoke)"
    read -p "Select Role: " role_opt
    if [ "$role_opt" == "1" ]; then
        SERVER_ROLE="IRAN"
    elif [ "$role_opt" == "2" ]; then
        SERVER_ROLE="KHAREJ"
    else
        echo "Invalid Role."
        return
    fi
    
    read -p "Enter Tunnel Assignment # (ID) [1-99]: " TUN_ID
    if [[ ! "$TUN_ID" =~ ^[0-9]+$ ]]; then TUN_ID=1; fi
    
    echo -e "\n${CYAN}--- Select Local Source IP ---${NC}"
    local available_ips=($(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1))
    local SELECTED_LOCAL_IP=${available_ips[0]}
    
    if [ ${#available_ips[@]} -gt 1 ]; then
        for i in "${!available_ips[@]}"; do
             echo "$((i+1))) ${available_ips[$i]}"
        done
        read -p "Select IP: " ip_opt
        if [[ "$ip_opt" =~ ^[0-9]+$ ]]; then
            SELECTED_LOCAL_IP=${available_ips[$((ip_opt-1))]}
        fi
    fi
    
    echo -e "\n${GREEN}YOUR IP: ${SELECTED_LOCAL_IP}${NC}"
    echo -e "${YELLOW}👉 Enter THIS IP ($SELECTED_LOCAL_IP) on the Remote Server.${NC}\n"
    
    read -p "Enter Public IP of Remote Server: " REMOTE_PUBLIC_IP
    
    # GRE IPv4 Logic
    local gre_local_v4="172.24.${TUN_ID}.1"
    local gre_remote_v4="172.24.${TUN_ID}.2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        local temp2=$gre_local_v4
        gre_local_v4=$gre_remote_v4
        gre_remote_v4=$temp2
    fi
    
    echo ""
    echo -e "${BLUE}Plan:${NC}"
    echo -e "   Role       : $SERVER_ROLE"
    echo -e "   ID         : ${GREEN}$TUN_ID${NC}"
    echo -e "   Public SRC : $SELECTED_LOCAL_IP"
    echo -e "   Public DST : $REMOTE_PUBLIC_IP"
    echo -e "   ----------------------------"
    echo -e "   GRE IPv4   : ${YELLOW}$gre_local_v4${NC} <---> ${YELLOW}$gre_remote_v4${NC}"
    echo ""
    read -p "Press ENTER to start installation..."
    
    echo -e "\n${YELLOW}Configuring Tunnel $TUN_ID...${NC}"
    enable_modules
    setup_gre_tunnel "$TUN_ID" "$SELECTED_LOCAL_IP" "$REMOTE_PUBLIC_IP"
    setup_keepalive "$TUN_ID"
    
    echo -e "${GREEN}✅ Tunnel $TUN_ID Setup Complete!${NC}"
    echo -e "   Inner IP: $(ip addr show gre${TUN_ID} | grep inet | awk '{print $2}')"
}

uninstall_tunnel() {
    read -p "Enter Tunnel ID to uninstall: " TUN_ID
    if [[ -n "$TUN_ID" ]]; then
        systemctl stop "keepalive-gre-${TUN_ID}" "gre-tunnel-${TUN_ID}" 2>/dev/null
        systemctl disable "keepalive-gre-${TUN_ID}" "gre-tunnel-${TUN_ID}" 2>/dev/null
        rm -f "/etc/systemd/system/keepalive-gre-${TUN_ID}.service" "/etc/systemd/system/gre-tunnel-${TUN_ID}.service"
        rm -f "/usr/local/bin/gre-up-${TUN_ID}.sh" "/usr/local/bin/keepalive-gre-${TUN_ID}.sh"
        systemctl daemon-reload
        ip tunnel del "gre${TUN_ID}" 2>/dev/null
        echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
    fi
}

# Main Menu
clear
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}   Standard GRE Multi-Tunnel Manager${NC}"
echo -e "${GREEN}====================================${NC}"
echo "1) Install Tunnel"
echo "2) Uninstall Tunnel"
echo "3) Exit"
read -p "Select: " opt

case $opt in
    1) install_tunnel ;;
    2) uninstall_tunnel ;;
    *) exit 0 ;;
esac

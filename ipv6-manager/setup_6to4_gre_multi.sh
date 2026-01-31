#!/bin/bash

# ==========================================
# 6to4 + GRE6 Multi-Tunnel Manager
# Architecture: IPv4 > SIT (IPv6) > GRE6 (IPv4)
# Supports: Multiple Servers (Hub & Spoke)
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/6to4-gre-setup.log"

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
    modprobe sit
    modprobe ip_gre
    modprobe ip6_gre
    modprobe ipv6
    
    # Enable IPv6 Forwarding
    echo "net.ipv6.conf.all.forwarding=1" > /etc/sysctl.d/99-ipv6-forward.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-ipv6-forward.conf
    sysctl -p /etc/sysctl.d/99-ipv6-forward.conf >> "$LOG_FILE" 2>&1
}

setup_sit_tunnel() {
    local id=$1
    local local_ip=$2
    local remote_ip=$3
    
    # Addressing Scheme for SIT Layer:
    # We use valid ULA addresses to avoid conflict
    # Iran: fd00:100:{ID}::1
    # Kharej: fd00:100:{ID}::2
    
    local sit_if="sit${id}"
    local ipv6_local="fd00:100:${id}::1"
    local ipv6_remote="fd00:100:${id}::2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        # Swap for remote side
        local temp=$ipv6_local
        ipv6_local=$ipv6_remote
        ipv6_remote=$temp
    fi

    log "Setting up SIT Tunnel ($sit_if)..."
    log "   SIT Local  : $local_ip"
    log "   SIT Remote : $remote_ip"
    log "   IPv6 Local : $ipv6_local"
    
    # 1. Create Script
    cat > "/usr/local/bin/sit-up-${id}.sh" <<EOF
#!/bin/bash
ip tunnel del $sit_if 2>/dev/null || true
ip tunnel add $sit_if mode sit remote $remote_ip local $local_ip ttl 255
ip link set $sit_if up
ip -6 addr add $ipv6_local/64 dev $sit_if
ip link set $sit_if mtu 1480
EOF
    chmod +x "/usr/local/bin/sit-up-${id}.sh"
    
    # 2. Run it
    "/usr/local/bin/sit-up-${id}.sh" >> "$LOG_FILE" 2>&1
}

setup_gre6_tunnel() {
    local id=$1
    # For GRE6, we use the IPv6 addresses established by SIT as endpoints
    
    local ipv6_local="fd00:100:${id}::1"
    local ipv6_remote="fd00:100:${id}::2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        local temp=$ipv6_local
        ipv6_local=$ipv6_remote
        ipv6_remote=$temp
    fi
    
    # Addressing Scheme for Inner GRE (IPv4 payload):
    # 172.20.{ID}.1 (Iran) <-> 172.20.{ID}.2 (Kharej)
    local gre_if="gre6_${id}"
    local gre_ip_local="172.20.${id}.1"
    local gre_ip_remote="172.20.${id}.2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        local temp=$gre_ip_local
        gre_ip_local=$gre_ip_remote
        gre_ip_remote=$temp
    fi
    
    log "Setting up GRE6 Tunnel ($gre_if)..."
    log "   GRE6 Local IPv6  : $ipv6_local"
    log "   GRE6 Remote IPv6 : $ipv6_remote"
    log "   Inner IPv4       : $gre_ip_local"

    # 1. Create Script
    cat > "/usr/local/bin/gre6-up-${id}.sh" <<EOF
#!/bin/bash
ip -6 tunnel del $gre_if 2>/dev/null || true
# Ensure SIT is up first by dependencies
ip -6 tunnel add $gre_if mode ip6gre remote $ipv6_remote local $ipv6_local ttl 255
ip link set $gre_if up
ip addr add $gre_ip_local/30 dev $gre_if
# MTU Calculation: 1480 (SIT) - 4 (GRE) - 40 (IPv6) = 1436. Let's use 1400 for safety.
ip link set $gre_if mtu 1400
EOF
    chmod +x "/usr/local/bin/gre6-up-${id}.sh"

    # 2. Run it
    "/usr/local/bin/gre6-up-${id}.sh" >> "$LOG_FILE" 2>&1
    
    # 3. Create Persistent Service (Combines SIT + GRE6 logic)
    cat > "/etc/systemd/system/tunnel6-${id}.service" <<EOF
[Unit]
Description=6to4 + GRE6 Tunnel ${id}
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/usr/local/bin/sit-up-${id}.sh && /usr/local/bin/gre6-up-${id}.sh'
RemainAfterExit=yes
ExecStop=/sbin/ip -6 tunnel del gre6_${id} ; /sbin/ip tunnel del sit${id}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "tunnel6-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "tunnel6-${id}" >> "$LOG_FILE" 2>&1
}

setup_keepalive() {
    local id=$1
    local target_ip="172.20.${id}.2" # Default to Remote
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        target_ip="172.20.${id}.1"
    fi
    
    log "Setting up Keepalive for $target_ip..."
    
    cat > "/usr/local/bin/keepalive6-${id}.sh" <<EOF
#!/bin/bash
TARGET="$target_ip"
ID="$id"
while true; do
    if ! ping -c 3 -W 2 \$TARGET > /dev/null; then
        echo "\$(date): Connection lost. Restarting tunnel \$ID..."
        systemctl restart tunnel6-\$ID
        sleep 5
    fi
    sleep 5
done
EOF
    chmod +x "/usr/local/bin/keepalive6-${id}.sh"
    
    cat > "/etc/systemd/system/keepalive6-${id}.service" <<EOF
[Unit]
Description=Keepalive for Tunnel6 ${id}
After=tunnel6-${id}.service

[Service]
ExecStart=/usr/local/bin/keepalive6-${id}.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "keepalive6-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "keepalive6-${id}" >> "$LOG_FILE" 2>&1
}


# ==========================================
# UI Functions
# ==========================================

install_tunnel() {
    echo -e "${BLUE}--- Install New Tunnel (6to4 + GRE6) ---${NC}"
    
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
    
    # --- IP Calculation ---
    # SIT IPv6
    local sit_local_v6="fd00:100:${TUN_ID}::1"
    local sit_remote_v6="fd00:100:${TUN_ID}::2"
    
    # GRE6 IPv4
    local gre_local_v4="172.20.${TUN_ID}.1"
    local gre_remote_v4="172.20.${TUN_ID}.2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        # Swap for Kharej
        local temp=$sit_local_v6
        sit_local_v6=$sit_remote_v6
        sit_remote_v6=$temp
        
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
    echo -e "   SIT Tunnel : $sit_local_v6 <---> $sit_remote_v6"
    echo -e "   GRE IPv4   : ${YELLOW}$gre_local_v4${NC} <---> ${YELLOW}$gre_remote_v4${NC}"
    echo ""
    read -p "Press ENTER to start installation..."
    
    echo -e "\n${YELLOW}Configuring Tunnel $TUN_ID...${NC}"
    enable_modules
    setup_sit_tunnel "$TUN_ID" "$SELECTED_LOCAL_IP" "$REMOTE_PUBLIC_IP"
    setup_gre6_tunnel "$TUN_ID"
    setup_keepalive "$TUN_ID"
    
    echo -e "${GREEN}✅ Tunnel $TUN_ID Setup Complete!${NC}"
    echo -e "   Inner IP: $(ip addr show gre6_${TUN_ID} | grep inet | awk '{print $2}')"
}

uninstall_tunnel() {
    read -p "Enter Tunnel ID to uninstall: " TUN_ID
    if [[ -n "$TUN_ID" ]]; then
        systemctl stop "keepalive6-${TUN_ID}" "tunnel6-${TUN_ID}" 2>/dev/null
        systemctl disable "keepalive6-${TUN_ID}" "tunnel6-${TUN_ID}" 2>/dev/null
        rm -f "/etc/systemd/system/keepalive6-${TUN_ID}.service" "/etc/systemd/system/tunnel6-${TUN_ID}.service"
        rm -f "/usr/local/bin/sit-up-${TUN_ID}.sh" "/usr/local/bin/gre6-up-${TUN_ID}.sh" "/usr/local/bin/keepalive6-${TUN_ID}.sh"
        systemctl daemon-reload
        ip link delete "sit${TUN_ID}" 2>/dev/null
        ip -6 tunnel del "gre6_${TUN_ID}" 2>/dev/null
        echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
    fi
}

# Main Menu
clear
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}   6to4 + GRE6 Tunnel Manager       ${NC}"
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

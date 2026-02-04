#!/bin/bash

# ==========================================
# L2TPv3 Multi-Tunnel Manager (Static/Unmanaged)
# Protocol: Ethernet over L2TPv3 (UDP Encapsulation)
# Supports: Multiple Servers (Hub & Spoke), Batch Install
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/l2tpv3-setup.log"

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
    modprobe l2tp_core
    modprobe l2tp_netlink
    modprobe l2tp_eth
    
    # Enable IPv4 Forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
    sysctl -p /etc/sysctl.d/99-ip-forward.conf >> "$LOG_FILE" 2>&1
}

setup_l2tp_tunnel() {
    local id=$1
    local local_public_ip=$2
    local remote_public_ip=$3
    
    # Architecture:
    # Tunnel ID: $id
    # Session ID: $id
    # UDP Port: 5000 + $id
    
    local port=$((5000 + id))
    local if_name="l2tpeth${id}"
    
    # Inner IP Addressing Scheme: 10.10.{ID}.1/30
    local inner_local="10.10.${id}.1"
    local inner_remote="10.10.${id}.2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        local temp=$inner_local
        inner_local=$inner_remote
        inner_remote=$temp
    fi
    
    log "Setting up L2TPv3 Tunnel ($if_name)..."
    log "   Local Public  : $local_public_ip : $port"
    log "   Remote Public : $remote_public_ip : $port"
    log "   Inner Local   : $inner_local/30"
    
    # 1. Create Script
    local script_path="/usr/local/bin/l2tp-up-${id}.sh"
    cat > "$script_path" <<EOF
#!/bin/bash
# Clean up existing
ip link set $if_name down 2>/dev/null
ip l2tp del session tunnel_id $id session_id $id 2>/dev/null
ip l2tp del tunnel tunnel_id $id 2>/dev/null

# Create L2TPv3 Tunnel (UDP Encap)
# Note: udp_sport/udp_dport must match on both ends (or be crossed if asymmetric, but we use symmetric here)
ip l2tp add tunnel tunnel_id $id peer_tunnel_id $id encap udp local $local_public_ip remote $remote_public_ip udp_sport $port udp_dport $port

# Create Session (Ethernet Pseudowire)
ip l2tp add session name $if_name tunnel_id $id session_id $id peer_session_id $id

# Bring up interface
ip link set $if_name up
ip link set $if_name mtu 1460 
ip addr add $inner_local/30 dev $if_name
EOF
    chmod +x "$script_path"
    
    # 2. Run it
    "$script_path" >> "$LOG_FILE" 2>&1
    
    # 3. Persistent Service
    local service_path="/etc/systemd/system/tunnel-l2tp-${id}.service"
    cat > "$service_path" <<EOF
[Unit]
Description=L2TPv3 Tunnel ${id}
After=network.target

[Service]
Type=oneshot
ExecStart=$script_path
RemainAfterExit=yes
ExecStop=/sbin/ip l2tp del session tunnel_id $id session_id $id ; /sbin/ip l2tp del tunnel tunnel_id $id

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "tunnel-l2tp-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "tunnel-l2tp-${id}" >> "$LOG_FILE" 2>&1
}

setup_keepalive() {
    local id=$1
    local target_ip="10.10.${id}.2"
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        target_ip="10.10.${id}.1"
    fi
    
    log "Setting up Keepalive for $target_ip..."
    
    local ka_script="/usr/local/bin/keepalive-l2tp-${id}.sh"
    cat > "$ka_script" <<EOF
#!/bin/bash
TARGET="$target_ip"
SERVICE="tunnel-l2tp-${id}"
while true; do
    if ! ping -c 3 -W 2 \$TARGET > /dev/null; then
        echo "\$(date): Connection lost to \$TARGET. Restarting \$SERVICE..."
        systemctl restart \$SERVICE
        sleep 5
    fi
    sleep 10
done
EOF
    chmod +x "$ka_script"
    
    local ka_service="/etc/systemd/system/keepalive-l2tp-${id}.service"
    cat > "$ka_service" <<EOF
[Unit]
Description=Keepalive for L2TPv3 Tunnel ${id}
After=tunnel-l2tp-${id}.service

[Service]
ExecStart=$ka_script
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "keepalive-l2tp-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "keepalive-l2tp-${id}" >> "$LOG_FILE" 2>&1
}

# ==========================================
# UI Functions
# ==========================================

install_tunnel() {
    echo -e "${BLUE}--- Install New L2TPv3 Tunnel (UDP) ---${NC}"
    
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
    
    read -p "Enter Tunnel Number (ID) [1-250]: " TUN_ID
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
    
    # Calculate Port
    local port=$((5000 + TUN_ID))
    
    echo ""
    echo -e "${BLUE}Plan:${NC}"
    echo -e "   Role       : $SERVER_ROLE"
    echo -e "   Tunnel ID  : $TUN_ID"
    echo -e "   Local  IP  : $SELECTED_LOCAL_IP"
    echo -e "   Remote IP  : $REMOTE_PUBLIC_IP"
    echo -e "   UDP Port   : $port"
    echo ""
    read -p "Press ENTER to start installation..."
    
    enable_modules
    setup_l2tp_tunnel "$TUN_ID" "$SELECTED_LOCAL_IP" "$REMOTE_PUBLIC_IP"
    setup_keepalive "$TUN_ID"
    
    echo -e "${GREEN}✅ L2TPv3 Tunnel $TUN_ID Setup Complete!${NC}"
    echo -e "   Interface : l2tpeth${TUN_ID}"
}

batch_install() {
    echo -e "${BLUE}--- Batch Install L2TPv3 Tunnels ---${NC}"

    echo "1) IRAN Server (Hub)"
    echo "2) KHAREJ Server (Spoke)"
    read -p "Select Role: " role_opt
    if [ "$role_opt" == "1" ]; then
        SERVER_ROLE="IRAN"
    elif [ "$role_opt" == "2" ]; then
        SERVER_ROLE="KHAREJ"
    else
        echo "Check"
        return
    fi

    read -p "Enter Starting Tunnel ID [1-250]: " START_TUN_ID
    if [[ ! "$START_TUN_ID" =~ ^[0-9]+$ ]]; then START_TUN_ID=1; fi

    echo -e "\n${CYAN}--- Local Source IPs ---${NC}"
    local available_ips=($(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1))
    
    if [ ${#available_ips[@]} -eq 0 ]; then
        echo "${RED}No public IPs found!${NC}"
        AVAILABLE_LOCAL_IPS=($(get_public_ip))
    else
        echo "Available Local IPs:"
        for i in "${!available_ips[@]}"; do
             echo "$((i+1))) ${available_ips[$i]}"
        done
        echo "A) All IPs (in order)"
        echo "C) Custom Selection"
        
        read -p "Select Local IPs option: " loc_opt
        
        SELECTED_LOCAL_IPS=()
        if [[ "$loc_opt" =~ ^[aA]$ ]]; then
            SELECTED_LOCAL_IPS=("${available_ips[@]}")
        elif [[ "$loc_opt" =~ ^[cC]$ ]]; then
            read -p "Enter IP numbers to use (e.g. '1 2'): " ip_nums
            for num in $ip_nums; do
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    SELECTED_LOCAL_IPS+=("${available_ips[$((num-1))]}")
                fi
            done
        else
             SELECTED_LOCAL_IPS=($(get_public_ip))
        fi
    fi
    echo -e "Selected Local IPs: ${GREEN}${SELECTED_LOCAL_IPS[*]}${NC}"

    echo -e "\n${CYAN}--- Remote Server IPs ---${NC}"
    read -p "Enter Remote Server Public IPs (space separated): " -a REMOTE_IPS_INPUT
    
    if [ ${#REMOTE_IPS_INPUT[@]} -eq 0 ]; then
        echo "${RED}No Remote IPs entered!${NC}"
        return
    fi

    # Matching IPs
    local count_local=${#SELECTED_LOCAL_IPS[@]}
    local count_remote=${#REMOTE_IPS_INPUT[@]}
    local loop_count=0
    
    if [ $count_local -gt $count_remote ]; then loop_count=$count_local; else loop_count=$count_remote; fi

    echo -e "\n${YELLOW}Preparing to install $loop_count tunnels...${NC}"
    echo "Press ENTER to start..."
    read

    enable_modules

    for (( i=0; i<loop_count; i++ )); do
        CURRENT_ID=$((START_TUN_ID + i))
        local_idx=$((i % count_local))
        CURRENT_LOCAL_IP=${SELECTED_LOCAL_IPS[$local_idx]}
        remote_idx=$((i % count_remote))
        CURRENT_REMOTE_IP=${REMOTE_IPS_INPUT[$remote_idx]}
        
        echo -e "\n${BLUE}Configuring Tunnel #$CURRENT_ID${NC}"
        setup_l2tp_tunnel "$CURRENT_ID" "$CURRENT_LOCAL_IP" "$CURRENT_REMOTE_IP"
        setup_keepalive "$CURRENT_ID"
        
        echo -e "${GREEN}✅ Tunnel $CURRENT_ID Installed!${NC}"
    done
    
    echo -e "\n${GREEN}All batch operations completed.${NC}"
    read -p "Press Enter to return..."
}

uninstall_menu() {
    echo "1) Uninstall Specific Tunnel ID"
    echo "2) Nuke ALL L2TPv3 Tunnels"
    read -p "Select: " u_opt
    
    if [ "$u_opt" == "2" ]; then
        echo -e "${RED}WARNING: This will delete ALL 'l2tpeth' interfaces.${NC}"
        read -p "Are you sure? [y/N]: " confirm
        if [[ "$confirm" != "y" ]]; then return; fi
        
        log "Nuking all L2TP tunnels..."
        systemctl stop "tunnel-l2tp-*" 2>/dev/null
        systemctl disable "tunnel-l2tp-*" 2>/dev/null
        systemctl stop "keepalive-l2tp-*" 2>/dev/null
        systemctl disable "keepalive-l2tp-*" 2>/dev/null
        
        rm -f /etc/systemd/system/tunnel-l2tp-*.service
        rm -f /etc/systemd/system/keepalive-l2tp-*.service
        rm -f /usr/local/bin/l2tp-up-*.sh
        rm -f /usr/local/bin/keepalive-l2tp-*.sh
        
        # Cleanup Kernel Sessions
        for i in {1..250}; do
             ip l2tp del session tunnel_id $i session_id $i 2>/dev/null
             ip l2tp del tunnel tunnel_id $i 2>/dev/null
        done
        
        systemctl daemon-reload
        echo -e "${GREEN}All L2TPv3 Tunnels Removed.${NC}"
        return
    fi
    
    read -p "Enter Tunnel ID to uninstall: " TUN_ID
    if [[ -n "$TUN_ID" ]]; then
        systemctl stop "keepalive-l2tp-${TUN_ID}" "tunnel-l2tp-${TUN_ID}"
        systemctl disable "keepalive-l2tp-${TUN_ID}" "tunnel-l2tp-${TUN_ID}"
        rm -f "/etc/systemd/system/keepalive-l2tp-${TUN_ID}.service" "/etc/systemd/system/tunnel-l2tp-${TUN_ID}.service"
        rm -f "/usr/local/bin/l2tp-up-${TUN_ID}.sh" "/usr/local/bin/keepalive-l2tp-${TUN_ID}.sh"
        systemctl daemon-reload
        
        ip l2tp del session tunnel_id $TUN_ID session_id $TUN_ID 2>/dev/null
        ip l2tp del tunnel tunnel_id $TUN_ID 2>/dev/null
        
        echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
    fi
}

# Main Menu
clear
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}   L2TPv3 Multi-Tunnel (UDP)        ${NC}"
echo -e "${GREEN}====================================${NC}"
echo "1) Single Install"
echo "2) Batch Install"
echo "3) Uninstall Menu"
echo "4) Exit"
read -p "Select: " opt

case $opt in
    1) install_tunnel ;;
    2) batch_install ;;
    3) uninstall_menu ;;
    *) exit 0 ;;
esac

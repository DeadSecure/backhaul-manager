#!/bin/bash

# ==========================================
# GREtap Multi-Tunnel Manager (L2 over IPv4)
# Architecture: IPv4 > GREtap (Ethernet/L2) > IPv4 (Inside)
# Supports: Multiple Servers (Hub & Spoke) with 10.10.x.x addressing
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/gretap-setup.log"

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
    modprobe gre
    
    # Enable IPv4 Forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
    sysctl -p /etc/sysctl.d/99-ip-forward.conf >> "$LOG_FILE" 2>&1
}

setup_gretap_tunnel() {
    local id=$1
    local local_public_ip=$2
    local remote_public_ip=$3
    
    # Naming: gt4_{ID} (GREtap v4)
    local if_name="gt4_${id}"
    
    # Inner IP Addressing Scheme: 10.10.{ID}.x/30
    local inner_local="10.10.${id}.1"
    local inner_remote="10.10.${id}.2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        local temp=$inner_local
        inner_local=$inner_remote
        inner_remote=$temp
    fi
    
    log "Setting up GREtap Tunnel ($if_name)..."
    log "   Local Public  : $local_public_ip"
    log "   Remote Public : $remote_public_ip"
    log "   Inner Local   : $inner_local/30"
    
    # 1. Create Script
    local script_path="/usr/local/bin/gretap-up-${id}.sh"
    cat > "$script_path" <<EOF
#!/bin/bash
# Clean up existing if needed
ip link set $if_name down 2>/dev/null
ip link del $if_name 2>/dev/null || true

# Create GREtap interface
ip link add dev $if_name type gretap local $local_public_ip remote $remote_public_ip ttl 255

# Set MTU (Safe value for GRE overhead)
ip link set $if_name mtu 1450

# Bring up and assign IP
ip link set $if_name up
ip addr add $inner_local/30 dev $if_name
EOF
    chmod +x "$script_path"
    
    # 2. Run it immediately
    "$script_path" >> "$LOG_FILE" 2>&1
    
    # 3. Create Persistent Service
    local service_path="/etc/systemd/system/tunnel-tap-${id}.service"
    cat > "$service_path" <<EOF
[Unit]
Description=GREtap Tunnel ${id}
After=network.target

[Service]
Type=oneshot
ExecStart=$script_path
RemainAfterExit=yes
ExecStop=/sbin/ip link set $if_name down ; /sbin/ip link del $if_name

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "tunnel-tap-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "tunnel-tap-${id}" >> "$LOG_FILE" 2>&1
}

setup_keepalive() {
    local id=$1
    # Determine target IP to ping
    local target_ip="10.10.${id}.2" # Default target is Kharej (Remote for Hub)
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        target_ip="10.10.${id}.1" # Target is Iran (Remote for Spoke)
    fi
    
    log "Setting up Keepalive for $target_ip..."
    
    local ka_script="/usr/local/bin/keepalive-tap-${id}.sh"
    cat > "$ka_script" <<EOF
#!/bin/bash
TARGET="$target_ip"
SERVICE="tunnel-tap-${id}"
while true; do
    # Try pinging 3 times
    if ! ping -c 3 -W 2 \$TARGET > /dev/null; then
        echo "\$(date): Connection lost to \$TARGET. Restarting \$SERVICE..."
        systemctl restart \$SERVICE
        sleep 5
    fi
    sleep 10
done
EOF
    chmod +x "$ka_script"
    
    local ka_service="/etc/systemd/system/keepalive-tap-${id}.service"
    cat > "$ka_service" <<EOF
[Unit]
Description=Keepalive for GREtap Tunnel ${id}
After=tunnel-tap-${id}.service

[Service]
ExecStart=$ka_script
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "keepalive-tap-${id}" >> "$LOG_FILE" 2>&1
    systemctl start "keepalive-tap-${id}" >> "$LOG_FILE" 2>&1
}

# ==========================================
# UI Functions
# ==========================================

install_tunnel() {
    echo -e "${BLUE}--- Install New GREtap Tunnel (10.10.x.x) ---${NC}"
    
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
    
    # Calculate Plan
    local inner_local="10.10.${TUN_ID}.1"
    local inner_remote="10.10.${TUN_ID}.2"
    
    if [ "$SERVER_ROLE" == "KHAREJ" ]; then
        local temp=$inner_local
        inner_local=$inner_remote
        inner_remote=$temp
    fi
    
    echo ""
    echo -e "${BLUE}Plan:${NC}"
    echo -e "   Role       : $SERVER_ROLE"
    echo -e "   Tunnel ID  : ${GREEN}$TUN_ID${NC}"
    echo -e "   Local  IP  : $SELECTED_LOCAL_IP"
    echo -e "   Remote IP  : $REMOTE_PUBLIC_IP"
    echo -e "   Inner IP   : ${YELLOW}$inner_local${NC} <---> ${YELLOW}$inner_remote${NC}"
    echo ""
    read -p "Press ENTER to start installation..."
    
    echo -e "\n${YELLOW}Configuring Tunnel $TUN_ID...${NC}"
    enable_modules
    setup_gretap_tunnel "$TUN_ID" "$SELECTED_LOCAL_IP" "$REMOTE_PUBLIC_IP"
    setup_keepalive "$TUN_ID"
    
    echo -e "${GREEN}✅ GREtap Tunnel $TUN_ID Setup Complete!${NC}"
    echo -e "   Interface : gt4_${TUN_ID}"
    echo -e "   IP        : $(ip addr show gt4_${TUN_ID} 2>/dev/null | grep inet | awk '{print $2}')"
}

uninstall_menu() {
    echo "1) Uninstall Specific Tunnel ID"
    echo "2) Nuke ALL GREtap Tunnels"
    read -p "Select: " u_opt
    
    if [ "$u_opt" == "2" ]; then
        echo -e "${RED}WARNING: This will delete ALL 'gt4_*' interfaces and related services.${NC}"
        read -p "Are you sure? [y/N]: " confirm
        if [[ "$confirm" != "y" ]]; then return; fi
        
        log "Nuking all GREtap tunnels..."
        
        # Stop & Disable Services
        systemctl stop "tunnel-tap-*" 2>/dev/null
        systemctl disable "tunnel-tap-*" 2>/dev/null
        systemctl stop "keepalive-tap-*" 2>/dev/null
        systemctl disable "keepalive-tap-*" 2>/dev/null
        
        # Remove Files
        rm -f /etc/systemd/system/tunnel-tap-*.service
        rm -f /etc/systemd/system/keepalive-tap-*.service
        rm -f /usr/local/bin/gretap-up-*.sh
        rm -f /usr/local/bin/keepalive-tap-*.sh
        
        # Delete Interfaces
        for dev in $(ip link show | grep -o 'gt4_[0-9]\+'); do
            echo "Deleting $dev..."
            ip link set "$dev" down 2>/dev/null
            ip link del "$dev" 2>/dev/null
        done
        
        systemctl daemon-reload
        echo -e "${GREEN}All GREtap Tunnels Removed.${NC}"
        return
    fi
    
    read -p "Enter Tunnel ID to uninstall: " TUN_ID
    if [[ -n "$TUN_ID" ]]; then
        systemctl stop "keepalive-tap-${TUN_ID}" "tunnel-tap-${TUN_ID}" 2>/dev/null
        systemctl disable "keepalive-tap-${TUN_ID}" "tunnel-tap-${TUN_ID}" 2>/dev/null
        rm -f "/etc/systemd/system/keepalive-tap-${TUN_ID}.service" "/etc/systemd/system/tunnel-tap-${TUN_ID}.service"
        rm -f "/usr/local/bin/gretap-up-${TUN_ID}.sh" "/usr/local/bin/keepalive-tap-${TUN_ID}.sh"
        systemctl daemon-reload
        
        ip link set "gt4_${TUN_ID}" down 2>/dev/null
        ip link del "gt4_${TUN_ID}" 2>/dev/null
        
        echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
    fi
}

# ==========================================
# Batch Logic
# ==========================================

batch_install() {
    echo -e "${BLUE}--- Batch Install GREtap Tunnels ---${NC}"

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

    read -p "Enter Starting Tunnel ID [1-250]: " START_TUN_ID
    if [[ ! "$START_TUN_ID" =~ ^[0-9]+$ ]]; then START_TUN_ID=1; fi

    # --- Local IP Selection ---
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
        echo "C) Custom Selection (Enter numbers separated by space, e.g. '1 3')"
        
        read -p "Select Local IPs option [A/C/Single Number]: " loc_opt
        
        SELECTED_LOCAL_IPS=()
        if [[ "$loc_opt" =~ ^[aA]$ ]]; then
            SELECTED_LOCAL_IPS=("${available_ips[@]}")
        elif [[ "$loc_opt" =~ ^[cC]$ ]]; then
            read -p "Enter IP numbers to use (e.g. '1 2'): " ip_nums
            for num in $ip_nums; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#available_ips[@]}" ]; then
                    SELECTED_LOCAL_IPS+=("${available_ips[$((num-1))]}")
                fi
            done
        elif [[ "$loc_opt" =~ ^[0-9]+$ ]] && [ "$loc_opt" -ge 1 ] && [ "$loc_opt" -le "${#available_ips[@]}" ]; then
             SELECTED_LOCAL_IPS=("${available_ips[$((loc_opt-1))]}")
        else
             echo "Invalid selection, defaulting to primary IP."
             SELECTED_LOCAL_IPS=($(get_public_ip))
        fi
    fi
    echo -e "Selected Local IPs: ${GREEN}${SELECTED_LOCAL_IPS[*]}${NC}"

    # --- Remote IP Selection ---
    echo -e "\n${CYAN}--- Remote Server IPs ---${NC}"
    read -p "Enter Remote Server Public IPs (space separated): " -a REMOTE_IPS_INPUT
    
    if [ ${#REMOTE_IPS_INPUT[@]} -eq 0 ]; then
        echo "${RED}No Remote IPs entered!${NC}"
        return
    fi

    # --- Logic for Matching IPs ---
    local count_local=${#SELECTED_LOCAL_IPS[@]}
    local count_remote=${#REMOTE_IPS_INPUT[@]}
    local loop_count=0
    
    if [ $count_local -gt $count_remote ]; then
        loop_count=$count_local
    else
        loop_count=$count_remote
    fi

    echo -e "\n${YELLOW}Preparing to install $loop_count tunnels...${NC}"
    echo "Press ENTER to start..."
    read

    enable_modules

    for (( i=0; i<loop_count; i++ )); do
        # Calculate current Tunnel ID
        CURRENT_ID=$((START_TUN_ID + i))
        
        # Determine Local IP (Cyclic)
        local_idx=$((i % count_local))
        CURRENT_LOCAL_IP=${SELECTED_LOCAL_IPS[$local_idx]}
        
        # Determine Remote IP (Cyclic)
        remote_idx=$((i % count_remote))
        CURRENT_REMOTE_IP=${REMOTE_IPS_INPUT[$remote_idx]}
        
        echo -e "\n--------------------------------------------------"
        echo -e "${BLUE}Configuring Tunnel #$CURRENT_ID${NC}"
        echo -e "  Local Public IP: ${GREEN}$CURRENT_LOCAL_IP${NC}"
        echo -e "  Remote Public IP: ${GREEN}$CURRENT_REMOTE_IP${NC}"
        echo -e "--------------------------------------------------"
        
        setup_gretap_tunnel "$CURRENT_ID" "$CURRENT_LOCAL_IP" "$CURRENT_REMOTE_IP"
        setup_keepalive "$CURRENT_ID"
        
        echo -e "${GREEN}✅ Tunnel $CURRENT_ID Installed!${NC}"
    done
    
    echo -e "\n${GREEN}All batch operations completed.${NC}"
    read -p "Press Enter to return..."
}

# Main Menu
clear
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}   GREtap Multi-Tunnel (10.10.x.x)  ${NC}"
echo -e "${GREEN}====================================${NC}"
echo "1) Single Install"
echo "2) Batch Install (Multi)"
echo "3) Uninstall Menu"
echo "4) Exit"
read -p "Select: " opt

case $opt in
    1) install_tunnel ;;
    2) batch_install ;;
    3) uninstall_menu ;;
    *) exit 0 ;;
esac

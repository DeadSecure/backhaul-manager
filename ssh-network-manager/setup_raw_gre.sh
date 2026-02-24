#!/bin/bash

# ==========================================
# RAW GRE Tunnel Manager
# Architecture: L3 over IPv4 (No Encryption)
# Engine: Kernel 'ip_gre' module
# Advantages: Lowest overhead, fastest speed.
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/gre-raw-setup.log"

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

install_dependencies() {
    log "Checking dependencies and Kernel Modules..."
    
    # Try to load modules
    if ! modprobe ip_gre && modprobe gre; then
        echo -e "${YELLOW}Modprobe failed! Attempting to install kernel-modules-extra...${NC}"
        if [ -f /etc/debian_version ]; then
            apt-get update -qq && apt-get install -y linux-modules-extra-$(uname -r) || true
        elif [ -f /etc/redhat-release ]; then
            yum install -y kernel-modules-extra || true
        fi
        modprobe ip_gre && modprobe gre || echo -e "${RED}Kernel modules still not loading. Tunnel might fail. (OpenVZ/LXC unsupported)${NC}"
    fi
}

setup_gre_raw_interface() {
    local id=$1
    local local_ip=$2
    local remote_ip=$3
    local tun_local=$4
    local tun_remote=$5
    
    local if_name="greraw_${id}"
    local up_script="/usr/local/bin/gre-raw-up-${id}.sh"
    local service_name="tunnel-gre-raw-${id}"

    log "Creating UP script at $up_script..."
    cat > "$up_script" <<EOF
#!/bin/bash
exec > /var/log/gre-raw-up-${id}.log 2>&1
set -x
ip link set ${if_name} down 2>/dev/null
ip link del ${if_name} 2>/dev/null || true
ip tunnel add ${if_name} mode gre local ${local_ip} remote ${remote_ip} ttl 255
ip link set ${if_name} mtu 1400
ip link set ${if_name} up
ip addr add ${tun_local}/30 dev ${if_name}
EOF
    chmod +x "$up_script"

    log "Creating SystemD Service: ${service_name}..."
    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=RAW GRE Tunnel ${id}
After=network.target

[Service]
Type=oneshot
ExecStart=${up_script}
RemainAfterExit=yes
ExecStop=/sbin/ip link set ${if_name} down ; /sbin/ip tunnel del ${if_name}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}"
    systemctl restart "${service_name}"
}

setup_keepalive() {
    local id=$1
    local target=$2
    
    local watchdog_script="/usr/local/bin/keepalive-gre-raw-${id}.sh"
    local watchdog_svc="keepalive-gre-raw-${id}"
    local tunnel_svc="tunnel-gre-raw-${id}"

    log "Creating Watchdog Script at $watchdog_script..."
    cat > "$watchdog_script" <<EOF
#!/bin/bash
TARGET="$target"
while true; do
    if ! ping -c 3 -W 1 "\$TARGET" > /dev/null 2>&1; then
        echo "[\$(date)] Ping to \$TARGET failed. Restarting ${tunnel_svc}..."
        systemctl restart "${tunnel_svc}"
        sleep 5
    fi
    sleep 10
done
EOF
    chmod +x "$watchdog_script"

    log "Creating Watchdog SystemD Service..."
    cat > "/etc/systemd/system/${watchdog_svc}.service" <<EOF
[Unit]
Description=Keepalive Watchdog for RAW GRE Tunnel ${id}
After=${tunnel_svc}.service network.target

[Service]
ExecStart=${watchdog_script}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${watchdog_svc}"
    systemctl restart "${watchdog_svc}"
}

# ==========================================
# UI
# ==========================================

install_menu() {
    echo -e "\n${BLUE}--- Install New RAW GRE Tunnel ---${NC}"
    
    echo "1) IRAN Server"
    echo "2) KHAREJ Server"
    read -p "Select Role: " role_opt
    
    read -p "Enter Tunnel Assignment # (ID) [1-250]: " TUN_ID
    if [[ ! "$TUN_ID" =~ ^[0-9]+$ ]]; then TUN_ID=1; fi
    
    # --- Multi-IP Selection Logic ---
    echo -e "\n${CYAN}--- Select Local Source IP for this Tunnel ---${NC}"
    # Get all IPv4s excluding loopback
    local available_ips=($(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1))
    local SELECTED_LOCAL_IP=""
    
    if [ ${#available_ips[@]} -eq 0 ]; then
        SELECTED_LOCAL_IP=$(get_public_ip)
    elif [ ${#available_ips[@]} -eq 1 ]; then
        SELECTED_LOCAL_IP=${available_ips[0]}
    else
        for i in "${!available_ips[@]}"; do
             echo "$((i+1))) ${available_ips[$i]}"
        done
        read -p "Select IP to Bind [1-${#available_ips[@]}]: " ip_opt
        if [[ "$ip_opt" =~ ^[0-9]+$ ]] && [ "$ip_opt" -ge 1 ] && [ "$ip_opt" -le "${#available_ips[@]}" ]; then
            SELECTED_LOCAL_IP=${available_ips[$((ip_opt-1))]}
        else
            SELECTED_LOCAL_IP=$(get_public_ip)
        fi
    fi
    echo -e "Using Local IP: ${GREEN}$SELECTED_LOCAL_IP${NC}"
    # --------------------------------
    
    read -p "Enter Remote Server Public IP: " REMOTE_IP
    
    read -p "Enter Internal IP Prefix (Default: 10.10, press Enter to keep): " IP_PREFIX
    IP_PREFIX=${IP_PREFIX:-10.10}

    local tun_local="${IP_PREFIX}.${TUN_ID}.1"
    local tun_remote="${IP_PREFIX}.${TUN_ID}.2"
    
    if [ "$role_opt" == "2" ]; then
        local temp=$tun_local
        tun_local=$tun_remote
        tun_remote=$temp
    fi
    
    log "Configuring Tunnel $TUN_ID..."
    install_dependencies
    
    setup_gre_raw_interface "$TUN_ID" "$SELECTED_LOCAL_IP" "$REMOTE_IP" "$tun_local" "$tun_remote"
    
    read -p "Do you want to install a Keepalive Watchdog? (y/n, default: y): " INSTALL_WATCHDOG
    INSTALL_WATCHDOG=${INSTALL_WATCHDOG:-y}
    if [[ "$INSTALL_WATCHDOG" =~ ^[Yy]$ ]]; then
        setup_keepalive "$TUN_ID" "$tun_remote"
        log "Watchdog Installed!"
    fi

    echo -e "${GREEN}✅ RAW GRE Tunnel $TUN_ID Installed Successfully!${NC}"
    echo -e "Tunnel Interface: \e[33mgreraw_${TUN_ID}\e[0m"
    echo -e "Test Connection : \e[33mping $tun_remote\e[0m"
}

uninstall_menu() {
    echo -e "\n${BLUE}--- Uninstall Menu ---${NC}"
    echo "1) Uninstall Specific Tunnel ID"
    echo "2) Nuke ALL RAW GRE Tunnels (Force Clean)"
    read -p "Select [1-2]: " u_opt
    
    if [ "$u_opt" == "2" ]; then
        echo -e "${RED}WARNING: This will delete ALL 'greraw' interfaces and services.${NC}"
        read -p "Are you sure? [y/N]: " confirm
        if [[ "$confirm" != "y" ]]; then return; fi
        
        # Stop Services
        systemctl stop "tunnel-gre-raw-*" 2>/dev/null
        systemctl disable "tunnel-gre-raw-*" 2>/dev/null
        systemctl stop "keepalive-gre-raw-*" 2>/dev/null
        systemctl disable "keepalive-gre-raw-*" 2>/dev/null
        
        # Remove Files
        rm -f /etc/systemd/system/tunnel-gre-raw-*.service
        rm -f /etc/systemd/system/keepalive-gre-raw-*.service
        rm -f /usr/local/bin/gre-raw-up-*.sh
        rm -f /usr/local/bin/keepalive-gre-raw-*.sh
        
        # Force Delete Interfaces
        echo "Deleting interfaces..."
        for dev in $(ip link show | grep -o 'greraw_[0-9]\+'); do
            ip link set "$dev" down
            ip delete "$dev" 2>/dev/null
            ip tunnel del "$dev" 2>/dev/null
        done
        
        systemctl daemon-reload
        echo -e "${GREEN}All RAW GRE Tunnels Nuked.${NC}"
        return
    fi

    read -p "Enter Tunnel ID to uninstall: " TUN_ID
    if [[ -n "$TUN_ID" ]]; then
        systemctl stop "keepalive-gre-raw-${TUN_ID}" "tunnel-gre-raw-${TUN_ID}"
        systemctl disable "keepalive-gre-raw-${TUN_ID}" "tunnel-gre-raw-${TUN_ID}"
        
        # FORCE DELETE LINK
        ip link set "greraw_${TUN_ID}" down 2>/dev/null
        ip delete "greraw_${TUN_ID}" 2>/dev/null
        ip tunnel del "greraw_${TUN_ID}" 2>/dev/null
        
        rm -f "/etc/systemd/system/keepalive-gre-raw-${TUN_ID}.service"
        rm -f "/etc/systemd/system/tunnel-gre-raw-${TUN_ID}.service"
        rm -f "/usr/local/bin/keepalive-gre-raw-${TUN_ID}.sh"
        rm -f "/usr/local/bin/gre-raw-up-${TUN_ID}.sh"
        
        systemctl daemon-reload
        echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
    fi
}

check_tunnels() {
    clear
    echo -e "${BLUE}--- RAW GRE Tunnel Status Check ---${NC}"
    printf "%-5s %-20s %-25s %-20s\n" "ID" "Interface" "Service Status" "Ping Test"
    echo "------------------------------------------------------------------"
    
    # Reset failed states to ensure accurate reading
    systemctl reset-failed "tunnel-gre-raw-*" >/dev/null 2>&1
    
    # Find all GRE services
    for service_file in /etc/systemd/system/tunnel-gre-raw-*.service; do
        if [ ! -f "$service_file" ]; then continue; fi
        
        [[ $service_file =~ tunnel-gre-raw-([0-9]+).service ]] && id="${BASH_REMATCH[1]}"
        if_name="greraw_${id}"
        
        # 3. Ping Test
        target_ip=$(grep 'TARGET=' "/usr/local/bin/keepalive-gre-raw-${id}.sh" 2>/dev/null | cut -d'"' -f2)
        if [[ -n "$target_ip" ]]; then
            if ping -c 1 -W 1 "$target_ip" >/dev/null 2>&1; then
                ping_status="${GREEN}SUCCESS ($target_ip)${NC}"
            else
                ping_status="${RED}FAILED ($target_ip)${NC}"
            fi
        else
            ping_status="${YELLOW}Unknown Target${NC}"
        fi

        # Service Status
        if ip link show "${if_name}" >/dev/null 2>&1; then
            if_status="${GREEN}UP (${if_name})${NC}"
        else
            if_status="${RED}DOWN (${if_name})${NC}"
        fi

        if systemctl is-active --quiet "tunnel-gre-raw-${id}"; then
            svc_status="${GREEN}Active (Sysd)${NC}"
        else
            svc_status="${RED}Failed / Stopped${NC}"
        fi

        # Use %b to interpret color codes correctly
        printf "%-5s %-30b %-35b %-30b\n" "$id" "$if_status" "$svc_status" "$ping_status"
    done
    echo ""
    read -p "Press Enter to return..."
}

# Main Loop
while true; do
    clear
    echo -e "${CYAN}==================================${NC}"
    echo -e "${GREEN}    RAW GRE Manager V1.0         ${NC}"
    echo -e "${CYAN}==================================${NC}"
    echo "1) Install Tunnel"
    echo "2) Uninstall Tunnel"
    echo "3) Check Connection Status"
    echo "4) Exit"
    echo ""
    read -p "Select Option: " opt
    
    case $opt in
        1) install_menu ;;
        2) uninstall_menu ;;
        3) check_tunnels ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ; sleep 1 ;;
    esac
done

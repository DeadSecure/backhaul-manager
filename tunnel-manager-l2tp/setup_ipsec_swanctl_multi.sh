#!/bin/bash

# ==========================================
# GRE + IPSec (Swanctl) Multi-Tunnel Manager
# Architecture: GRE over IPSec (Transport Mode)
# Engine: StrongSwan 5.x + Swanctl (VICI)
# Advantages: No service restarts, independent tunnels, atomic updates.
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/ipsec-swanctl-setup.log"
SWANCTL_DIR="/etc/swanctl"
CONF_D_DIR="$SWANCTL_DIR/conf.d"

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
    log "Checking dependencies..."
    
    if ! command -v swanctl &> /dev/null; then
        log "Installing StrongSwan (swanctl)..."
        apt-get update -qq
        apt-get install -y -qq strongswan strongswan-pki libstrongswan-extra-plugins strongswan-swanctl charon-systemd
    fi
    
    mkdir -p "$CONF_D_DIR"
    
    # Kernel Modules
    modprobe af_key >> "$LOG_FILE" 2>&1
    modprobe ip_gre >> "$LOG_FILE" 2>&1
    
    # CRITICAL: Disable legacy, Enable Modern
    systemctl stop strongswan 2>/dev/null || true
    systemctl disable strongswan 2>/dev/null || true
    systemctl stop strongswan-starter 2>/dev/null || true
    systemctl disable strongswan-starter 2>/dev/null || true
    
    # Enable Charon-Systemd (The VICI backend)
    systemctl enable strongswan-swanctl >> "$LOG_FILE" 2>&1
    systemctl restart strongswan-swanctl >> "$LOG_FILE" 2>&1
    
    sleep 2
}

configure_firewall() {
    iptables -I INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p 47 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p esp -j ACCEPT 2>/dev/null || true
}

setup_swanctl_config() {
    local id=$1
    local local_ip=$2
    local remote_ip=$3
    local psk=$4
    
    # Generate Unique Config File for this Tunnel
    cat > "$CONF_D_DIR/tun${id}.conf" <<EOF
connections {
    tun${id} {
        local_addrs = $local_ip
        remote_addrs = $remote_ip
        version = 2
        proposals = aes256-sha256-modp2048,aes128-sha1-modp1024
        
        local {
            auth = psk
            id = $local_ip
        }
        remote {
            auth = psk
            id = $remote_ip
        }
        
        children {
            tun${id} {
                mode = transport
                esp_proposals = aes256-sha256,aes128-sha1
                start_action = trap
                dpd_action = restart
                dpd_delay = 30s
            }
        }
    }
}

secrets {
    ike-tun${id} {
        id = $remote_ip
        secret = "$psk"
    }
}
EOF

    log "Loading Swanctl Config for Tunnel $id..."
    # Reload ONLY causes new configs to be read, does NO harm to existing connections
    swanctl --load-all
}

setup_gre_interface() {
    local id=$1
    local local_ip=$2
    local remote_ip=$3
    local tun_local=$4
    local tun_remote=$5
    
    cat > "/usr/local/bin/ipsec-gre-up-${id}.sh" <<EOF
#!/bin/bash
ip tunnel del gre${id} 2>/dev/null || true
ip tunnel add gre${id} mode gre remote $remote_ip local $local_ip ttl 255
ip link set gre${id} mtu 1400
ip link set gre${id} up
ip addr add $tun_local/30 dev gre${id}
EOF
    chmod +x "/usr/local/bin/ipsec-gre-up-${id}.sh"

    cat > "/etc/systemd/system/ipsec-gre-${id}.service" <<EOF
[Unit]
Description=GRE over IPsec Tunnel ${id}
After=strongswan-swanctl.service network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipsec-gre-up-${id}.sh
# Ignore errors if SA is already up (prevents service from being marked Failed)
ExecStartPost=-/usr/sbin/swanctl --initiate --child tun${id}
RemainAfterExit=yes
ExecStop=/sbin/ip tunnel del gre${id}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "ipsec-gre-${id}"
    systemctl restart "ipsec-gre-${id}"
}

setup_keepalive() {
    local id=$1
    local target=$2
    
    cat > "/usr/local/bin/ipsec-keepalive-${id}.sh" <<EOF
#!/bin/bash
TARGET="$target"
ID="$id"
while true; do
    # Logic matched with ssh-network-manager (Patient Keepalive)
    if ! ping -c 6 -W 2 \$TARGET > /dev/null; then
        echo "Connection lost. Re-initiating IPsec..."
        swanctl --initiate --child tun\$ID
        sleep 2
        systemctl restart ipsec-gre-\$ID
        sleep 5
    fi
    sleep 4
done
EOF
    chmod +x "/usr/local/bin/ipsec-keepalive-${id}.sh"
    
    cat > "/etc/systemd/system/ipsec-keepalive-${id}.service" <<EOF
[Unit]
Description=Keepalive for IPsec Tunnel ${id}
After=ipsec-gre-${id}.service

[Service]
ExecStart=/usr/local/bin/ipsec-keepalive-${id}.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "ipsec-keepalive-${id}"
    systemctl restart "ipsec-keepalive-${id}"
}

# ==========================================
# UI
# ==========================================

install_menu() {
    echo -e "${BLUE}--- Install New IPsec+GRE Tunnel (Swanctl) ---${NC}"
    
    echo "1) IRAN Server"
    echo "2) KHAREJ Server"
    read -p "Select Role: " role_opt
    
    read -p "Enter Tunnel Assignment # (ID) [1-99]: " TUN_ID
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
    read -p "Enter IPsec Pre-Shared Key (PSK): " PSK
    
    local tun_local="10.10.${TUN_ID}.1"
    local tun_remote="10.10.${TUN_ID}.2"
    
    if [ "$role_opt" == "2" ]; then
        local temp=$tun_local
        tun_local=$tun_remote
        tun_remote=$temp
    fi
    
    log "Configuring Tunnel $TUN_ID..."
    install_dependencies
    configure_firewall
    setup_swanctl_config "$TUN_ID" "$SELECTED_LOCAL_IP" "$REMOTE_IP" "$PSK"
    setup_gre_interface "$TUN_ID" "$SELECTED_LOCAL_IP" "$REMOTE_IP" "$tun_local" "$tun_remote"
    setup_keepalive "$TUN_ID" "$tun_remote"
    
    echo -e "${GREEN}✅ Tunnel $TUN_ID Installed Successfully!${NC}"
}

uninstall_menu() {
    read -p "Enter Tunnel ID to uninstall: " TUN_ID
    if [[ -n "$TUN_ID" ]]; then
        systemctl stop "ipsec-keepalive-${TUN_ID}" "ipsec-gre-${TUN_ID}"
        systemctl disable "ipsec-keepalive-${TUN_ID}" "ipsec-gre-${TUN_ID}"
        
        rm -f "/etc/systemd/system/ipsec-keepalive-${TUN_ID}.service"
        rm -f "/etc/systemd/system/ipsec-gre-${TUN_ID}.service"
        rm -f "/usr/local/bin/ipsec-keepalive-${TUN_ID}.sh"
        rm -f "/usr/local/bin/ipsec-gre-up-${TUN_ID}.sh"
        rm -f "$CONF_D_DIR/tun${TUN_ID}.conf"
        
        # Unload from Swanctl memory
        swanctl --terminate --ike tun${TUN_ID} 2>/dev/null
        swanctl --load-all
        
        systemctl daemon-reload
        echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
    fi
}

check_tunnels() {
    echo -e "${BLUE}--- Tunnel Status Check ---${NC}"
    printf "%-5s %-12s %-25s %-20s\n" "ID" "Service" "IPsec SA" "Ping Test (GRE)"
    echo "------------------------------------------------------------------"
    
    # Try to start daemon seamlessly if missing
    if ! systemctl is-active --quiet strongswan-swanctl; then
         systemctl restart strongswan-swanctl >/dev/null 2>&1
         sleep 1
    fi
    
    # Silently capture swanctl output. If it fails, variable is empty. No stderr.
    local swan_out=$(swanctl --list-sas 2>/dev/null)
    
    # Reset failed states to ensure accurate reading (Fixes false positives)
    systemctl reset-failed "ipsec-gre-*" >/dev/null 2>&1
    
    # Find all GRE services
    for service_file in /etc/systemd/system/ipsec-gre-*.service; do
        if [ ! -f "$service_file" ]; then continue; fi
        
        [[ $service_file =~ ipsec-gre-([0-9]+).service ]] && id="${BASH_REMATCH[1]}"
        
        # 3. Ping Test FIRST (Source of Truth)
        target_ip=$(grep 'TARGET=' "/usr/local/bin/ipsec-keepalive-${id}.sh" 2>/dev/null | cut -d'"' -f2)
        if [[ -n "$target_ip" ]]; then
            if ping -c 1 -W 1 "$target_ip" >/dev/null 2>&1; then
                ping_status="${GREEN}SUCCESS ($target_ip)${NC}"
                is_connected=true
            else
                ping_status="${RED}FAILED ($target_ip)${NC}"
                is_connected=false
            fi
        else
            ping_status="${YELLOW}Unknown Target${NC}"
            is_connected=false
        fi

        # 1. Service Status (Logic Update: If Ping works, Service IS Up)
        if [ "$is_connected" = true ]; then
             svc_status="${GREEN}Active (Verified)${NC}"
        elif ip link show "gre${id}" >/dev/null 2>&1; then
            svc_status="${GREEN}Active (Up)${NC}"
        elif systemctl is-active --quiet "ipsec-gre-${id}"; then
            svc_status="${GREEN}Active (Sysd)${NC}"
        else
            svc_status="${RED}Down${NC}"
        fi

        # 2. IPsec SA Status (Logic: If Ping works, SA IS UP regardless of swanctl api error)

        # 2. IPsec SA Status (Logic: If Ping works, SA IS UP regardless of swanctl api error)
        if echo "$swan_out" | grep -q "tun${id}"; then
            sas_status="${GREEN}ESTABLISHED${NC}"
        elif [ "$is_connected" = true ]; then
            sas_status="${GREEN}ESTABLISHED (Flowing)${NC}"
        else
            sas_status="${RED}NO-SA${NC}"
        fi
        
        # Use %b to interpret color codes correctly
        printf "%-5s %-30b %-45b %-30b\n" "$id" "$svc_status" "$sas_status" "$ping_status"
    done
    echo ""
    read -p "Press Enter to return..."
}

# Main Loop
while true; do
    clear
    echo -e "${GREEN}   Swanctl IPsec Manager V3   ${NC}"
    echo "1) Install Tunnel"
    echo "2) Uninstall Tunnel"
    echo "3) Check Connection Status"
    echo "4) Exit"
    read -p "Select: " opt
    
    case $opt in
        1) install_menu ;;
        2) uninstall_menu ;;
        3) check_tunnels ;;
        4) exit 0 ;;
        *) echo "Invalid option" ; sleep 1 ;;
    esac
done

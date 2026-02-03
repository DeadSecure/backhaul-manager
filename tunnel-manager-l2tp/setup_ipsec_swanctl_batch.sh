#!/bin/bash

# ==========================================
# Colors
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/ipsec-swanctl-batch.log"
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
# Install Dependencies
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
# Main Batch Logic
# ==========================================
batch_install() {
    echo -e "${BLUE}--- Batch Install IPsec+GRE Tunnels ---${NC}"

    echo "1) IRAN Server (Initiator/Hub)"
    echo "2) KHAREJ Server (Responder/Spoke)"
    read -p "Select Role: " role_opt

    read -p "Enter Starting Tunnel ID [1-99]: " START_TUN_ID
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

    read -p "Enter IPsec Pre-Shared Key (PSK): " PSK

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
    
    install_dependencies
    configure_firewall

    for (( i=0; i<loop_count; i++ )); do
        # Calculate current Tunnel ID
        CURRENT_ID=$((START_TUN_ID + i))
        
        # Determine Local IP (Cyclic)
        local_idx=$((i % count_local))
        CURRENT_LOCAL_IP=${SELECTED_LOCAL_IPS[$local_idx]}
        
        # Determine Remote IP (Cyclic)
        remote_idx=$((i % count_remote))
        CURRENT_REMOTE_IP=${REMOTE_IPS_INPUT[$remote_idx]}
        
        # Determine GRE IPs (172.20.ID.x)
        # Assuming ID fits in octet (<255)
        local gre_local="172.20.${CURRENT_ID}.1"
        local gre_remote="172.20.${CURRENT_ID}.2"

        # Swap valid GRE IPs based on role
        # Originally: Local=10.10.ID.1 (Hub/Iran), Remote=10.10.ID.2 (Kharej)
        # If user selected Role 2 (Kharej), we act as Spoke.
        # usually 1 (Hub) takes .1 and 2 (Spoke) takes .2
        
        # Actually logic in original script:
        # tun_local="10.10.${TUN_ID}.1" -> assigned to local interface by default
        # if role == 2 -> swap, so local gets .2
        
        local final_gre_local=$gre_local
        local final_gre_remote=$gre_remote
        
        if [ "$role_opt" == "2" ]; then
            final_gre_local=$gre_remote
            final_gre_remote=$gre_local
        fi

        echo -e "\n--------------------------------------------------"
        echo -e "${BLUE}Configuring Tunnel #$CURRENT_ID${NC}"
        echo -e "  Local Public IP: ${GREEN}$CURRENT_LOCAL_IP${NC}"
        echo -e "  Remote Public IP: ${GREEN}$CURRENT_REMOTE_IP${NC}"
        echo -e "  GRE Local IP:    $final_gre_local"
        echo -e "  GRE Remote IP:   $final_gre_remote"
        echo -e "--------------------------------------------------"
        
        setup_swanctl_config "$CURRENT_ID" "$CURRENT_LOCAL_IP" "$CURRENT_REMOTE_IP" "$PSK"
        setup_gre_interface "$CURRENT_ID" "$CURRENT_LOCAL_IP" "$CURRENT_REMOTE_IP" "$final_gre_local" "$final_gre_remote"
        setup_keepalive "$CURRENT_ID" "$final_gre_remote"
        
        echo -e "${GREEN}✅ Tunnel $CURRENT_ID Installed!${NC}"
    done
    
    echo -e "\n${GREEN}All batch operations completed.${NC}"
    read -p "Press Enter to return..."
}

uninstall_menu() {
    # Reuse original uninstall logic but simplified call
    echo "1) Uninstall Specific Tunnel ID"
    echo "2) Nuke ALL Tunnels (Force Clean)"
    read -p "Select: " u_opt

    if [ "$u_opt" == "2" ]; then
        echo -e "${RED}WARNING: This will delete ALL 'gre' interfaces and 'ipsec-gre' services.${NC}"
        read -p "Are you sure? [y/N]: " confirm
        if [[ "$confirm" != "y" ]]; then return; fi

        systemctl stop "ipsec-gre-*" 2>/dev/null
        systemctl disable "ipsec-gre-*" 2>/dev/null
        systemctl stop "ipsec-keepalive-*" 2>/dev/null
        systemctl disable "ipsec-keepalive-*" 2>/dev/null

        rm -f /etc/systemd/system/ipsec-gre-*.service
        rm -f /etc/systemd/system/ipsec-keepalive-*.service
        rm -f /usr/local/bin/ipsec-gre-up-*.sh
        rm -f /usr/local/bin/ipsec-keepalive-*.sh
        rm -f "$CONF_D_DIR/tun*.conf"

        for i in {1..99}; do
            ip link delete "gre$i" 2>/dev/null
            ip tunnel del "gre$i" 2>/dev/null
        done
        
        swanctl --terminate --ike "*" 2>/dev/null
        swanctl --load-all
        systemctl daemon-reload
        log "All tunnels nuked."
        echo -e "${GREEN}All Tunnels Nuked.${NC}"
        return
    fi
    
    read -p "Enter Tunnel ID to uninstall: " TUN_ID
    if [[ -n "$TUN_ID" ]]; then
        systemctl stop "ipsec-keepalive-${TUN_ID}" "ipsec-gre-${TUN_ID}"
        systemctl disable "ipsec-keepalive-${TUN_ID}" "ipsec-gre-${TUN_ID}"
        ip link delete "gre${TUN_ID}" 2>/dev/null
        ip tunnel del "gre${TUN_ID}" 2>/dev/null
        
        rm -f "/etc/systemd/system/ipsec-keepalive-${TUN_ID}.service"
        rm -f "/etc/systemd/system/ipsec-gre-${TUN_ID}.service"
        rm -f "/usr/local/bin/ipsec-keepalive-${TUN_ID}.sh"
        rm -f "/usr/local/bin/ipsec-gre-up-${TUN_ID}.sh"
        rm -f "$CONF_D_DIR/tun${TUN_ID}.conf"
        
        swanctl --terminate --ike tun${TUN_ID} 2>/dev/null
        swanctl --load-all
        systemctl daemon-reload
        echo -e "${GREEN}Tunnel $TUN_ID Removed.${NC}"
    fi
}

check_tunnels() {
    # Simplified reuse of check logic
    echo -e "${BLUE}--- Tunnel Status Check ---${NC}"
    printf "%-5s %-12s %-25s %-20s\n" "ID" "Service" "IPsec SA" "Ping Test"
    echo "------------------------------------------------------------------"
    
    local swan_out=$(swanctl --list-sas 2>/dev/null)
    
    for service_file in /etc/systemd/system/ipsec-gre-*.service; do
        if [ ! -f "$service_file" ]; then continue; fi
        [[ $service_file =~ ipsec-gre-([0-9]+).service ]] && id="${BASH_REMATCH[1]}"
        
        target_ip=$(grep 'TARGET=' "/usr/local/bin/ipsec-keepalive-${id}.sh" 2>/dev/null | cut -d'"' -f2)
        
        if [[ -n "$target_ip" ]]; then
            if ping -c 1 -W 1 "$target_ip" >/dev/null 2>&1; then
                ping_status="${GREEN}UP ($target_ip)${NC}"
                is_connected=true
            else
                ping_status="${RED}DOWN ($target_ip)${NC}"
                is_connected=false
            fi
        else
            ping_status="${YELLOW}Unknown${NC}"
            is_connected=false
        fi

        if [ "$is_connected" = true ]; then
            svc_status="${GREEN}Active${NC}"
        else
            svc_status="${RED}Issues${NC}"
        fi

        if echo "$swan_out" | grep -q "tun${id}"; then
            sas_status="${GREEN}ESTABLISHED${NC}"
        else
            sas_status="${RED}NO-SA${NC}"
        fi

        printf "%-5s %-30b %-45b %-30b\n" "$id" "$svc_status" "$sas_status" "$ping_status"
    done
    echo ""
    read -p "Press Enter to return..."
}

# Main Loop
while true; do
    clear
    echo -e "${GREEN}   Swanctl IPsec BATCH Manager   ${NC}"
    echo "1) Batch Install Tunnels"
    echo "2) Uninstall Tunnel"
    echo "3) Check Connection Status"
    echo "4) Exit"
    read -p "Select: " opt

    case $opt in
        1) batch_install ;;
        2) uninstall_menu ;;
        3) check_tunnels ;;
        4) exit 0 ;;
        *) echo "Invalid option" ; sleep 1 ;;
    esac
done

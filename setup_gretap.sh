#!/bin/bash

# ==========================================
#  GREtap Tunnel Manager v1.0
#  Based on setup_gost_v2.sh style
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# ==========================================
# Check Prerequisites
# ==========================================
check_prereqs() {
    if ! lsmod | grep -q "ip_gre"; then
        echo -e "${YELLOW}Loading 'ip_gre' kernel module...${NC}"
        modprobe ip_gre
        if [ $? -eq 0 ]; then
            echo "ip_gre" > /etc/modules-load.d/ip_gre.conf
            echo -e "${GREEN}Module loaded.${NC}"
        else
            echo -e "${RED}Failed to load ip_gre module!${NC}"
        fi
    fi
}

# ==========================================
# Create Tunnel Service
# ==========================================
create_tunnel() {
    local TYPE=$1
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    if [ "$TYPE" == "server" ]; then
        echo -e "${BLUE}  Setup Server (Kharej) - GREtap${NC}"
    else
        echo -e "${BLUE}  Setup Client (Iran) - GREtap${NC}"
    fi
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    # Detect Public IP
    local MY_IP=$(hostname -I | awk '{print $1}')
    
    echo -e "Your IP seems to be: ${GREEN}${MY_IP}${NC}"
    read -p "Enter Local IP (this server) [${MY_IP}]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$MY_IP}

    read -p "Enter Remote IP (peer server): " REMOTE_IP
    [[ -z "$REMOTE_IP" ]] && { echo -e "${RED}Remote IP required${NC}"; return; }

    # Tunnel Interface Name
    read -p "Tunnel Interface Name [gretap1]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-gretap1}

    # Tunnel Internal IP (CIDR)
    if [ "$TYPE" == "server" ]; then
        DEFAULT_CIDR="10.10.10.1/30"
    else
        DEFAULT_CIDR="10.10.10.2/30"
    fi
    read -p "Tunnel IP (CIDR) [${DEFAULT_CIDR}]: " TUN_IP
    TUN_IP=${TUN_IP:-$DEFAULT_CIDR}

    # TTL
    read -p "Tunnel TTL [255]: " TTL_VAL
    TTL_VAL=${TTL_VAL:-255}

    SERVICE_NAME="gretap-${TUN_NAME}"

    echo -e "${YELLOW}Creating systemd service: $SERVICE_NAME...${NC}"

    # Create Systemd Service
    # Note: We use Type=oneshot with RemainAfterExit=yes for network interface setup
    cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=GREtap Tunnel ($TUN_NAME)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip link add $TUN_NAME type gretap remote $REMOTE_IP local $LOCAL_IP ttl $TTL_VAL
ExecStart=/sbin/ip link set $TUN_NAME up
ExecStart=/sbin/ip addr add $TUN_IP dev $TUN_NAME
ExecStop=/sbin/ip link set $TUN_NAME down
ExecStop=/sbin/ip link del $TUN_NAME

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME

    sleep 1
    local status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Tunnel Setup Complete! (${status})${NC}"
    echo -e "${GREEN}  Service  : ${SERVICE_NAME}${NC}"
    echo -e "${GREEN}  Interface: ${TUN_NAME}${NC}"
    echo -e "${GREEN}  Local IP : ${LOCAL_IP}${NC}"
    echo -e "${GREEN}  Remote IP: ${REMOTE_IP}${NC}"
    echo -e "${GREEN}  Tunnel IP: ${TUN_IP}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    
    if [ "$TYPE" == "server" ]; then
         echo -e "${YELLOW}Now run this script on the CLIENT side with swapped IPs.${NC}"
    fi
    read -p "Press Enter to continue..."
}

# ==========================================
# List / Status
# ==========================================
list_tunnels() {
    echo ""
    echo -e "${CYAN}CONFIGURED GRETAP TUNNELS${NC}"
    echo ""

    local found=false
    for f in /etc/systemd/system/gretap-*.service; do
        [[ ! -f "$f" ]] && continue
        found=true
        local svc=$(basename "$f" .service)
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[ON]${NC}  $svc"
        else
            echo -e "  ${RED}[OFF]${NC} $svc"
        fi
    done

    $found || echo -e "  ${YELLOW}No tunnels configured${NC}"
    
    echo ""
    echo -e "${CYAN}ACTIVE INTERFACES (ip link)${NC}"
    ip link show type gretap
    
    echo ""
    read -p "Press Enter to continue..."
}

# ==========================================
# Uninstall
# ==========================================
uninstall_menu() {
    echo -e "${BLUE}--- Uninstall Tunnel ---${NC}"
    
    SERVICES=$(ls /etc/systemd/system/gretap-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No GREtap services found.${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo "Found services:"
    i=1
    declare -A SERVICE_MAP
    for svc_path in $SERVICES; do
        svc_name=$(basename "$svc_path" .service)
        local status=$(systemctl is-active "$svc_name" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $i) ${GREEN}[ON]${NC}  $svc_name"
        else
            echo -e "  $i) ${RED}[OFF]${NC} $svc_name"
        fi
        SERVICE_MAP[$i]=$svc_name
        i=$((i+1))
    done
    echo "  0) Cancel"
    
    read -p "Select: " CHOICE
    
    [[ "$CHOICE" == "0" ]] && return

    SVC=${SERVICE_MAP[$CHOICE]}
    if [ ! -z "$SVC" ]; then
        echo -e "${YELLOW}Stopping and removing $SVC...${NC}"
        systemctl stop $SVC
        systemctl disable $SVC
        rm -f "/etc/systemd/system/$SVC.service"
        systemctl daemon-reload
        echo -e "${GREEN}Service '$SVC' removed${NC}"
        
        # Manually cleanup if script failed
        IFACE=$(echo "$SVC" | sed 's/gretap-//')
        if ip link show $IFACE > /dev/null 2>&1; then
             ip link del $IFACE
             echo -e "${GREEN}Interface $IFACE deleted manually${NC}"
        fi
    else
        echo "Invalid choice."
    fi
    
    read -p "Press Enter to continue..."
}

# ==========================================
# Main Menu
# ==========================================
check_prereqs

while true; do
    clear
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  GREtap Tunnel Manager v1.0${NC}"
    echo -e "${GREEN}  L2 Tunneling (Ethernet over GRE)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}1) Setup Server (Kharej)${NC}"
    echo -e "${CYAN}2) Setup Client (Iran)${NC}"
    echo ""
    echo "3) List Tunnels / Status"
    echo "4) Uninstall Tunnel"
    echo "0) Exit"
    echo ""
    read -p "Select: " OPTION

    case $OPTION in
        1)
            create_tunnel "server"
            ;;
        2)
            create_tunnel "client"
            ;;
        3)
            list_tunnels
            ;;
        4)
            uninstall_menu
            ;;
        0)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option"
            sleep 1
            ;;
    esac
done

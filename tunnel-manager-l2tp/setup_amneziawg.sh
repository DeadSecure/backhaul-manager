#!/bin/bash

# ==========================================
# AmneziaWG (Obfuscated WireGuard) Manager
# Architecture: L3 Tunnel with Anti-DPI properties
# Engine: amneziawg-tools + Kernel Module
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

TOOLS_DIR="/etc/amnezia/amneziawg"
mkdir -p "$TOOLS_DIR"

log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

install_amnezia() {
    log "Installing AmneziaWG..."
    
    # 1. Add PPA
    if ! grep -q "amnezia/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        apt-get update -qq
        apt-get install -y -qq software-properties-common python3-launchpadlib gnupg2
        add-apt-repository -y ppa:amnezia/ppa
        apt-get update -qq
    fi
    
    # 2. Install Tools & Module w/o prompts
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq amneziawg
    
    # Verify installation
    if ! command -v awg &> /dev/null; then
        echo -e "${RED}AmneziaWG installation failed!${NC}"
        echo "Please assume your kernel supports modules (KVM/Dedicated)."
        exit 1
    fi
    log "AmneziaWG Installed Successfully."
}

# Function to generate random values for obfuscation
gen_random() {
    shuf -i $1-$2 -n 1
}

generate_client_script() {
    local peer_priv=$1
    local local_pub=$2
    local psk=$3
    local remote_ip=$4
    local listen_port=$5
    local jc=$6; local jmin=$7; local jmax=$8
    local s1=$9; local s2=${10}
    local h1=${11}; local h2=${12}; local h3=${13}; local h4=${14}
    local client_ip=${15}
    local server_ip=${16}
    local interface=${17}

    echo "cat > /etc/amnezia/amneziawg/${interface}.conf <<EOF"
    echo "[Interface]"
    echo "PrivateKey = $peer_priv"
    echo "ListenPort = $listen_port"
    echo "Address = $client_ip/30"
    echo "Jc = $jc"
    echo "Jmin = $jmin"
    echo "Jmax = $jmax"
    echo "S1 = $s1"
    echo "S2 = $s2"
    echo "H1 = $h1"
    echo "H2 = $h2"
    echo "H3 = $h3"
    echo "H4 = $h4"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $local_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = 0.0.0.0/0"
    echo "Endpoint = $remote_ip:$listen_port"
    echo "PersistentKeepalive = 20"
    echo "EOF"
    echo "chmod 600 /etc/amnezia/amneziawg/${interface}.conf"
    echo "systemctl enable --now awg-quick@${interface}"
    echo "echo -e \"\033[0;32mClient Configured Successfully!\033[0m\""
}

install_menu() {
    clear
    echo -e "${BLUE}--- AmneziaWG Easy Setup ---${NC}"
    echo "This script assumes you are running it on the MASTER node (e.g. Kharej)."
    echo "It will configure this server AND generate a one-time script for the other server."
    echo ""
    
    read -p "Enter Tunnel Name (default: awg0): " IFACE
    if [[ -z "$IFACE" ]]; then IFACE="awg0"; fi
    
    # Check if already exists
    if [ -f "/etc/amnezia/amneziawg/${IFACE}.conf" ]; then
        echo -e "${RED}Config $IFACE already exists! Aborting.${NC}"
        read -p "Press Enter..."
        return
    fi

    # Detect Local IP
    local my_ip=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    echo -e "Detected Local IP: ${GREEN}$my_ip${NC}"
    
    read -p "Enter REMOTE Server IP (The other side): " REMOTE_PEER_IP
    read -p "Enter Listen Port (default: 51820): " PORT
    if [[ -z "$PORT" ]]; then PORT=51820; fi
    
    install_amnezia
    
    echo "Generating Keys..."
    # Local Keys (Master)
    master_priv=$(awg genkey)
    master_pub=$(echo "$master_priv" | awg pubkey)
    
    # Peer Keys (The other side)
    peer_priv=$(awg genkey)
    peer_pub=$(echo "$peer_priv" | awg pubkey)
    
    psk=$(awg genpsk)
    
    # Generate Magic Obfuscation Params
    Jc=$(gen_random 3 10); Jmin=$(gen_random 50 100); Jmax=$(gen_random 600 1000)
    S1=$(gen_random 100 200); S2=$(gen_random 100 200)
    H1=$(gen_random 1000000000 2000000000)
    H2=$(gen_random 1000000000 2000000000)
    H3=$(gen_random 1000000000 2000000000)
    H4=$(gen_random 1000000000 2000000000)
    
    # Create Local Config (Master)
    cat > "/etc/amnezia/amneziawg/${IFACE}.conf" <<EOF
[Interface]
PrivateKey = $master_priv
ListenPort = $PORT
Address = 10.10.100.1/30
Jc = $Jc
Jmin = $Jmin
Jmax = $Jmax
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $peer_pub
PresharedKey = $psk
AllowedIPs = 10.10.100.2/32
# We don't necessarily know if the other side has a public IP/Port reachable, 
# but usually for a tunnel we assume both are servers.
Endpoint = $REMOTE_PEER_IP:$PORT
PersistentKeepalive = 20
EOF
    chmod 600 "/etc/amnezia/amneziawg/${IFACE}.conf"
    
    # Enable Local Service
    systemctl enable --now "awg-quick@${IFACE}"
    
    echo -e "${GREEN}✅ Local Configuration (Master) Done!${NC}"
    echo "IP: 10.10.100.1"
    echo ""
    echo -e "${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}   COPY THIS CODE AND RUN IN THE OTHER SERVER terminal   ${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    echo ""
    
    # Generate Client Script
    # 10.10.100.2 is peer IP, my_ip is endpoint IP
    generate_client_script "$peer_priv" "$master_pub" "$psk" "$my_ip" "$PORT" \
                           "$Jc" "$Jmin" "$Jmax" "$S1" "$S2" \
                           "$H1" "$H2" "$H3" "$H4" \
                           "10.10.100.2" "10.10.100.1" "$IFACE"
                           
    echo ""
    echo -e "${YELLOW}====================================================${NC}"
    echo "Just copy the lines between the lines above and paste in the other VPS."
    read -p "Press Enter to return..."
}

check_status() {
    clear
    echo -e "${BLUE}--- AmneziaWG Smart Diagnostics ---${NC}"
    
    # 1. Check Service State
    if ! systemctl is-active --quiet "awg-quick@awg0"; then
        echo -e "${RED}[CRITICAL] Service awg-quick@awg0 is STOPPED!${NC}"
        echo "Trying to start..."
        systemctl start awg-quick@awg0
        sleep 2
    fi

    # 2. Check Interface
    if ! ip link show awg0 >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Interface 'awg0' not found.${NC}"
        echo "Check logs: journalctl -xeu awg-quick@awg0"
        read -p "Press Enter..."
        return
    fi
    
    # 3. Analyze Handshake
    local output=$(awg show awg0)
    echo "$output"
    echo "------------------------------------------------"
    
    if echo "$output" | grep -q "latest handshake"; then
        local last_hs=$(echo "$output" | grep "latest handshake" | awk '{print $3, $4}')
        echo -e "${GREEN}✅ Handshake Successful!${NC} (Last: $last_hs)"
        
        # 4. Ping Test
        # Determine peer IP based on my IP
        local my_vpn_ip=$(ip -4 addr show awg0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        local peer_ip=""
        
        if [[ "$my_vpn_ip" == *"10.10.100.1"* ]]; then
            peer_ip="10.10.100.2"
        elif [[ "$my_vpn_ip" == *"10.10.100.2"* ]]; then
            peer_ip="10.10.100.1"
        fi
        
        if [[ -n "$peer_ip" ]]; then
            echo -e "\n${CYAN}--- Pinging Peer ($peer_ip) ---${NC}"
            if ping -c 3 -W 1 "$peer_ip"; then
                echo -e "\n${GREEN}🚀 CONNECTION STABLE! 🚀${NC}"
            else
                echo -e "\n${RED}⚠️ Handshake OK but Ping FAILED.${NC}"
                echo "Possibilities:"
                echo "1. Firewall on Peer is dropping ICMP."
                echo "2. Routing table issue."
            fi
        fi
        
    else
        echo -e "${RED}❌ NO HANDSHAKE DETECTED!${NC}"
        echo -e "${YELLOW}Troubleshooting Tips:${NC}"
        echo "1. Wait 1-2 minutes. Amnezia handshake is sometimes slow."
        echo "2. Check UDP Port blocking. Try changing port in config."
        echo "3. Ensure 'Remote Server IP' was correct during setup."
        echo "4. If in Iran, UDP might be throttled. Try different Garbage params (Jc, S1...)."
    fi
    
    echo ""
    read -p "Press Enter to return..."
}

# Menu
clear
echo -e "${BLUE}AmneziaWG Setup Script${NC}"
echo "1) Install / Configure"
echo "2) Check Status"
echo "3) Uninstall"
echo "4) Exit"
read -p "Select: " opt

case $opt in
    1) install_menu ;;
    2) check_status ;;
    3) apt-get remove -y amneziawg ;;
    4) exit 0 ;;
esac

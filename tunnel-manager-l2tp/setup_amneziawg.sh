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

generate_config() {
    local role=$1
    local tun_id=$2
    local local_ip=$3
    local remote_ip=$4
    local listen_port=$5
    
    # Generate Keys if not exist
    local priv_key=$(awg genkey)
    local pub_key=$(echo "$priv_key" | awg pubkey)
    local psk=$(awg genpsk)
    
    # Amnezia Specific Obfuscation Parameters (The MAGIC)
    # Allows the tunnel to look like random garbage to DPI
    local Jc=$(gen_random 3 10)
    local Jmin=$(gen_random 10 50)
    local Jmax=$(gen_random 50 100)
    local S1=$(gen_random 15 150)
    local S2=$(gen_random 15 150)
    local H1=$(gen_random 5 20)
    local H2=$(gen_random 5 20)
    local H3=$(gen_random 5 20)
    local H4=$(gen_random 5 20)
    
    # Store these shared secrets mainly on one side, but both need to match.
    # For symmetry, we will ask user to PASTE config from Peer A to Peer B.
    
    echo -e "${CYAN}--- GENERATED CONFIG ---${NC}"
    echo "Please SAVE this block. You need to verify these params match on the other side."
    echo ""
    echo "[Interface]"
    echo "PrivateKey = $priv_key"
    echo "ListenPort = $listen_port"
    echo "Address = 10.10.${tun_id}.${role}/30"
    echo "Jc = $Jc"
    echo "Jmin = $Jmin"
    echo "Jmax = $Jmax"
    echo "S1 = $S1"
    echo "S2 = $S2"
    echo "H1 = $H1"
    echo "H2 = $H2"
    echo "H3 = $H3"
    echo "H4 = $H4"
    echo ""
    echo "[Peer]"
    echo "PublicKey = (PUT_REMOTE_PUBKEY_HERE)"
    echo "PresharedKey = $psk"
    echo "Endpoint = $remote_ip:$listen_port"
    echo "AllowedIPs = 0.0.0.0/0"
    echo "------------------------------------------------"
}

# Simplistic approach: Standard WireGuard setup structure but using 'awg' command.
# Since Amnezia requires matching random parameters on both sides, automated script 
# usually generates a "Server" config and a "Client" config file output.

install_menu() {
    echo -e "${BLUE}--- AmneziaWG Tunnel Setup ---${NC}"
    echo "1) Configure This Node"
    read -p "Select: " opt
    
    read -p "Enter Tunnel CONFIG NAME (e.g. awg0): " IFACE
    if [[ -z "$IFACE" ]]; then IFACE="awg0"; fi
    
    read -p "Enter Local Port (UDP) [Default 51820]: " PORT
    if [[ -z "$PORT" ]]; then PORT=51820; fi
    
    # Logic:
    # 1. Install dependencies
    install_amnezia
    
    # 2. Ask if this is the "Initiator" (Config Generator) or "Peer" (Paste Config)
    echo -e "\nSince Amnezia parameters must match perfectly:"
    echo "1) Generate New Configuration (Run this on Server 1)"
    echo "2) Paste Configuration (Run this on Server 2)"
    read -p "Select Mode: " mode
    
    CONFIG_FILE="/etc/amnezia/amneziawg/${IFACE}.conf"
    
    if [ "$mode" == "1" ]; then
        # Generation Logic
        priv=$(awg genkey)
        pub=$(echo "$priv" | awg pubkey)
        psk=$(awg genpsk)
        
        # Magic Params
        Jc=$(gen_random 3 10); Jmin=$(gen_random 50 100); Jmax=$(gen_random 600 1000)
        S1=$(gen_random 100 200); S2=$(gen_random 100 200)
        H1=$(gen_random 1000000000 2000000000) 
        H2=$(gen_random 1000000000 2000000000)
        H3=$(gen_random 1000000000 2000000000)
        H4=$(gen_random 1000000000 2000000000)
        
        local_ip="10.10.100.1/30"
        
        cat > "$CONFIG_FILE" <<EOF
[Interface]
PrivateKey = $priv
ListenPort = $PORT
Address = $local_ip
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
PublicKey = REPLACE_WITH_REMOTE_PUBKEY
PresharedKey = $psk
AllowedIPs = 10.10.100.2/32
Endpoint = REPLACE_WITH_REMOTE_IP:$PORT
EOF
        chmod 600 "$CONFIG_FILE"
        
        echo -e "\n${GREEN}Config Generated at $CONFIG_FILE${NC}"
        echo -e "${YELLOW}IMPORTANT: You must use these EXACT parameters on the other server:${NC}"
        echo "-------------------------------------------------"
        echo "Jc = $Jc"
        echo "Jmin = $Jmin"
        echo "Jmax = $Jmax"
        echo "S1 = $S1"
        echo "S2 = $S2"
        echo "H1 = $H1"
        echo "H2 = $H2"
        echo "H3 = $H3"
        echo "H4 = $H4"
        echo "PresharedKey = $psk"
        echo "PublicKey (Mine) = $pub"
        echo "-------------------------------------------------"
        echo "Update the [Peer] section in $CONFIG_FILE with the Remote Public Key and IP later."
        
    else
        # Paste Logic
        echo -e "${YELLOW}Paste the content for $CONFIG_FILE (Ctrl+D to save):${NC}"
        cat > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    fi
    
    # Enable Service
    systemctl enable --now "awg-quick@${IFACE}"
    echo -e "${GREEN}Service awg-quick@${IFACE} started.${NC}"
}

check_status() {
    awg show
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

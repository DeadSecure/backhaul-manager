#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  XRAY TUNNEL MANAGER - VERSION 2.0 (DIRECT/FORWARD TUNNEL)     ║
# ║  Architecture: Iran (Client) -> Internet -> Foreign (Server)   ║
# ║  Protocol: VLESS + XTLS-Vision + Reality                       ║
# ╚════════════════════════════════════════════════════════════════╝

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Paths
XRAY_PATH="/usr/local/bin/xray"
CONFIG_DIR="/etc/xray-tunnel"
SERVICE_NAME="xray-tunnel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ═══════════════════════════════════════════════════════════════
# CORE FUNCTIONS
# ═══════════════════════════════════════════════════════════════

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     XRAY TUNNEL MANAGER v2.1 (DIRECT FORWARD)              ║"
    echo "║     Mode: Forward Tunnel (Iran -> Foreign)                 ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

install_xray() {
    if [ ! -f "$XRAY_PATH" ]; then
        echo -e "${YELLOW}[*] Installing Xray...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
}

sync_time() {
    echo -e "${YELLOW}[*] Syncing System Time...${NC}"
    timedatectl set-ntp true 2>/dev/null
    systemctl restart systemd-timesyncd 2>/dev/null
    sleep 1
}

apply_kernel_tuning() {
    echo -e "${YELLOW}[*] Applying Kernel Optimizations...${NC}"
    ulimit -n 1048576
    cat > /etc/sysctl.d/99-xray-tunnel.conf << 'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 75
net.ipv4.tcp_keepalive_probes = 9
SYSCTL
    sysctl --system &>/dev/null
}

generate_keys() {
    echo -e "${YELLOW}[*] Generating Keys...${NC}"
    chmod +x "$XRAY_PATH" 2>/dev/null
     mkdir -p "$CONFIG_DIR"

    if [[ -s "$CONFIG_DIR/keys" ]]; then
        echo -e "${GREEN}[*] Using existing keys.${NC}"
    else
        "$XRAY_PATH" x25519 > "$CONFIG_DIR/keys"
    fi

    PRIVATE_KEY=$(grep -i "Private" "$CONFIG_DIR/keys" | awk '{print $NF}')
    PUBLIC_KEY=$(grep -i "Public" "$CONFIG_DIR/keys" | awk '{print $NF}')
    
    # Fallback if grep fails (some Xray versions use "Password"?)
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY=$(grep -i "Password" "$CONFIG_DIR/keys" | awk '{print $NF}')
    fi
}

create_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$XRAY_PATH run -c $CONFIG_DIR/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME &>/dev/null
    systemctl start $SERVICE_NAME
}

# ═══════════════════════════════════════════════════════════════
# SERVER CONFIGURATION (FOREIGN)
# ═══════════════════════════════════════════════════════════════

setup_foreign_server() {
    echo -e "${GREEN}[FOREIGN SERVER SETUP]${NC}"
    sync_time
    install_xray
    apply_kernel_tuning
    generate_keys

    read -p "Enter Port to Listen on (default 443): " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-443}

    # Fixed UUID for simplicity, or generate
    UUID="55555555-5555-5555-5555-555555555555"

    cat > "$CONFIG_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-in",
      "port": $SERVER_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.google.com:443",
          "xver": 0,
          "serverNames": ["www.google.com"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [""]
        },
        "sockopt": { "tcpKeepAlive": true }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["vless-in"], "outboundTag": "direct" }
    ]
  }
}
EOF

    create_service
    
    # Save info
    echo "foreign" > "$CONFIG_DIR/mode"
    
    IP=$(curl -s icanhazip.com || hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║               FOREIGN SERVER READY                         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "IP Address:   ${BLUE}$IP${NC}"
    echo -e "Port:         ${BLUE}$SERVER_PORT${NC}"
    echo -e "UUID:         ${BLUE}$UUID${NC}"
    echo -e "Public Key:   ${YELLOW}$PUBLIC_KEY${NC}"
    echo -e "SNI:          ${BLUE}www.google.com${NC}"
    echo ""
    echo -e "${RED}>>> SAVE THESE VALUES FOR IRAN SERVER <<<${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# CLIENT CONFIGURATION (IRAN)
# ═══════════════════════════════════════════════════════════════

setup_iran_client() {
    echo -e "${GREEN}[IRAN SERVER SETUP]${NC}"
    sync_time
    install_xray
    apply_kernel_tuning

    # Get Foreign Info
    echo -e "${CYAN}Please enter details from Foreign Server:${NC}"
    read -p "Foreign server IP: " FOREIGN_IP
    read -p "Foreign server Port (443): " FOREIGN_PORT
    FOREIGN_PORT=${FOREIGN_PORT:-443}
    read -p "Foreign Public Key: " FOREIGN_PUBKEY
    
    read -p "Local Listen Port (user connects here, default 8080): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-8080}
    
    UUID="55555555-5555-5555-5555-555555555555"

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "dokodemo-in",
      "port": $LOCAL_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "network": "tcp,udp",
        "followRedirect": false
      },
       "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$FOREIGN_IP",
            "port": $FOREIGN_PORT,
            "users": [
              { "id": "$UUID", "flow": "xtls-rprx-vision", "encryption": "none" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "www.google.com",
          "publicKey": "$FOREIGN_PUBKEY",
          "shortId": "",
          "spiderX": ""
        },
        "sockopt": { "tcpKeepAlive": true }
      },
      "mux": { "enabled": false, "concurrency": -1 }
    },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["dokodemo-in"], "outboundTag": "proxy-out" }
    ]
  }
}
EOF

    create_service
    echo "iran" > "$CONFIG_DIR/mode"

    IP=$(curl -s icanhazip.com || hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                 IRAN SERVER READY                          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Users should connect to: ${BLUE}$IP:$LOCAL_PORT${NC}"
    echo -e "Traffic forwards to:     ${BLUE}$FOREIGN_IP:$FOREIGN_PORT${NC}"
    echo ""
    echo -e "${GREEN}Tunnel is Active!${NC}"
}

# ═══════════════════════════════════════════════════════════════
# MAIN MENU
# ═══════════════════════════════════════════════════════════════

show_info() {
    cat "$CONFIG_DIR/config.json"
}

delete_tunnel() {
    systemctl stop $SERVICE_NAME
    systemctl disable $SERVICE_NAME
    rm -rf $CONFIG_DIR $SERVICE_FILE
    echo "Removed."
}

view_logs() {
    journalctl -u $SERVICE_NAME -f
}

menu() {
    show_banner
    echo -e "1) Setup Foreign Server (Upstream)"
    echo -e "2) Setup Iran Server (Downstream)"
    echo -e "3) Show Config"
    echo -e "4) View Logs"
    echo -e "5) Delete Tunnel"
    echo -e "0) Exit"
    echo ""
    read -p "Select: " OPT
    case $OPT in
        1) setup_foreign_server ;;
        2) setup_iran_client ;;
        3) show_info ;;
        4) view_logs ;;
        5) delete_tunnel ;;
        0) exit 0 ;;
        *) echo "Invalid" ;;
    esac
}

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

menu

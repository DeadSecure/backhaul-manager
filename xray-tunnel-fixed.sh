#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  XRAY REVERSE TUNNEL - UNIFIED MANAGER (FIXED & OPTIMIZED)     ║
# ║  XTLS-Vision + Reality | High Performance | Auto-Reconnect     ║
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
# FUNCTIONS
# ═══════════════════════════════════════════════════════════════

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     XRAY REVERSE TUNNEL - UNIFIED MANAGER (FIXED)          ║"
    echo "║     XTLS-Vision + Reality | High Performance               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

install_xray() {
    if [ ! -f "$XRAY_PATH" ]; then
        echo -e "${YELLOW}[*] Installing Xray...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
}

apply_kernel_tuning() {
    echo -e "${YELLOW}[*] Applying Kernel Optimizations...${NC}"
    ulimit -n 1048576

    cat > /etc/sysctl.d/99-xray-tunnel.conf << 'SYSCTL'
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_notsent_lowat = 16384
# Added TCP Keepalive for better tunnel stability
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 75
net.ipv4.tcp_keepalive_probes = 9
SYSCTL

    sysctl --system &>/dev/null
}

open_firewall() {
    local port1=$1
    local port2=$2
    
    if command -v ufw &> /dev/null; then
        ufw allow $port1/tcp &>/dev/null
        [ -n "$port2" ] && ufw allow $port2/tcp &>/dev/null
        ufw reload &>/dev/null
    fi
    iptables -I INPUT -p tcp --dport $port1 -j ACCEPT 2>/dev/null
    [ -n "$port2" ] && iptables -I INPUT -p tcp --dport $port2 -j ACCEPT 2>/dev/null
}

generate_keys() {
    $XRAY_PATH x25519 > "$CONFIG_DIR/keys" 2>/dev/null
    PRIVATE_KEY=$(grep -i "PrivateKey" "$CONFIG_DIR/keys" | awk '{print $NF}' | tr -d ' \r')
    PUBLIC_KEY=$(grep -i "Password" "$CONFIG_DIR/keys" | awk '{print $NF}' | tr -d ' \r')
}

create_iran_config() {
    local bridge_port=$1
    local user_port=$2
    local tunnel_uuid=$3

    cat > "$CONFIG_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["8.8.8.8", "1.1.1.1"], "queryStrategy": "UseIPv4", "disableCache": false },
  "policy": {
    "levels": { "0": { "handshake": 4, "connIdle": 600, "uplinkOnly": 2, "downlinkOnly": 30, "bufferSize": 2048 } },
    "system": { "statsInboundUplink": false, "statsInboundDownlink": false, "statsOutboundUplink": false, "statsOutboundDownlink": false }
  },
  "reverse": { "portals": [{ "tag": "portal", "domain": "reverse.tunnel" }] },
  "inbounds": [
    {
      "tag": "client-in", "port": $user_port, "listen": "0.0.0.0", "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": 443, "network": "tcp,udp", "followRedirect": false }
    },
    {
      "tag": "tunnel-listener", "listen": "0.0.0.0", "port": $bridge_port, "protocol": "vless",
      "settings": { "clients": [{ "id": "$tunnel_uuid", "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": {
        "network": "raw", "security": "reality",
        "realitySettings": {
          "show": false, "target": "www.google.com:443", "xver": 0,
          "serverNames": ["www.google.com", "www.googletagmanager.com"],
          "privateKey": "$PRIVATE_KEY", "shortIds": ["", "0123456789abcdef"]
        },
        "sockopt": { "tcpKeepAlive": true, "tcpKeepAliveIdle": 100, "tcpKeepAliveInterval": 30 }
      }
    }
  ],
  "routing": { "rules": [{ "type": "field", "inboundTag": ["tunnel-listener", "client-in"], "outboundTag": "portal" }] }
}
EOF
}

create_foreign_config() {
    local iran_ip=$1
    local iran_port=$2
    local tunnel_password=$3
    local dest_addr=$4
    local tunnel_uuid=$5

    cat > "$CONFIG_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["8.8.8.8", "1.1.1.1"], "queryStrategy": "UseIPv4", "disableCache": false },
  "policy": {
    "levels": { "0": { "handshake": 4, "connIdle": 600, "uplinkOnly": 2, "downlinkOnly": 30, "bufferSize": 2048 } },
    "system": { "statsInboundUplink": false, "statsInboundDownlink": false, "statsOutboundUplink": false, "statsOutboundDownlink": false }
  },
  "reverse": { "bridges": [{ "tag": "bridge", "domain": "reverse.tunnel" }] },
  "outbounds": [
    {
      "tag": "tunnel-connector", "protocol": "vless",
      "settings": { "vnext": [{ "address": "$iran_ip", "port": $iran_port, "users": [{ "id": "$tunnel_uuid", "flow": "xtls-rprx-vision", "encryption": "none" }] }] },
      "streamSettings": {
        "network": "raw", "security": "reality",
        "realitySettings": { "show": false, "fingerprint": "chrome", "serverName": "www.google.com", "password": "$tunnel_password", "shortId": "", "spiderX": "" },
        "sockopt": { "tcpKeepAlive": true, "tcpKeepAliveIdle": 100, "tcpKeepAliveInterval": 30 }
      },
      "mux": { "enabled": false, "concurrency": -1 }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "portal-to-local", "protocol": "freedom", "settings": { "redirect": "$dest_addr" } }
  ],
  "routing": {
    "rules": [
      { "type": "field", "domain": ["full:reverse.tunnel"], "outboundTag": "tunnel-connector" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "portal-to-local" }
    ]
  }
}
EOF
}

create_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray Reverse Tunnel Service (Fixed)
After=network.target

[Service]
Type=simple
ExecStart=$XRAY_PATH run -c $CONFIG_DIR/config.json
# CHANGED: 'always' ensures restart even if exit code is 0 or killed
Restart=always
# CHANGED: reduced restart delay
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
# SETUP FUNCTIONS
# ═══════════════════════════════════════════════════════════════

setup_iran() {
    echo -e "${GREEN}[IRAN SERVER SETUP]${NC}"
    echo ""
    
    read -p "Enter Bridge Port (default 2096): " BRIDGE_PORT
    BRIDGE_PORT=${BRIDGE_PORT:-2096}
    
    read -p "Enter User Port (default 8443): " USER_PORT
    USER_PORT=${USER_PORT:-8443}
    
    TUNNEL_UUID="55555555-5555-5555-5555-555555555555"
    
    mkdir -p $CONFIG_DIR
    install_xray
    apply_kernel_tuning
    open_firewall $BRIDGE_PORT $USER_PORT
    generate_keys
    
    create_iran_config $BRIDGE_PORT $USER_PORT $TUNNEL_UUID
    create_service
    
    # Save info
    echo "iran" > "$CONFIG_DIR/mode"
    echo "$BRIDGE_PORT" > "$CONFIG_DIR/bridge_port"
    echo "$USER_PORT" > "$CONFIG_DIR/user_port"
    
    IP=$(curl -s icanhazip.com || hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              IRAN SERVER CONFIGURED!                       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Bridge Port:    ${BLUE}$BRIDGE_PORT${NC}"
    echo -e "User Port:      ${BLUE}$USER_PORT${NC}"
    echo -e "Tunnel UUID:    ${BLUE}$TUNNEL_UUID${NC}"
    echo ""
    echo -e "${YELLOW}Password (for Foreign): ${GREEN}$PUBLIC_KEY${NC}"
    echo ""
    echo -e "Run on Foreign Server:"
    echo -e "${CYAN}./xray-tunnel-fixed.sh${NC}"
    echo -e "Then enter: ${BLUE}$IP:$BRIDGE_PORT${NC} and password above"
    echo ""
}

setup_foreign() {
    echo -e "${GREEN}[FOREIGN SERVER SETUP]${NC}"
    echo ""
    
    read -p "Enter Iran Server (IP:PORT, e.g. 1.2.3.4:2096): " IRAN_ADDR
    
    read -p "Enter Password (from Iran server): " TUNNEL_PASSWORD
    
    read -p "Enter Destination (default 127.0.0.1:3031): " DEST_ADDR
    DEST_ADDR=${DEST_ADDR:-127.0.0.1:3031}
    
    IRAN_IP=$(echo $IRAN_ADDR | cut -d: -f1)
    IRAN_PORT=$(echo $IRAN_ADDR | cut -d: -f2)
    TUNNEL_UUID="55555555-5555-5555-5555-555555555555"
    
    mkdir -p $CONFIG_DIR
    install_xray
    apply_kernel_tuning
    
    create_foreign_config $IRAN_IP $IRAN_PORT $TUNNEL_PASSWORD $DEST_ADDR $TUNNEL_UUID
    create_service
    
    # Save info
    echo "foreign" > "$CONFIG_DIR/mode"
    echo "$IRAN_ADDR" > "$CONFIG_DIR/iran_addr"
    echo "$DEST_ADDR" > "$CONFIG_DIR/dest_addr"
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            FOREIGN SERVER CONFIGURED!                      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Connected to Iran: ${BLUE}$IRAN_ADDR${NC}"
    echo -e "Traffic goes to:   ${BLUE}$DEST_ADDR${NC}"
    echo ""
    echo -e "${GREEN}Tunnel is now active!${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# MANAGEMENT FUNCTIONS
# ═══════════════════════════════════════════════════════════════

show_status() {
    echo -e "${CYAN}[Tunnel Status]${NC}"
    systemctl status $SERVICE_NAME --no-pager
}

restart_tunnel() {
    echo -e "${YELLOW}[*] Restarting tunnel...${NC}"
    systemctl restart $SERVICE_NAME
    echo -e "${GREEN}[✓] Tunnel restarted!${NC}"
}

stop_tunnel() {
    echo -e "${YELLOW}[*] Stopping tunnel...${NC}"
    systemctl stop $SERVICE_NAME
    echo -e "${GREEN}[✓] Tunnel stopped!${NC}"
}

start_tunnel() {
    echo -e "${YELLOW}[*] Starting tunnel...${NC}"
    systemctl start $SERVICE_NAME
    echo -e "${GREEN}[✓] Tunnel started!${NC}"
}

view_logs() {
    echo -e "${CYAN}[Live Logs] Press Ctrl+C to exit${NC}"
    journalctl -u $SERVICE_NAME -f
}

delete_tunnel() {
    echo -e "${RED}[!] This will delete all tunnel configuration!${NC}"
    read -p "Are you sure? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop $SERVICE_NAME 2>/dev/null
        systemctl disable $SERVICE_NAME 2>/dev/null
        rm -f $SERVICE_FILE
        rm -rf $CONFIG_DIR
        systemctl daemon-reload
        echo -e "${GREEN}[✓] Tunnel deleted!${NC}"
    else
        echo -e "${YELLOW}[*] Cancelled.${NC}"
    fi
}

show_info() {
    if [ -f "$CONFIG_DIR/mode" ]; then
        MODE=$(cat "$CONFIG_DIR/mode")
        echo -e "${CYAN}[Tunnel Info]${NC}"
        echo -e "Mode: ${GREEN}$MODE${NC}"
        
        if [ "$MODE" == "iran" ]; then
            echo -e "Bridge Port: ${BLUE}$(cat $CONFIG_DIR/bridge_port)${NC}"
            echo -e "User Port: ${BLUE}$(cat $CONFIG_DIR/user_port)${NC}"
            if [ -f "$CONFIG_DIR/keys" ]; then
                PK=$(grep -i "Password" "$CONFIG_DIR/keys" | awk '{print $NF}')
                echo -e "Password: ${YELLOW}$PK${NC}"
            fi
        else
            echo -e "Iran Server: ${BLUE}$(cat $CONFIG_DIR/iran_addr)${NC}"
            echo -e "Destination: ${BLUE}$(cat $CONFIG_DIR/dest_addr)${NC}"
        fi
    else
        echo -e "${RED}[!] No tunnel configured.${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN MENU
# ═══════════════════════════════════════════════════════════════

main_menu() {
    show_banner
    
    # Check if already configured
    if [ -f "$CONFIG_DIR/mode" ]; then
        MODE=$(cat "$CONFIG_DIR/mode")
        echo -e "Current Mode: ${GREEN}$MODE${NC}"
        echo ""
        echo -e "1) ${GREEN}Show Status${NC}"
        echo -e "2) ${BLUE}Restart Tunnel${NC}"
        echo -e "3) ${YELLOW}Stop Tunnel${NC}"
        echo -e "4) ${GREEN}Start Tunnel${NC}"
        echo -e "5) ${CYAN}View Live Logs${NC}"
        echo -e "6) ${BLUE}Show Info${NC}"
        echo -e "7) ${RED}Delete Tunnel${NC}"
        echo -e "8) ${YELLOW}Reconfigure${NC}"
        echo -e "0) Exit"
        echo ""
        read -p "Select option: " choice
        
        case $choice in
            1) show_status ;;
            2) restart_tunnel ;;
            3) stop_tunnel ;;
            4) start_tunnel ;;
            5) view_logs ;;
            6) show_info ;;
            7) delete_tunnel ;;
            8) setup_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
    else
        setup_menu
    fi
}

setup_menu() {
    echo -e "Select server type:"
    echo -e "1) ${GREEN}Iran Server${NC} (Portal - Users connect here)"
    echo -e "2) ${BLUE}Foreign Server${NC} (Bridge - Connects to Iran)"
    echo -e "0) Exit"
    echo ""
    read -p "Select: " server_type
    
    case $server_type in
        1) setup_iran ;;
        2) setup_foreign ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════════

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

main_menu

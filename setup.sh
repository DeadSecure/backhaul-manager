#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/DaggerConnect"
SYSTEMD_DIR="/etc/systemd/system"

# Repo Info - Updated to new repo
GITHUB_REPO="https://github.com/alireza-2030/backhaul-manager"
BINARY_URL="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/DaggerConnect"

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "    ____                                 ______                            _   "
    echo "   / __ \____ _____  ____ ____  _____   / ____/___  ____  ____  ___  _____/ |_ "
    echo "  / / / / __ \`/ __ \/ __ \`/ _ \/ ___/  / /   / __ \/ __ \/ __ \/ _ \/ ___/ __/ "
    echo " / /_/ / /_/ / /_/ / /_/ /  __/ /     / /___/ /_/ / / / / / / /  __/ /__/ /_   "
    echo "/_____/\__,_/\__, /\__, /\___/_/      \____/\____/_/ /_/_/ /_/\___/\___/\__/   "
    echo "            /____//____/                                                       "
    echo -e "${NC}"
    echo -e "${BLUE}   Developed by @DaggerConnect Team (Rebuilt by @Antigravity)${NC}"
    echo -e "${YELLOW}   Version: 1.3.0 (Clean - No License)${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ This script must be run as root${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}📦 Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt update -qq
        apt install -y wget curl tar git openssl iproute2 > /dev/null 2>&1 || { echo -e "${RED}Failed to install dependencies${NC}"; exit 1; }
    elif command -v yum &>/dev/null; then
        yum install -y wget curl tar git openssl iproute2 > /dev/null 2>&1 || { echo -e "${RED}Failed to install dependencies${NC}"; exit 1; }
    else
        echo -e "${RED}❌ Unsupported package manager${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Dependencies installed${NC}"
}

get_current_version() {
    if [ -f "$INSTALL_DIR/DaggerConnect" ]; then
        VERSION=$("$INSTALL_DIR/DaggerConnect" -v 2>&1 | grep -oP 'v\d+\.\d+' || echo "unknown")
        echo "$VERSION"
    else
        echo "not-installed"
    fi
}

download_binary() {
    echo -e "${YELLOW}⬇️  Downloading DaggerConnect binary...${NC}"
    mkdir -p "$INSTALL_DIR"

    if [ -f "$INSTALL_DIR/DaggerConnect" ]; then
        mv "$INSTALL_DIR/DaggerConnect" "$INSTALL_DIR/DaggerConnect.backup"
    fi

    # Download directly from raw github content (Clean version)
    if curl -L --progress-bar "$BINARY_URL" -o "$INSTALL_DIR/DaggerConnect"; then
        chmod +x "$INSTALL_DIR/DaggerConnect"
        echo -e "${GREEN}✓ DaggerConnect downloaded successfully${NC}"

        if "$INSTALL_DIR/DaggerConnect" -v &>/dev/null; then
            VERSION=$("$INSTALL_DIR/DaggerConnect" -v 2>&1 | grep -oP 'v\d+\.\d+' || echo "1.3.0")
            echo -e "${CYAN}ℹ️  Installed version: $VERSION${NC}"
        fi

        rm -f "$INSTALL_DIR/DaggerConnect.backup"
    else
        echo -e "${RED}✖ Failed to download DaggerConnect binary${NC}"
        echo -e "${YELLOW}Check your internet connection${NC}"

        if [ -f "$INSTALL_DIR/DaggerConnect.backup" ]; then
            mv "$INSTALL_DIR/DaggerConnect.backup" "$INSTALL_DIR/DaggerConnect"
            echo -e "${YELLOW}⚠️  Restored previous version${NC}"
        fi
        exit 1
    fi
}

# ============================================================================
# SYSTEM OPTIMIZER
# ============================================================================

optimize_system() {
    local LOCATION=$1  # "iran" or "foreign"

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SYSTEM OPTIMIZATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Optimizing system for: ${GREEN}${LOCATION^^}${NC}"
    echo ""

    # Detect network interface
    INTERFACE=$(ip link show | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    if [ -z "$INTERFACE" ]; then
        INTERFACE="eth0"
        echo -e "${YELLOW}⚠️  Could not detect interface, using: $INTERFACE${NC}"
    else
        echo -e "${GREEN}✓ Detected interface: $INTERFACE${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Applying TCP optimizations...${NC}"

    # Anti-jitter & Low-latency TCP settings
    sysctl -w net.core.rmem_max=8388608 > /dev/null 2>&1
    sysctl -w net.core.wmem_max=8388608 > /dev/null 2>&1
    sysctl -w net.core.rmem_default=131072 > /dev/null 2>&1
    sysctl -w net.core.wmem_default=131072 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_rmem="4096 65536 8388608" > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 8388608" > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_sack=1 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_retries2=6 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_syn_retries=2 > /dev/null 2>&1

    sysctl -w net.core.netdev_max_backlog=1000 > /dev/null 2>&1
    sysctl -w net.core.somaxconn=512 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_low_latency=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_no_metrics_save=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_autocorking=0 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_mtu_probing=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_base_mss=1024 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_keepalive_time=120 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=3 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_fin_timeout=15 > /dev/null 2>&1

    echo -e "${GREEN}✓ TCP settings optimized${NC}"

    # BBR Congestion Control
    echo ""
    echo -e "${YELLOW}Configuring BBR congestion control...${NC}"
    if modprobe tcp_bbr 2>/dev/null; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq_codel > /dev/null 2>&1
        echo -e "${GREEN}✓ BBR enabled${NC}"
    else
        echo -e "${YELLOW}⚠️  BBR not available, using CUBIC${NC}"
    fi

    # Queue discipline (fq_codel for low latency)
    echo ""
    echo -e "${YELLOW}Configuring queue discipline...${NC}"
    tc qdisc del dev $INTERFACE root 2>/dev/null || true
    if tc qdisc add dev $INTERFACE root fq_codel limit 500 target 3ms interval 50ms quantum 300 ecn 2>/dev/null; then
        echo -e "${GREEN}✓ fq_codel queue configured${NC}"
    else
        echo -e "${YELLOW}⚠️  Could not configure qdisc (may need manual setup)${NC}"
    fi

    # Make persistent
    echo ""
    echo -e "${YELLOW}Making settings persistent...${NC}"
    cat > /etc/sysctl.d/99-daggerconnect.conf << 'EOF'
# DaggerConnect Optimizations
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=131072
net.core.wmem_default=131072

net.ipv4.tcp_rmem=4096 65536 8388608
net.ipv4.tcp_wmem=4096 65536 8388608

net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_retries2=6
net.ipv4.tcp_syn_retries=2

net.core.netdev_max_backlog=1000
net.core.somaxconn=512

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_autocorking=0

net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024

net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3

net.ipv4.tcp_fin_timeout=15

net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq_codel
EOF
    echo -e "${GREEN}✓ Settings will persist after reboot${NC}"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ System optimization complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
}

system_optimizer_menu() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SYSTEM OPTIMIZER${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Optimize for Iran Server"
    echo "  2) Optimize for Foreign Server"
    echo ""
    echo "  0) Back to Main Menu"
    echo ""
    read -p "Select option: " choice

    case $choice in
        1)
            optimize_system "iran"
            read -p "Press Enter to continue..."
            main_menu
            ;;
        2)
            optimize_system "foreign"
            read -p "Press Enter to continue..."
            main_menu
            ;;
        0) main_menu ;;
        *) system_optimizer_menu ;;
    esac
}

# ============================================================================
# AUTOMATIC CONFIGURATION
# ============================================================================

install_server_automatic() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   AUTOMATIC SERVER CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    # Only ask essential questions
    read -p "Tunnel Port [2020]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-2020}

    while true; do
        read -sp "Enter PSK (Pre-Shared Key): " PSK
        echo ""
        if [ -z "$PSK" ]; then
            echo -e "${RED}PSK cannot be empty!${NC}"
        else
            break
        fi
    done

    # Transport selection
    echo ""
    echo -e "${YELLOW}Select Transport:${NC}"
    echo "  1) httpsmux  - HTTPS Mimicry (Recommended)"
    echo "  2) httpmux   - HTTP Mimicry"
    echo "  3) wssmux    - WebSocket Secure (TLS)"
    echo "  4) wsmux     - WebSocket"
    echo "  5) kcpmux    - KCP (UDP based)"
    echo "  6) tcpmux    - Simple TCP"
    read -p "Choice [1-6]: " trans_choice
    case $trans_choice in
        1) TRANSPORT="httpsmux" ;;
        2) TRANSPORT="httpmux" ;;
        3) TRANSPORT="wssmux" ;;
        4) TRANSPORT="wsmux" ;;
        5) TRANSPORT="kcpmux" ;;
        6) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="httpsmux" ;;
    esac

    # Port mappings
    echo ""
    echo -e "${CYAN}PORT MAPPINGS${NC}"
    echo ""
    MAPPINGS=""
    COUNT=0
    while true; do
        echo ""
        echo -e "${YELLOW}Port Mapping #$((COUNT+1))${NC}"

        read -p "Bind Port (port on this server, e.g., 2222): " BIND_PORT
        if [[ ! "$BIND_PORT" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid port${NC}"
            continue
        fi

        read -p "Target Port (destination port, e.g., 22): " TARGET_PORT
        if [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid port${NC}"
            continue
        fi

        read -p "Protocol (tcp/udp/both) [tcp]: " PROTO
        PROTO=${PROTO:-tcp}

        BIND="0.0.0.0:${BIND_PORT}"
        TARGET="127.0.0.1:${TARGET_PORT}"

        case $PROTO in
            tcp)
                MAPPINGS="${MAPPINGS}  - type: tcp\n    bind: \"${BIND}\"\n    target: \"${TARGET}\"\n"
                ;;
            udp)
                MAPPINGS="${MAPPINGS}  - type: udp\n    bind: \"${BIND}\"\n    target: \"${TARGET}\"\n"
                ;;
            both)
                MAPPINGS="${MAPPINGS}  - type: tcp\n    bind: \"${BIND}\"\n    target: \"${TARGET}\"\n"
                MAPPINGS="${MAPPINGS}  - type: udp\n    bind: \"${BIND}\"\n    target: \"${TARGET}\"\n"
                ;;
        esac

        COUNT=$((COUNT+1))
        echo -e "${GREEN}✓ Mapping added: $BIND → $TARGET ($PROTO)${NC}"

        read -p "Add another mapping? [y/N]: " more
        [[ ! $more =~ ^[Yy]$ ]] && break
    done

    # Generate SSL cert if needed
    CERT_FILE=""
    KEY_FILE=""
    if [ "$TRANSPORT" == "httpsmux" ] || [ "$TRANSPORT" == "wssmux" ]; then
        echo ""
        echo -e "${YELLOW}Generating SSL certificate...${NC}"
        read -p "Domain for certificate [www.google.com]: " CERT_DOMAIN
        CERT_DOMAIN=${CERT_DOMAIN:-www.google.com}

        mkdir -p "$CONFIG_DIR/certs"
        openssl req -x509 -newkey rsa:4096 -keyout "$CONFIG_DIR/certs/key.pem" \
            -out "$CONFIG_DIR/certs/cert.pem" -days 365 -nodes \
            -subj "/C=US/ST=California/L=San Francisco/O=MyCompany/CN=${CERT_DOMAIN}" \
            2>/dev/null

        CERT_FILE="$CONFIG_DIR/certs/cert.pem"
        KEY_FILE="$CONFIG_DIR/certs/key.pem"
        echo -e "${GREEN}✓ Certificate generated${NC}"
    fi

    mkdir -p "$CONFIG_DIR"
    # Write optimized config
    CONFIG_FILE="$CONFIG_DIR/server.yaml"
    cat > "$CONFIG_FILE" << EOF
mode: "server"
listen: "0.0.0.0:${LISTEN_PORT}"
transport: "${TRANSPORT}"
psk: "${PSK}"
profile: "latency"
verbose: true

heartbeat: 2

EOF

    if [[ -n "$CERT_FILE" ]]; then
        cat >> "$CONFIG_FILE" << EOF
cert_file: "$CERT_FILE"
key_file: "$KEY_FILE"

EOF
    fi

    echo -e "maps:\n$MAPPINGS" >> "$CONFIG_FILE"

    cat >> "$CONFIG_FILE" << 'EOF'

smux:
  keepalive: 1
  max_recv: 524288
  max_stream: 524288
  frame_size: 2048
  version: 2

kcp:
  nodelay: 1
  interval: 5
  resend: 2
  nc: 1
  sndwnd: 256
  rcvwnd: 256
  mtu: 1200

advanced:
  tcp_nodelay: true
  tcp_keepalive: 3
  tcp_read_buffer: 32768
  tcp_write_buffer: 32768
  websocket_read_buffer: 16384
  websocket_write_buffer: 16384
  websocket_compression: false
  cleanup_interval: 1
  session_timeout: 15
  connection_timeout: 20
  stream_timeout: 45
  max_connections: 300
  max_udp_flows: 150
  udp_flow_timeout: 90
  udp_buffer_size: 262144

obfuscation:
  enabled: true
  min_padding: 8
  max_padding: 32
  min_delay_ms: 0
  max_delay_ms: 0
  burst_chance: 0

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  chunked_encoding: false
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"
EOF

    create_systemd_service "server"

    # Optimize system
    echo ""
    read -p "Optimize system now? [Y/n]: " opt
    if [[ ! $opt =~ ^[Nn]$ ]]; then
        optimize_system "iran"
    fi

    systemctl start DaggerConnect-server
    systemctl enable DaggerConnect-server

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ Server configured (Optimized)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "  Tunnel Port: ${GREEN}${LISTEN_PORT}${NC}"
    echo -e "  PSK: ${GREEN}${PSK}${NC}"
    echo -e "  Transport: ${GREEN}${TRANSPORT}${NC}"
    echo -e "  Config: $CONFIG_FILE"
    echo ""
    read -p "Press Enter to return..."
    main_menu
}

install_client_automatic() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   AUTOMATIC CLIENT CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    while true; do
        read -sp "Enter PSK (must match server): " PSK
        echo ""
        if [ -z "$PSK" ]; then
            echo -e "${RED}PSK cannot be empty!${NC}"
        else
            break
        fi
    done

    echo ""
    echo -e "${YELLOW}Select Transport:${NC}"
    echo "  1) httpsmux  - HTTPS Mimicry (Recommended)"
    echo "  2) httpmux   - HTTP Mimicry"
    echo "  3) wssmux    - WebSocket Secure (TLS)"
    echo "  4) wsmux     - WebSocket"
    echo "  5) kcpmux    - KCP (UDP based)"
    echo "  6) tcpmux    - Simple TCP"
    read -p "Choice [1-6]: " trans_choice
    case $trans_choice in
        1) TRANSPORT="httpsmux" ;;
        2) TRANSPORT="httpmux" ;;
        3) TRANSPORT="wssmux" ;;
        4) TRANSPORT="wsmux" ;;
        5) TRANSPORT="kcpmux" ;;
        6) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="httpsmux" ;;
    esac

    read -p "Server address with port (e.g., 1.2.3.4:2020): " ADDR
    if [ -z "$ADDR" ]; then
        echo -e "${RED}Address cannot be empty!${NC}"
        install_client_automatic
        return
    fi

    mkdir -p "$CONFIG_DIR"
    # Write optimized config
    CONFIG_FILE="$CONFIG_DIR/client.yaml"
    cat > "$CONFIG_FILE" << EOF
mode: "client"
psk: "${PSK}"
profile: "latency"
verbose: true

heartbeat: 2

paths:
  - transport: "${TRANSPORT}"
    addr: "${ADDR}"
    connection_pool: 3
    aggressive_pool: true
    retry_interval: 1
    dial_timeout: 5

smux:
  keepalive: 1
  max_recv: 524288
  max_stream: 524288
  frame_size: 2048
  version: 2

kcp:
  nodelay: 1
  interval: 5
  resend: 2
  nc: 1
  sndwnd: 256
  rcvwnd: 256
  mtu: 1200

advanced:
  tcp_nodelay: true
  tcp_keepalive: 3
  tcp_read_buffer: 32768
  tcp_write_buffer: 32768
  websocket_read_buffer: 16384
  websocket_write_buffer: 16384
  websocket_compression: false
  cleanup_interval: 1
  session_timeout: 15
  connection_timeout: 20
  stream_timeout: 45
  max_connections: 300
  max_udp_flows: 150
  udp_flow_timeout: 90
  udp_buffer_size: 262144

obfuscation:
  enabled: true
  min_padding: 8
  max_padding: 32
  min_delay_ms: 0
  max_delay_ms: 0
  burst_chance: 0

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  chunked_encoding: false
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"
EOF

    create_systemd_service "client"

    # Optimize system
    echo ""
    read -p "Optimize system now? [Y/n]: " opt
    if [[ ! $opt =~ ^[Nn]$ ]]; then
        optimize_system "foreign"
    fi

    systemctl start DaggerConnect-client
    systemctl enable DaggerConnect-client

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ Client configured (Optimized)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "  Server: ${GREEN}${ADDR}${NC}"
    echo -e "  Transport: ${GREEN}${TRANSPORT}${NC}"
    echo -e "  Config: $CONFIG_FILE"
    echo ""
    read -p "Press Enter to return..."
    main_menu
}

# ============================================================================
# UTILITIES
# ============================================================================

update_binary() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      UPDATE DaggerConnect CORE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    CURRENT_VERSION=$(get_current_version)

    if [ "$CURRENT_VERSION" == "not-installed" ]; then
        echo -e "${RED}❌ DaggerConnect is not installed yet${NC}"
        echo ""
        read -p "Press Enter to return to menu..."
        main_menu
        return
    fi

    echo -e "${CYAN}Current Version: ${GREEN}$CURRENT_VERSION${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  This will:${NC}"
    echo "  - Stop all running services"
    echo "  - Download latest Clean version"
    echo "  - Restart services automatically"
    echo ""
    read -p "Continue with update? [y/N]: " confirm

    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        main_menu
        return
    fi

    echo ""
    echo -e "${YELLOW}Stopping services...${NC}"
    systemctl stop DaggerConnect-server 2>/dev/null
    systemctl stop DaggerConnect-client 2>/dev/null
    sleep 2

    # Force re-download
    rm -f "$INSTALL_DIR/DaggerConnect"
    download_binary

    NEW_VERSION=$(get_current_version)

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ Update completed successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "  Previous Version: ${YELLOW}$CURRENT_VERSION${NC}"
    echo -e "  Current Version:  ${GREEN}$NEW_VERSION${NC}"
    echo ""

    if systemctl is-enabled DaggerConnect-server &>/dev/null || systemctl is-enabled DaggerConnect-client &>/dev/null; then
        read -p "Restart services now? [Y/n]: " restart
        if [[ ! $restart =~ ^[Nn]$ ]]; then
            echo ""
            if systemctl is-enabled DaggerConnect-server &>/dev/null; then
                systemctl start DaggerConnect-server
                echo -e "${GREEN}✓ Server restarted${NC}"
            fi
            if systemctl is-enabled DaggerConnect-client &>/dev/null; then
                systemctl start DaggerConnect-client
                echo -e "${GREEN}✓ Client restarted${NC}"
            fi
        fi
    fi

    echo ""
    read -p "Press Enter to return to menu..."
    main_menu
}

generate_ssl_cert() {
    echo -e "${YELLOW}Generating self-signed SSL certificate...${NC}"

    read -p "Domain name for certificate (e.g., www.google.com): " CERT_DOMAIN
    CERT_DOMAIN=${CERT_DOMAIN:-www.google.com}

    mkdir -p "$CONFIG_DIR/certs"

    openssl req -x509 -newkey rsa:4096 -keyout "$CONFIG_DIR/certs/key.pem" \
        -out "$CONFIG_DIR/certs/cert.pem" -days 365 -nodes \
        -subj "/C=US/ST=California/L=San Francisco/O=MyCompany/CN=${CERT_DOMAIN}" \
        2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ SSL certificate generated${NC}"
        echo -e "  Certificate: $CONFIG_DIR/certs/cert.pem"
        echo -e "  Private Key: $CONFIG_DIR/certs/key.pem"
    else
        echo -e "${RED}✖ Failed to generate certificate${NC}"
    fi
    read -p "Press Enter..."
    main_menu
}

create_systemd_service() {
    local MODE=$1
    local SERVICE_NAME="DaggerConnect-${MODE}"
    local SERVICE_FILE="$SYSTEMD_DIR/${SERVICE_NAME}.service"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Reverse Tunnel ${MODE^}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$INSTALL_DIR/DaggerConnect -c $CONFIG_DIR/${MODE}.yaml
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}✓ Systemd service for ${MODE^} created: ${SERVICE_NAME}.service${NC}"
}

service_manager() {
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SERVICE MANAGER${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Start Services"
    echo "  2) Stop Services"
    echo "  3) Restart Services"
    echo "  4) Check Status"
    echo "  5) View Logs"
    echo ""
    echo "  0) Back to Main Menu"
    echo ""
    read -p "Select option: " choice

    case $choice in
        1)
            systemctl start DaggerConnect-server 2>/dev/null
            systemctl start DaggerConnect-client 2>/dev/null
            echo -e "${GREEN}✓ Services started${NC}"
            ;;
        2)
            systemctl stop DaggerConnect-server 2>/dev/null
            systemctl stop DaggerConnect-client 2>/dev/null
            echo -e "${RED}✓ Services stopped${NC}"
            ;;
        3)
            systemctl restart DaggerConnect-server 2>/dev/null
            systemctl restart DaggerConnect-client 2>/dev/null
            echo -e "${GREEN}✓ Services restarted${NC}"
            ;;
        4)
            systemctl status DaggerConnect-server DaggerConnect-client
            ;;
        5)
            journalctl -u DaggerConnect-server -u DaggerConnect-client -n 50 -f
            ;;
        0) main_menu ;;
        *) service_manager ;;
    esac
    read -p "Press Enter..."
    main_menu
}

uninstall_dagger() {
    echo -e "${RED}⚠️  WARNING: This will remove DaggerConnect and all configs!${NC}"
    read -p "Are you sure? [y/N]: " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        systemctl stop DaggerConnect-server 2>/dev/null
        systemctl disable DaggerConnect-server 2>/dev/null
        systemctl stop DaggerConnect-client 2>/dev/null
        systemctl disable DaggerConnect-client 2>/dev/null
        rm -f /etc/systemd/system/DaggerConnect*.service
        systemctl daemon-reload
        rm -rf "$INSTALL_DIR/DaggerConnect"
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}✓ DaggerConnect uninstalled successfully${NC}"
    else
        echo -e "${YELLOW}Cancelled${NC}"
    fi
    exit 0
}

# ============================================================================
# MAIN MENU
# ============================================================================

main_menu() {
    show_banner
    
    # Check installation status
    if [ -f "$INSTALL_DIR/DaggerConnect" ]; then
        STATUS="${GREEN}INSTALLED${NC}"
        VER=$("$INSTALL_DIR/DaggerConnect" -v 2>&1 | grep -oP 'v\d+\.\d+' || echo "unknown")
    else
        STATUS="${RED}NOT INSTALLED${NC}"
        VER="-"
    fi

    echo -e "Status: $STATUS  |  Version: $VER"
    echo -e "${BLUE}_____________________________${NC}"
    echo ""
    echo "  1) Install / Reinstall Core"
    echo "  2) Automatic Server Setup (Iran)"
    echo "  3) Automatic Client Setup (Kharej)"
    echo "  4) System Optimizer"
    echo "  5) Service Manager (Logs, Start, Stop)"
    echo "  6) Update Core"
    echo "  7) Generate SSL Certificate"
    echo "  8) Uninstall DaggerConnect"
    echo ""
    echo "  0) Exit"
    echo ""
    
    read -p "Select option: " option

    case $option in
        1) 
            install_dependencies
            download_binary
            read -p "Press Enter..."
            main_menu
            ;;
        2) install_server_automatic ;;
        3) install_client_automatic ;;
        4) system_optimizer_menu ;;
        5) service_manager ;;
        6) update_binary ;;
        7) generate_ssl_cert ;;
        8) uninstall_dagger ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

# Entry point
check_root
if [[ $# -gt 0 ]]; then
    # Handle arguments if needed usually just open menu
    main_menu
else
    main_menu
fi

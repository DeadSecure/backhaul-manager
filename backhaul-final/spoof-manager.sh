#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  SPOOF TUNNEL MANAGER — ParsaKSH                              ║
# ║  Automated Setup & Management for spoof-tunnel                 ║
# ║  Supports: ICMP (Echo/Reply) + UDP                             ║
# ╚════════════════════════════════════════════════════════════════╝

# ═══════════════════════════════════════════════════════════════
# COLORS & PATHS
# ═══════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/spoof-tunnel"
SERVICE_NAME="spoof-tunnel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BINARY_NAME="spoof"
BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
GITHUB_REPO="ParsaKSH/spoof-tunnel"
MIRROR_URL="http://79.175.188.86:8090/spoof-tunnel"

# ═══════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║       SPOOF TUNNEL MANAGER — ParsaKSH v1.0.3            ║"
    echo "║       ICMP (Echo/Reply) + UDP | IP Spoofing              ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

get_latest_version() {
    # Try GitHub first, then mirror
    local version=$(curl -s --max-time 5 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    if [ -z "$version" ]; then
        version=$(curl -s --max-time 5 "${MIRROR_URL}/latest.txt" 2>/dev/null | tr -d '\n\r')
    fi
    echo "$version"
}

get_server_ip() {
    curl -s --max-time 5 icanhazip.com 2>/dev/null \
        || curl -s --max-time 5 ifconfig.me 2>/dev/null \
        || hostname -I 2>/dev/null | awk '{print $1}'
}

press_enter() {
    echo ""
    read -p "Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════════
# INSTALL / UPDATE
# ═══════════════════════════════════════════════════════════════

# $1 = download mode: "iran", "foreign", or empty (ask user)
install_binary() {
    local dl_mode="$1"

    echo -e "${YELLOW}[*] Detecting architecture...${NC}"
    local arch=$(detect_arch)
    if [ -z "$arch" ]; then
        echo -e "${RED}[!] Unsupported architecture: $(uname -m)${NC}"
        return 1
    fi
    echo -e "${GREEN}[+] Architecture: ${arch}${NC}"

    echo -e "${YELLOW}[*] Fetching latest version...${NC}"
    local version=$(get_latest_version)
    if [ -z "$version" ]; then
        echo -e "${RED}[!] Could not fetch latest version${NC}"
        read -p "Enter version (e.g. v1.0.3): " version
    fi
    echo -e "${GREEN}[+] Version: ${version}${NC}"

    local filename="spoof-linux-${arch}"
    local downloaded=false

    # Auto-select source based on mode, or ask user
    if [ -z "$dl_mode" ]; then
        echo ""
        echo -e "${CYAN}Where is this server located?${NC}"
        echo -e "  1) ${GREEN}Iran${NC}    — Download from Iran Mirror (fast)"
        echo -e "  2) ${BLUE}Foreign${NC} — Download from GitHub (direct)"
        echo ""
        read -p "Select [1-2] (default: 1): " loc_choice
        case "$loc_choice" in
            2) dl_mode="foreign" ;;
            *) dl_mode="iran" ;;
        esac
    fi

    if [ "$dl_mode" = "iran" ]; then
        # Iran: mirror first, GitHub fallback
        local mirror_url="${MIRROR_URL}/${version}/${filename}"
        echo -e "${YELLOW}[*] Downloading from Iran Mirror...${NC}"
        echo -e "${BLUE}    URL: ${mirror_url}${NC}"
        if curl -L --max-time 30 --progress-bar -o /tmp/${filename} "${mirror_url}" 2>/dev/null; then
            local fsize=$(stat -c%s /tmp/${filename} 2>/dev/null || stat -f%z /tmp/${filename} 2>/dev/null)
            if [ "${fsize:-0}" -gt 1000000 ]; then
                downloaded=true
                echo -e "${GREEN}[+] Downloaded from Iran Mirror${NC}"
            fi
        fi
        if ! $downloaded; then
            echo -e "${YELLOW}[*] Mirror failed, trying GitHub...${NC}"
            local gh_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"
            echo -e "${BLUE}    URL: ${gh_url}${NC}"
            if curl -L --progress-bar -o /tmp/${filename} "${gh_url}"; then
                downloaded=true
            fi
        fi
    else
        # Foreign: GitHub first, mirror fallback
        local gh_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"
        echo -e "${YELLOW}[*] Downloading from GitHub...${NC}"
        echo -e "${BLUE}    URL: ${gh_url}${NC}"
        if curl -L --max-time 30 --progress-bar -o /tmp/${filename} "${gh_url}" 2>/dev/null; then
            local fsize=$(stat -c%s /tmp/${filename} 2>/dev/null || stat -f%z /tmp/${filename} 2>/dev/null)
            if [ "${fsize:-0}" -gt 1000000 ]; then
                downloaded=true
                echo -e "${GREEN}[+] Downloaded from GitHub${NC}"
            fi
        fi
        if ! $downloaded; then
            echo -e "${YELLOW}[*] GitHub failed, trying Iran Mirror...${NC}"
            local mirror_url="${MIRROR_URL}/${version}/${filename}"
            echo -e "${BLUE}    URL: ${mirror_url}${NC}"
            if curl -L --progress-bar -o /tmp/${filename} "${mirror_url}"; then
                downloaded=true
            fi
        fi
    fi

    if $downloaded; then
        chmod +x /tmp/${filename}
        mv /tmp/${filename} ${BINARY_PATH}
        mkdir -p ${CONFIG_DIR}
        echo -e "${GREEN}[+] Installed to ${BINARY_PATH}${NC}"
        echo "${version}" > ${CONFIG_DIR}/version
    else
        echo -e "${RED}[!] Download failed from all sources!${NC}"
        echo -e "${YELLOW}    Download manually and place at: ${BINARY_PATH}${NC}"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# KEY GENERATION
# ═══════════════════════════════════════════════════════════════

generate_keys() {
    if [ ! -f "${BINARY_PATH}" ]; then
        echo -e "${RED}[!] Binary not found! Install first.${NC}"
        return 1
    fi

    echo -e "${CYAN}[*] Generating cryptographic keys...${NC}"
    echo ""

    local output=$(${BINARY_PATH} keygen 2>&1)
    echo -e "${GREEN}${output}${NC}"

    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  IMPORTANT: Save these keys!                             ║${NC}"
    echo -e "${YELLOW}║  Server's Public Key → Client's peer_public_key          ║${NC}"
    echo -e "${YELLOW}║  Client's Public Key → Server's peer_public_key          ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# TRANSPORT SELECTION
# ═══════════════════════════════════════════════════════════════

select_transport() {
    echo ""
    echo -e "${CYAN}Select Transport Type:${NC}"
    echo -e "  1) ${GREEN}ICMP Echo${NC}  — Traffic looks like ping (recommended)"
    echo -e "  2) ${BLUE}ICMP Reply${NC} — Traffic looks like ping reply"
    echo -e "  3) ${MAGENTA}UDP${NC}        — Standard UDP datagrams"
    echo ""
    read -p "Select [1-3] (default: 1): " transport_choice

    case "$transport_choice" in
        2)
            TRANSPORT_TYPE="icmp"
            ICMP_MODE="reply"
            echo -e "${GREEN}[+] Selected: ICMP Reply mode${NC}"
            ;;
        3)
            TRANSPORT_TYPE="udp"
            ICMP_MODE="echo"
            echo -e "${GREEN}[+] Selected: UDP mode${NC}"
            ;;
        *)
            TRANSPORT_TYPE="icmp"
            ICMP_MODE="echo"
            echo -e "${GREEN}[+] Selected: ICMP Echo mode (default)${NC}"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# SERVER SETUP (IRAN)
# ═══════════════════════════════════════════════════════════════

setup_server() {
    echo -e "${GREEN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║              SERVER SETUP (IRAN SIDE)                    ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Transport
    select_transport

    # Listen
    local default_ip=$(get_server_ip)
    read -p "Listen Address (default: 0.0.0.0): " LISTEN_ADDR
    LISTEN_ADDR=${LISTEN_ADDR:-"0.0.0.0"}

    local listen_port=8080
    if [ "$TRANSPORT_TYPE" = "udp" ]; then
        read -p "Listen Port (default: 8080): " listen_port_input
        listen_port=${listen_port_input:-8080}
    fi

    # Spoof IPs
    echo ""
    echo -e "${CYAN}--- Spoof Configuration ---${NC}"
    echo -e "${YELLOW}  source_ip     = IP this server CLAIMS when sending packets${NC}"
    echo -e "${YELLOW}  peer_spoof_ip = Expected spoof IP of incoming CLIENT packets${NC}"
    echo -e "${YELLOW}  client_real_ip= Client's ACTUAL real IP (for routing replies)${NC}"
    echo ""

    read -p "Server Spoof Source IP (source_ip): " SPOOF_SRC_IP
    while [ -z "$SPOOF_SRC_IP" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Server Spoof Source IP (source_ip): " SPOOF_SRC_IP
    done

    read -p "Expected Client Spoof IP (peer_spoof_ip): " PEER_SPOOF_IP
    while [ -z "$PEER_SPOOF_IP" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Expected Client Spoof IP (peer_spoof_ip): " PEER_SPOOF_IP
    done

    read -p "Client Real IP (client_real_ip): " CLIENT_REAL_IP
    while [ -z "$CLIENT_REAL_IP" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Client Real IP (client_real_ip): " CLIENT_REAL_IP
    done

    # Crypto
    echo ""
    echo -e "${CYAN}--- Crypto Keys ---${NC}"
    echo -e "${YELLOW}  Run 'Generate Keys' option from menu to create keys${NC}"
    echo ""

    read -p "Server Private Key (Base64): " SERVER_PRIV_KEY
    while [ -z "$SERVER_PRIV_KEY" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Server Private Key (Base64): " SERVER_PRIV_KEY
    done

    read -p "Client Public Key (peer_public_key, Base64): " CLIENT_PUB_KEY
    while [ -z "$CLIENT_PUB_KEY" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Client Public Key (peer_public_key, Base64): " CLIENT_PUB_KEY
    done

    # Performance defaults
    echo ""
    echo -e "${CYAN}--- Performance (Enter for defaults) ---${NC}"
    read -p "Workers (default: 16): " WORKERS
    WORKERS=${WORKERS:-16}
    read -p "MTU (default: 1400): " MTU
    MTU=${MTU:-1400}
    read -p "Session Timeout seconds (default: 600): " SESSION_TIMEOUT
    SESSION_TIMEOUT=${SESSION_TIMEOUT:-600}

    # FEC
    echo ""
    read -p "Enable FEC (Forward Error Correction)? [Y/n]: " fec_choice
    FEC_ENABLED=true
    [[ "$fec_choice" =~ ^[Nn]$ ]] && FEC_ENABLED=false

    # Generate config
    mkdir -p ${CONFIG_DIR}

    cat > ${CONFIG_DIR}/config.json << SERVEOF
{
  "mode": "server",
  "transport": {
    "type": "${TRANSPORT_TYPE}",
    "icmp_mode": "${ICMP_MODE}",
    "protocol_number": 0
  },
  "listen": {
    "address": "${LISTEN_ADDR}",
    "port": ${listen_port}
  },
  "spoof": {
    "source_ip": "${SPOOF_SRC_IP}",
    "source_ipv6": "",
    "peer_spoof_ip": "${PEER_SPOOF_IP}",
    "peer_spoof_ipv6": "",
    "client_real_ip": "${CLIENT_REAL_IP}",
    "client_real_ipv6": ""
  },
  "crypto": {
    "private_key": "${SERVER_PRIV_KEY}",
    "peer_public_key": "${CLIENT_PUB_KEY}"
  },
  "performance": {
    "buffer_size": 131072,
    "mtu": ${MTU},
    "session_timeout": ${SESSION_TIMEOUT},
    "workers": ${WORKERS},
    "read_buffer": 16777216,
    "write_buffer": 16777216
  },
  "reliability": {
    "enabled": true,
    "window_size": 128,
    "retransmit_timeout_ms": 300,
    "max_retries": 5,
    "ack_interval_ms": 50
  },
  "fec": {
    "enabled": ${FEC_ENABLED},
    "data_shards": 10,
    "parity_shards": 3
  },
  "keepalive": {
    "enabled": true,
    "interval_seconds": 30,
    "timeout_seconds": 120
  },
  "logging": {
    "level": "info",
    "file": ""
  }
}
SERVEOF

    create_service "server"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            SERVER CONFIGURED SUCCESSFULLY!               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Transport:     ${BLUE}${TRANSPORT_TYPE} (${ICMP_MODE})${NC}"
    echo -e "  Listen:        ${BLUE}${LISTEN_ADDR}:${listen_port}${NC}"
    echo -e "  Spoof Src IP:  ${BLUE}${SPOOF_SRC_IP}${NC}"
    echo -e "  Peer Spoof IP: ${BLUE}${PEER_SPOOF_IP}${NC}"
    echo -e "  Client Real:   ${BLUE}${CLIENT_REAL_IP}${NC}"
    echo -e "  Server IP:     ${BLUE}${default_ip}${NC}"
    echo ""
    echo -e "${YELLOW}For client setup, use:${NC}"
    echo -e "  Server Address: ${CYAN}${default_ip}${NC}"
    echo ""

    echo "server" > ${CONFIG_DIR}/mode

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# CLIENT SETUP (FOREIGN)
# ═══════════════════════════════════════════════════════════════

setup_client() {
    echo -e "${BLUE}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║             CLIENT SETUP (FOREIGN SIDE)                  ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Transport
    select_transport

    # Server address
    echo ""
    echo -e "${CYAN}--- Server Connection ---${NC}"
    read -p "Iran Server Real IP: " SERVER_ADDR
    while [ -z "$SERVER_ADDR" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Iran Server Real IP: " SERVER_ADDR
    done

    local server_port=8080
    if [ "$TRANSPORT_TYPE" = "udp" ]; then
        read -p "Server Port (default: 8080): " server_port_input
        server_port=${server_port_input:-8080}
    fi

    # SOCKS5 Listen
    echo ""
    echo -e "${CYAN}--- SOCKS5 Proxy ---${NC}"
    read -p "SOCKS5 Listen Address (default: 127.0.0.1): " SOCKS_ADDR
    SOCKS_ADDR=${SOCKS_ADDR:-"127.0.0.1"}
    read -p "SOCKS5 Listen Port (default: 1080): " SOCKS_PORT
    SOCKS_PORT=${SOCKS_PORT:-1080}

    # Spoof IPs
    echo ""
    echo -e "${CYAN}--- Spoof Configuration ---${NC}"
    echo -e "${YELLOW}  source_ip     = IP this client CLAIMS when sending packets${NC}"
    echo -e "${YELLOW}  peer_spoof_ip = Expected spoof IP of incoming SERVER packets${NC}"
    echo ""

    read -p "Client Spoof Source IP (source_ip): " SPOOF_SRC_IP
    while [ -z "$SPOOF_SRC_IP" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Client Spoof Source IP (source_ip): " SPOOF_SRC_IP
    done

    read -p "Expected Server Spoof IP (peer_spoof_ip): " PEER_SPOOF_IP
    while [ -z "$PEER_SPOOF_IP" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Expected Server Spoof IP (peer_spoof_ip): " PEER_SPOOF_IP
    done

    # Crypto
    echo ""
    echo -e "${CYAN}--- Crypto Keys ---${NC}"
    read -p "Client Private Key (Base64): " CLIENT_PRIV_KEY
    while [ -z "$CLIENT_PRIV_KEY" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Client Private Key (Base64): " CLIENT_PRIV_KEY
    done

    read -p "Server Public Key (peer_public_key, Base64): " SERVER_PUB_KEY
    while [ -z "$SERVER_PUB_KEY" ]; do
        echo -e "${RED}[!] This field is required${NC}"
        read -p "Server Public Key (peer_public_key, Base64): " SERVER_PUB_KEY
    done

    # Performance
    echo ""
    echo -e "${CYAN}--- Performance (Enter for defaults) ---${NC}"
    read -p "Workers (default: 4): " WORKERS
    WORKERS=${WORKERS:-4}
    read -p "MTU (default: 1400): " MTU
    MTU=${MTU:-1400}
    read -p "Session Timeout seconds (default: 90): " SESSION_TIMEOUT
    SESSION_TIMEOUT=${SESSION_TIMEOUT:-90}

    # FEC
    echo ""
    read -p "Enable FEC (Forward Error Correction)? [y/N]: " fec_choice
    FEC_ENABLED=false
    [[ "$fec_choice" =~ ^[Yy]$ ]] && FEC_ENABLED=true

    # Generate config
    mkdir -p ${CONFIG_DIR}

    cat > ${CONFIG_DIR}/config.json << CLIENTEOF
{
  "mode": "client",
  "transport": {
    "type": "${TRANSPORT_TYPE}",
    "icmp_mode": "${ICMP_MODE}",
    "protocol_number": 0
  },
  "listen": {
    "address": "${SOCKS_ADDR}",
    "port": ${SOCKS_PORT}
  },
  "server": {
    "address": "${SERVER_ADDR}",
    "port": ${server_port}
  },
  "spoof": {
    "source_ip": "${SPOOF_SRC_IP}",
    "peer_spoof_ip": "${PEER_SPOOF_IP}"
  },
  "crypto": {
    "private_key": "${CLIENT_PRIV_KEY}",
    "peer_public_key": "${SERVER_PUB_KEY}"
  },
  "performance": {
    "buffer_size": 65535,
    "mtu": ${MTU},
    "session_timeout": ${SESSION_TIMEOUT},
    "workers": ${WORKERS},
    "read_buffer": 4194304,
    "write_buffer": 4194304
  },
  "fec": {
    "enabled": ${FEC_ENABLED},
    "data_shards": 10,
    "parity_shards": 3
  },
  "logging": {
    "level": "info",
    "file": ""
  }
}
CLIENTEOF

    create_service "client"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            CLIENT CONFIGURED SUCCESSFULLY!               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Transport:     ${BLUE}${TRANSPORT_TYPE} (${ICMP_MODE})${NC}"
    echo -e "  Server:        ${BLUE}${SERVER_ADDR}:${server_port}${NC}"
    echo -e "  SOCKS5:        ${BLUE}${SOCKS_ADDR}:${SOCKS_PORT}${NC}"
    echo -e "  Spoof Src IP:  ${BLUE}${SPOOF_SRC_IP}${NC}"
    echo -e "  Peer Spoof IP: ${BLUE}${PEER_SPOOF_IP}${NC}"
    echo ""
    echo -e "${YELLOW}SOCKS5 proxy will be available at: ${CYAN}${SOCKS_ADDR}:${SOCKS_PORT}${NC}"
    echo ""

    echo "client" > ${CONFIG_DIR}/mode

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# SYSTEMD SERVICE
# ═══════════════════════════════════════════════════════════════

create_service() {
    local mode=$1

    cat > ${SERVICE_FILE} << SVCEOF
[Unit]
Description=Spoof Tunnel Service (${mode})
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} -c ${CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} &>/dev/null
    systemctl restart ${SERVICE_NAME}

    sleep 1
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${GREEN}[+] Service is running!${NC}"
    else
        echo -e "${RED}[!] Service failed to start. Check logs:${NC}"
        echo -e "${YELLOW}    journalctl -u ${SERVICE_NAME} -n 20${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════
# SERVICE MANAGEMENT
# ═══════════════════════════════════════════════════════════════

show_status() {
    echo -e "${CYAN}[Service Status]${NC}"
    echo ""
    systemctl status ${SERVICE_NAME} --no-pager -l
    press_enter
}

start_service() {
    echo -e "${YELLOW}[*] Starting service...${NC}"
    systemctl start ${SERVICE_NAME}
    sleep 1
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${GREEN}[+] Service started!${NC}"
    else
        echo -e "${RED}[!] Failed to start${NC}"
    fi
    press_enter
}

stop_service() {
    echo -e "${YELLOW}[*] Stopping service...${NC}"
    systemctl stop ${SERVICE_NAME}
    echo -e "${GREEN}[+] Service stopped!${NC}"
    press_enter
}

restart_service() {
    echo -e "${YELLOW}[*] Restarting service...${NC}"
    systemctl restart ${SERVICE_NAME}
    sleep 1
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${GREEN}[+] Service restarted!${NC}"
    else
        echo -e "${RED}[!] Failed to restart${NC}"
    fi
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# LOGS
# ═══════════════════════════════════════════════════════════════

view_logs() {
    echo ""
    echo -e "${CYAN}[Log Options]${NC}"
    echo "  1) Live Logs (Follow)"
    echo "  2) Last 50 Lines"
    echo "  3) Last 100 Lines"
    echo "  4) Search in Logs"
    echo "  5) Export Logs to File"
    echo "  0) Back"
    echo ""
    read -p "Select: " log_choice

    case $log_choice in
        1)
            echo -e "${CYAN}[Live Logs] Press Ctrl+C to exit${NC}"
            journalctl -u ${SERVICE_NAME} -f
            ;;
        2) journalctl -u ${SERVICE_NAME} -n 50 --no-pager ;;
        3) journalctl -u ${SERVICE_NAME} -n 100 --no-pager ;;
        4)
            read -p "Search term: " search_term
            journalctl -u ${SERVICE_NAME} --no-pager | grep -i "$search_term"
            ;;
        5)
            local export_file="/tmp/spoof-tunnel-logs-$(date +%Y%m%d-%H%M%S).txt"
            journalctl -u ${SERVICE_NAME} --no-pager > ${export_file}
            echo -e "${GREEN}[+] Logs exported to: ${export_file}${NC}"
            ;;
        0) return ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# INFO & TEST
# ═══════════════════════════════════════════════════════════════

show_info() {
    if [ ! -f "${CONFIG_DIR}/mode" ]; then
        echo -e "${RED}[!] Service not configured${NC}"
        press_enter
        return
    fi

    local mode=$(cat ${CONFIG_DIR}/mode)
    local version="unknown"
    [ -f "${CONFIG_DIR}/version" ] && version=$(cat ${CONFIG_DIR}/version)

    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  SERVICE INFORMATION                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Mode:       ${GREEN}${mode}${NC}"
    echo -e "  Version:    ${BLUE}${version}${NC}"
    echo -e "  Binary:     ${BLUE}${BINARY_PATH}${NC}"
    echo -e "  Config:     ${BLUE}${CONFIG_DIR}/config.json${NC}"
    echo -e "  Service:    ${BLUE}${SERVICE_NAME}${NC}"
    echo ""

    if [ -f "${CONFIG_DIR}/config.json" ]; then
        echo -e "${CYAN}[Configuration Summary]${NC}"
        local transport=$(grep -o '"type": *"[^"]*"' ${CONFIG_DIR}/config.json | head -1 | cut -d'"' -f4)
        local icmp_mode=$(grep -o '"icmp_mode": *"[^"]*"' ${CONFIG_DIR}/config.json | cut -d'"' -f4)
        local src_ip=$(grep -o '"source_ip": *"[^"]*"' ${CONFIG_DIR}/config.json | cut -d'"' -f4)
        local peer_ip=$(grep -o '"peer_spoof_ip": *"[^"]*"' ${CONFIG_DIR}/config.json | cut -d'"' -f4)

        echo -e "  Transport:     ${BLUE}${transport} (${icmp_mode})${NC}"
        echo -e "  Spoof Src IP:  ${BLUE}${src_ip}${NC}"
        echo -e "  Peer Spoof IP: ${BLUE}${peer_ip}${NC}"

        if [ "$mode" = "server" ]; then
            local client_ip=$(grep -o '"client_real_ip": *"[^"]*"' ${CONFIG_DIR}/config.json | cut -d'"' -f4)
            echo -e "  Client Real:   ${BLUE}${client_ip}${NC}"
        else
            local server_addr=$(grep -o '"address": *"[^"]*"' ${CONFIG_DIR}/config.json | tail -1 | cut -d'"' -f4)
            echo -e "  Server Addr:   ${BLUE}${server_addr}${NC}"
        fi
    fi

    echo ""
    echo -e "${CYAN}[Service Status]${NC}"
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "  Status: ${GREEN}Active (Running)${NC}"
        local uptime=$(systemctl show ${SERVICE_NAME} -p ActiveEnterTimestamp --value 2>/dev/null)
        [ -n "$uptime" ] && echo -e "  Since:  ${BLUE}${uptime}${NC}"
    else
        echo -e "  Status: ${RED}Inactive (Stopped)${NC}"
    fi

    press_enter
}

test_connection() {
    if [ ! -f "${CONFIG_DIR}/config.json" ]; then
        echo -e "${RED}[!] Service not configured${NC}"
        press_enter
        return
    fi

    local mode=$(cat ${CONFIG_DIR}/mode 2>/dev/null)

    echo -e "${CYAN}[Testing Connection]${NC}"
    echo ""

    # Service check
    echo -n "  Spoof service: "
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${GREEN}Running${NC}"
    else
        echo -e "${RED}Stopped${NC}"
    fi

    if [ "$mode" = "client" ]; then
        # Check SOCKS5
        local socks_addr=$(grep -o '"address": *"[^"]*"' ${CONFIG_DIR}/config.json | head -1 | cut -d'"' -f4)
        local socks_port=$(grep -o '"port": *[0-9]*' ${CONFIG_DIR}/config.json | head -1 | grep -o '[0-9]*$')

        echo -n "  SOCKS5 port ${socks_port}: "
        if ss -tlnp 2>/dev/null | grep -q ":${socks_port}" || \
           netstat -tlnp 2>/dev/null | grep -q ":${socks_port}"; then
            echo -e "${GREEN}Listening${NC}"
        else
            echo -e "${RED}Not listening${NC}"
        fi

        # Ping server
        local server_ip=$(grep -o '"address": *"[^"]*"' ${CONFIG_DIR}/config.json | tail -1 | cut -d'"' -f4)
        echo -n "  Ping ${server_ip}: "
        if ping -c 2 -W 3 ${server_ip} &>/dev/null; then
            echo -e "${GREEN}Reachable${NC}"
        else
            echo -e "${RED}Unreachable${NC}"
        fi

        # SOCKS5 test
        echo -n "  SOCKS5 proxy test: "
        if command -v curl &>/dev/null; then
            local result=$(curl -s --max-time 10 --socks5 ${socks_addr}:${socks_port} icanhazip.com 2>/dev/null)
            if [ -n "$result" ]; then
                echo -e "${GREEN}Working (IP: ${result})${NC}"
            else
                echo -e "${RED}Failed${NC}"
            fi
        else
            echo -e "${YELLOW}curl not available${NC}"
        fi
    else
        echo -e "${BLUE}  Server mode — waiting for client connections${NC}"
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# CONFIG VIEW / EDIT
# ═══════════════════════════════════════════════════════════════

view_config() {
    if [ ! -f "${CONFIG_DIR}/config.json" ]; then
        echo -e "${RED}[!] No configuration found${NC}"
        press_enter
        return
    fi

    echo -e "${CYAN}[Current Configuration]${NC}"
    echo ""
    cat ${CONFIG_DIR}/config.json
    echo ""

    echo -e "${YELLOW}Options:${NC}"
    echo "  1) Edit Config"
    echo "  2) Backup Config"
    echo "  0) Back"
    read -p "Select: " config_choice

    case $config_choice in
        1)
            if command -v nano &>/dev/null; then
                nano ${CONFIG_DIR}/config.json
            elif command -v vi &>/dev/null; then
                vi ${CONFIG_DIR}/config.json
            else
                echo -e "${RED}No editor found (install nano)${NC}"
            fi
            echo -e "${YELLOW}Restart service to apply changes${NC}"
            ;;
        2)
            local backup="${CONFIG_DIR}/config.json.backup-$(date +%Y%m%d-%H%M%S)"
            cp ${CONFIG_DIR}/config.json ${backup}
            echo -e "${GREEN}[+] Backup saved to: ${backup}${NC}"
            ;;
    esac

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# DELETE SERVICE
# ═══════════════════════════════════════════════════════════════

delete_service() {
    echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                     WARNING                              ║${NC}"
    echo -e "${RED}║  This will PERMANENTLY delete spoof-tunnel config!       ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}What will be deleted:${NC}"
    echo "  - Service: ${SERVICE_NAME}"
    echo "  - Config:  ${CONFIG_DIR}/"
    echo "  - Systemd: ${SERVICE_FILE}"
    echo ""
    read -p "Type 'DELETE' to confirm: " confirm

    if [ "$confirm" = "DELETE" ]; then
        # Backup before delete
        if [ -f "${CONFIG_DIR}/config.json" ]; then
            local backup_dir="/tmp/spoof-backup-$(date +%Y%m%d-%H%M%S)"
            mkdir -p ${backup_dir}
            cp -r ${CONFIG_DIR}/* ${backup_dir}/
            echo -e "${BLUE}[i] Config backed up to: ${backup_dir}${NC}"
        fi

        systemctl stop ${SERVICE_NAME} 2>/dev/null
        systemctl disable ${SERVICE_NAME} 2>/dev/null
        rm -f ${SERVICE_FILE}
        rm -rf ${CONFIG_DIR}
        systemctl daemon-reload

        echo -e "${GREEN}[+] Service deleted successfully!${NC}"
        echo ""

        read -p "Delete binary too? (y/N): " del_bin
        if [[ "$del_bin" =~ ^[Yy]$ ]]; then
            rm -f ${BINARY_PATH}
            echo -e "${GREEN}[+] Binary deleted!${NC}"
        else
            echo -e "${BLUE}[i] Binary kept at: ${BINARY_PATH}${NC}"
        fi
    else
        echo -e "${YELLOW}[*] Cancelled. Nothing was deleted.${NC}"
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# UPDATE BINARY
# ═══════════════════════════════════════════════════════════════

update_binary() {
    echo -e "${YELLOW}[*] Checking for updates...${NC}"

    local current="unknown"
    [ -f "${CONFIG_DIR}/version" ] && current=$(cat ${CONFIG_DIR}/version)

    local latest=$(get_latest_version)
    echo -e "  Current: ${BLUE}${current}${NC}"
    echo -e "  Latest:  ${GREEN}${latest}${NC}"

    if [ "$current" = "$latest" ]; then
        echo -e "${GREEN}[+] Already up to date!${NC}"
        press_enter
        return
    fi

    echo ""
    read -p "Update to ${latest}? (Y/n): " update_choice
    if [[ "$update_choice" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}[*] Update cancelled${NC}"
        press_enter
        return
    fi

    # Stop service before update
    local was_running=false
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        was_running=true
        systemctl stop ${SERVICE_NAME}
        echo -e "${YELLOW}[*] Service stopped for update${NC}"
    fi

    install_binary

    if $was_running; then
        systemctl start ${SERVICE_NAME}
        echo -e "${GREEN}[+] Service restarted with new version${NC}"
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════
# MAIN MENU
# ═══════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        show_banner

        # Show current state
        if [ -f "${CONFIG_DIR}/config.json" ]; then
            local mode=$(cat ${CONFIG_DIR}/mode 2>/dev/null || echo "unknown")
            local version="?"
            [ -f "${CONFIG_DIR}/version" ] && version=$(cat ${CONFIG_DIR}/version)

            # Service status indicator
            local status_icon="${RED}Stopped${NC}"
            systemctl is-active --quiet ${SERVICE_NAME} && status_icon="${GREEN}Running${NC}"

            echo -e "  Mode: ${GREEN}${mode}${NC}  |  Version: ${BLUE}${version}${NC}  |  Status: ${status_icon}"
            echo ""

            echo -e "${CYAN}=== Service Management ===${NC}"
            echo -e "  1) ${GREEN}Show Status${NC}"
            echo -e "  2) ${GREEN}Start Service${NC}"
            echo -e "  3) ${YELLOW}Stop Service${NC}"
            echo -e "  4) ${BLUE}Restart Service${NC}"
            echo ""
            echo -e "${CYAN}=== Monitoring ===${NC}"
            echo -e "  5) ${CYAN}View Logs${NC}"
            echo -e "  6) ${BLUE}Test Connection${NC}"
            echo -e "  7) ${BLUE}Show Full Info${NC}"
            echo ""
            echo -e "${CYAN}=== Configuration ===${NC}"
            echo -e "  8) ${BLUE}View/Edit Config${NC}"
            echo -e "  9) ${YELLOW}Reconfigure${NC}"
            echo ""
            echo -e "${CYAN}=== Tools ===${NC}"
            echo -e "  k) ${MAGENTA}Generate New Keys${NC}"
            echo -e "  u) ${CYAN}Update Binary${NC}"
            echo -e "  d) ${RED}Delete Service${NC}"
            echo -e "  0) Exit"
            echo ""
            read -p "Select option: " choice

            case $choice in
                1) show_status ;;
                2) start_service ;;
                3) stop_service ;;
                4) restart_service ;;
                5) view_logs ;;
                6) test_connection ;;
                7) show_info ;;
                8) view_config ;;
                9) setup_menu ;;
                k|K) generate_keys ;;
                u|U) update_binary ;;
                d|D) delete_service ;;
                0) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
                *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
            esac
        else
            # First-time setup
            echo -e "${YELLOW}  No configuration found. Let's set up!${NC}"
            echo ""

            echo -e "${CYAN}=== Initial Setup ===${NC}"
            echo -e "  1) ${GREEN}Install Binary — Iran Server${NC}  (download from Mirror)"
            echo -e "  2) ${BLUE}Install Binary — Foreign Server${NC}  (download from GitHub)"
            echo -e "  3) ${MAGENTA}Generate Crypto Keys${NC}"
            echo -e "  4) ${GREEN}Setup Server (Iran)${NC}   — auto downloads from Mirror"
            echo -e "  5) ${BLUE}Setup Client (Foreign)${NC} — auto downloads from GitHub"
            echo -e "  0) Exit"
            echo ""
            read -p "Select option: " choice

            case $choice in
                1) install_binary "iran"; press_enter ;;
                2) install_binary "foreign"; press_enter ;;
                3) generate_keys ;;
                4)
                    if [ ! -f "${BINARY_PATH}" ]; then
                        echo -e "${YELLOW}[*] Binary not found. Installing from Mirror...${NC}"
                        install_binary "iran" || continue
                    fi
                    setup_server
                    ;;
                5)
                    if [ ! -f "${BINARY_PATH}" ]; then
                        echo -e "${YELLOW}[*] Binary not found. Installing from GitHub...${NC}"
                        install_binary "foreign" || continue
                    fi
                    setup_client
                    ;;
                0) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
                *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
            esac
        fi
    done
}

setup_menu() {
    echo ""
    echo -e "${CYAN}Select setup type:${NC}"
    echo -e "  1) ${GREEN}Server (Iran)${NC}"
    echo -e "  2) ${BLUE}Client (Foreign)${NC}"
    echo -e "  0) Back"
    echo ""
    read -p "Select: " server_type

    case $server_type in
        1) setup_server ;;
        2) setup_client ;;
        0) return ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═══════════════════════════════════════════════════════════════

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Please run as root (sudo)${NC}"
    exit 1
fi

main_menu

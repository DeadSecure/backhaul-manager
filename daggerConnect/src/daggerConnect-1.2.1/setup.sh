#!/bin/bash
# ═══════════════════════════════════════════════════
#  DaggerConnect Multi-Tunnel Manager
#  Supports multiple server/client tunnel instances
# ═══════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/DaggerConnect"
SYSTEMD_DIR="/etc/systemd/system"
GITHUB_REPO="https://github.com/itsFLoKi/DaggerConnect"
LATEST_RELEASE_API="https://api.github.com/repos/itsFLoKi/DaggerConnect/releases/latest"

# ═══════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════

show_banner() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}      DaggerConnect Multi-Tunnel Manager${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""
}

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}This script must be run as root${NC}"; exit 1; }
}

install_deps() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt update -qq
        apt install -y wget curl tar openssl iproute2 > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y wget curl tar openssl iproute > /dev/null 2>&1
    fi
    echo -e "${GREEN}Dependencies installed${NC}"
}

get_version() {
    if [[ -f "$INSTALL_DIR/DaggerConnect" ]]; then
        "$INSTALL_DIR/DaggerConnect" -v 2>&1 | grep -oP 'v\d+\.\d+' || echo "unknown"
    else
        echo "not-installed"
    fi
}

download_binary() {
    echo -e "${YELLOW}Downloading DaggerConnect binary...${NC}"
    mkdir -p "$INSTALL_DIR"

    LATEST=$(curl -s "$LATEST_RELEASE_API" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$LATEST" ]] && LATEST="v1.0"

    BINARY_URL="https://github.com/itsFLoKi/DaggerConnect/releases/download/${LATEST}/DaggerConnect"
    echo -e "${CYAN}Latest version: ${GREEN}${LATEST}${NC}"

    [[ -f "$INSTALL_DIR/DaggerConnect" ]] && cp "$INSTALL_DIR/DaggerConnect" "$INSTALL_DIR/DaggerConnect.backup"

    if wget -q --show-progress "$BINARY_URL" -O "$INSTALL_DIR/DaggerConnect"; then
        chmod +x "$INSTALL_DIR/DaggerConnect"
        echo -e "${GREEN}Downloaded successfully${NC}"
        rm -f "$INSTALL_DIR/DaggerConnect.backup"
    else
        echo -e "${RED}Download failed${NC}"
        [[ -f "$INSTALL_DIR/DaggerConnect.backup" ]] && mv "$INSTALL_DIR/DaggerConnect.backup" "$INSTALL_DIR/DaggerConnect"
        return 1
    fi
}

# ═══════════════════════════════════════════════════
#  TRANSPORT SELECTOR
# ═══════════════════════════════════════════════════

select_transport() {
    echo ""
    echo -e "${YELLOW}Select Transport:${NC}"
    echo "  1) httpsmux  - HTTPS Mimicry [Recommended]"
    echo "  2) httpmux   - HTTP Mimicry"
    echo "  3) wssmux    - WebSocket Secure (TLS)"
    echo "  4) wsmux     - WebSocket"
    echo "  5) kcpmux    - KCP (UDP based)"
    echo "  6) tcpmux    - Simple TCP"
    read -p "Choice [1]: " c
    case $c in
        2) TRANSPORT="httpmux" ;;
        3) TRANSPORT="wssmux" ;;
        4) TRANSPORT="wsmux" ;;
        5) TRANSPORT="kcpmux" ;;
        6) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="httpsmux" ;;
    esac
}

# ═══════════════════════════════════════════════════
#  SSL CERTIFICATE
# ═══════════════════════════════════════════════════

generate_ssl() {
    local ID=$1
    local CERT_DIR="$CONFIG_DIR/certs"
    mkdir -p "$CERT_DIR"

    read -p "Domain for certificate [www.google.com]: " DOMAIN
    DOMAIN=${DOMAIN:-www.google.com}

    openssl req -x509 -newkey rsa:4096 \
        -keyout "$CERT_DIR/key-${ID}.pem" \
        -out "$CERT_DIR/cert-${ID}.pem" \
        -days 365 -nodes \
        -subj "/C=US/ST=California/L=San Francisco/O=MyCompany/CN=${DOMAIN}" 2>/dev/null

    CERT_FILE="$CERT_DIR/cert-${ID}.pem"
    KEY_FILE="$CERT_DIR/key-${ID}.pem"
    echo -e "${GREEN}Certificate generated for ${DOMAIN}${NC}"
}

# ═══════════════════════════════════════════════════
#  OPTIMIZED CONFIG BLOCKS (shared between server/client)
# ═══════════════════════════════════════════════════

write_shared_config() {
    cat << 'EOF'

smux:
  keepalive: 5
  max_recv: 16777216
  max_stream: 16777216
  frame_size: 32768
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
  tcp_keepalive: 10
  tcp_read_buffer: 4194304
  tcp_write_buffer: 4194304
  websocket_read_buffer: 65536
  websocket_write_buffer: 65536
  websocket_compression: false
  cleanup_interval: 3
  session_timeout: 60
  connection_timeout: 30
  stream_timeout: 120
  max_connections: 2000
  max_udp_flows: 500
  udp_flow_timeout: 300
  udp_buffer_size: 4194304

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
}

# ═══════════════════════════════════════════════════
#  SYSTEMD SERVICE CREATOR
# ═══════════════════════════════════════════════════

create_service() {
    local SERVICE_NAME=$1
    local CONFIG_FILE=$2

    cat > "$SYSTEMD_DIR/${SERVICE_NAME}.service" << EOF
[Unit]
Description=DaggerConnect Tunnel - ${SERVICE_NAME}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$INSTALL_DIR/DaggerConnect -c ${CONFIG_FILE}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    systemctl start "$SERVICE_NAME"
    echo -e "${GREEN}Service ${SERVICE_NAME} created and started${NC}"
}

# ═══════════════════════════════════════════════════
#  ADD SERVER TUNNEL (Run on Iran)
# ═══════════════════════════════════════════════════

add_server() {
    show_banner
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ADD SERVER TUNNEL (Run this on IRAN)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""

    # Tunnel ID
    read -p "Tunnel ID (number) [1]: " ID
    ID=${ID:-1}

    local SERVICE_NAME="dagger-server-${ID}"
    local CONFIG_FILE="$CONFIG_DIR/server-${ID}.yaml"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}server-${ID}.yaml already exists!${NC}"
        read -p "Overwrite? [y/N]: " ow
        [[ ! $ow =~ ^[Yy]$ ]] && return
        systemctl stop "$SERVICE_NAME" 2>/dev/null
    fi

    mkdir -p "$CONFIG_DIR"

    # Tunnel port
    local DEFAULT_PORT=$((8443 + ID - 1))
    read -p "Tunnel Port [${DEFAULT_PORT}]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    # PSK
    while true; do
        read -sp "Enter PSK: " PSK
        echo ""
        [[ -n "$PSK" ]] && break
        echo -e "${RED}PSK cannot be empty${NC}"
    done

    # Transport
    select_transport

    # SSL cert if needed
    CERT_FILE=""
    KEY_FILE=""
    if [[ "$TRANSPORT" == "httpsmux" || "$TRANSPORT" == "wssmux" ]]; then
        generate_ssl "$ID"
    fi

    # Port mappings
    echo ""
    echo -e "${CYAN}PORT MAPPINGS${NC}"
    echo -e "  ${YELLOW}Bind${NC}   = Port on this Iran server (users connect here)"
    echo -e "  ${YELLOW}Target${NC} = Port on Foreign client (service on remote side)"
    echo ""

    local MAPS=""
    local MAP_COUNT=0
    while true; do
        read -p "Bind port (or press Enter to finish): " BP
        [[ -z "$BP" ]] && break
        if [[ ! "$BP" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid port${NC}"
            continue
        fi

        read -p "Target port [${BP}]: " TP
        TP=${TP:-$BP}

        read -p "Protocol (tcp/udp/both) [tcp]: " PROTO
        PROTO=${PROTO:-tcp}

        case $PROTO in
            tcp)
                MAPS="${MAPS}  - type: tcp\n    bind: \"0.0.0.0:${BP}\"\n    target: \"127.0.0.1:${TP}\"\n"
                ;;
            udp)
                MAPS="${MAPS}  - type: udp\n    bind: \"0.0.0.0:${BP}\"\n    target: \"127.0.0.1:${TP}\"\n"
                ;;
            both)
                MAPS="${MAPS}  - type: tcp\n    bind: \"0.0.0.0:${BP}\"\n    target: \"127.0.0.1:${TP}\"\n"
                MAPS="${MAPS}  - type: udp\n    bind: \"0.0.0.0:${BP}\"\n    target: \"127.0.0.1:${TP}\"\n"
                ;;
        esac
        MAP_COUNT=$((MAP_COUNT + 1))
        echo -e "  ${GREEN}Added: 0.0.0.0:${BP} -> 127.0.0.1:${TP} (${PROTO})${NC}"
    done

    if [[ $MAP_COUNT -eq 0 ]]; then
        echo -e "${RED}No port mappings added! At least one is required.${NC}"
        read -p "Press Enter..."
        return
    fi

    # Write config file
    cat > "$CONFIG_FILE" << EOF
mode: "server"
listen: "0.0.0.0:${PORT}"
transport: "${TRANSPORT}"
psk: "${PSK}"
profile: "latency"
verbose: true

heartbeat: 2
EOF

    if [[ -n "$CERT_FILE" ]]; then
        cat >> "$CONFIG_FILE" << EOF

cert_file: "${CERT_FILE}"
key_file: "${KEY_FILE}"
EOF
    fi

    printf "\nmaps:\n" >> "$CONFIG_FILE"
    printf "$MAPS" >> "$CONFIG_FILE"

    write_shared_config >> "$CONFIG_FILE"

    # Create and start service
    create_service "$SERVICE_NAME" "$CONFIG_FILE"

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Server tunnel #${ID} is ready!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "  Tunnel Port : ${GREEN}${PORT}${NC}"
    echo -e "  Transport   : ${GREEN}${TRANSPORT}${NC}"
    echo -e "  PSK         : ${GREEN}${PSK}${NC}"
    echo -e "  Mappings    : ${GREEN}${MAP_COUNT}${NC}"
    echo -e "  Config      : ${CONFIG_FILE}"
    echo -e "  Logs        : journalctl -u ${SERVICE_NAME} -f"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  ADD CLIENT TUNNEL (Run on Foreign)
# ═══════════════════════════════════════════════════

add_client() {
    show_banner
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ADD CLIENT TUNNEL (Run on FOREIGN)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""

    # Tunnel ID
    read -p "Tunnel ID (number) [1]: " ID
    ID=${ID:-1}

    local SERVICE_NAME="dagger-client-${ID}"
    local CONFIG_FILE="$CONFIG_DIR/client-${ID}.yaml"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}client-${ID}.yaml already exists!${NC}"
        read -p "Overwrite? [y/N]: " ow
        [[ ! $ow =~ ^[Yy]$ ]] && return
        systemctl stop "$SERVICE_NAME" 2>/dev/null
    fi

    mkdir -p "$CONFIG_DIR"

    # Server address
    read -p "Iran server address with port (e.g., 1.2.3.4:8443): " ADDR
    if [[ -z "$ADDR" ]]; then
        echo -e "${RED}Address cannot be empty${NC}"
        read -p "Press Enter..."
        return
    fi

    # PSK
    while true; do
        read -sp "Enter PSK (must match server): " PSK
        echo ""
        [[ -n "$PSK" ]] && break
        echo -e "${RED}PSK cannot be empty${NC}"
    done

    # Transport
    select_transport

    # Connection pool
    read -p "Connection pool size [3]: " POOL
    POOL=${POOL:-3}

    # Write config file
    cat > "$CONFIG_FILE" << EOF
mode: "client"
psk: "${PSK}"
profile: "latency"
verbose: true

heartbeat: 2

paths:
  - transport: "${TRANSPORT}"
    addr: "${ADDR}"
    connection_pool: ${POOL}
    aggressive_pool: true
    retry_interval: 3
    dial_timeout: 10
EOF

    write_shared_config >> "$CONFIG_FILE"

    # Create and start service
    create_service "$SERVICE_NAME" "$CONFIG_FILE"

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Client tunnel #${ID} is ready!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "  Server    : ${GREEN}${ADDR}${NC}"
    echo -e "  Transport : ${GREEN}${TRANSPORT}${NC}"
    echo -e "  Pool      : ${GREEN}${POOL}${NC}"
    echo -e "  Config    : ${CONFIG_FILE}"
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  LIST ALL TUNNELS
# ═══════════════════════════════════════════════════

list_tunnels() {
    show_banner
    echo -e "${CYAN}CONFIGURED TUNNELS${NC}"
    echo ""

    local found=false

    # New-style configs: server-{ID}.yaml / client-{ID}.yaml
    for f in "$CONFIG_DIR"/server-*.yaml "$CONFIG_DIR"/client-*.yaml; do
        [[ ! -f "$f" ]] && continue
        found=true

        local base=$(basename "$f" .yaml)
        local mode=$(echo "$base" | cut -d- -f1)
        local id=$(echo "$base" | sed "s/${mode}-//")
        local service="dagger-${mode}-${id}"
        local status=$(systemctl is-active "$service" 2>/dev/null)

        if [[ "$mode" == "server" ]]; then
            local port=$(grep "^listen:" "$f" | grep -oP ':\K\d+')
            local maps=$(grep -c "type:" "$f" 2>/dev/null || echo "0")
            if [[ "$status" == "active" ]]; then
                echo -e "  ${GREEN}[ACTIVE]${NC}  Server #${id}  |  Port: ${port}  |  Maps: ${maps}  |  ${service}"
            else
                echo -e "  ${RED}[STOP]${NC}   Server #${id}  |  Port: ${port}  |  Maps: ${maps}  |  ${service}"
            fi
        else
            local addr=$(grep "addr:" "$f" | head -1 | grep -oP '"[^"]+"' | tr -d '"')
            if [[ "$status" == "active" ]]; then
                echo -e "  ${GREEN}[ACTIVE]${NC}  Client #${id}  |  Server: ${addr}  |  ${service}"
            else
                echo -e "  ${RED}[STOP]${NC}   Client #${id}  |  Server: ${addr}  |  ${service}"
            fi
        fi
    done

    # Legacy configs: server.yaml / client.yaml (old DaggerConnect style)
    for mode in server client; do
        if [[ -f "$CONFIG_DIR/${mode}.yaml" ]]; then
            found=true
            local service="DaggerConnect-${mode}"
            local status=$(systemctl is-active "$service" 2>/dev/null)
            if [[ "$status" == "active" ]]; then
                echo -e "  ${GREEN}[ACTIVE]${NC}  ${mode^} (legacy)  |  ${service}"
            else
                echo -e "  ${RED}[STOP]${NC}   ${mode^} (legacy)  |  ${service}"
            fi
        fi
    done

    $found || echo -e "  ${YELLOW}No tunnels configured${NC}"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  MANAGE / CONTROL TUNNELS
# ═══════════════════════════════════════════════════

collect_tunnels() {
    # Populate TUNNEL_LIST array with "service|config|label" entries
    TUNNEL_LIST=()

    for f in "$CONFIG_DIR"/server-*.yaml "$CONFIG_DIR"/client-*.yaml; do
        [[ ! -f "$f" ]] && continue
        local base=$(basename "$f" .yaml)
        local mode=$(echo "$base" | cut -d- -f1)
        local id=$(echo "$base" | sed "s/${mode}-//")
        local service="dagger-${mode}-${id}"
        TUNNEL_LIST+=("${service}|${f}|${mode^} #${id}")
    done

    # Legacy
    for mode in server client; do
        if [[ -f "$CONFIG_DIR/${mode}.yaml" ]]; then
            local service="DaggerConnect-${mode}"
            TUNNEL_LIST+=("${service}|${CONFIG_DIR}/${mode}.yaml|${mode^} (legacy)")
        fi
    done
}

select_tunnel() {
    # Show numbered list of tunnels, user picks one
    # Sets: SELECTED_SERVICE, SELECTED_CONFIG, SELECTED_LABEL
    collect_tunnels

    if [[ ${#TUNNEL_LIST[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}No tunnels found${NC}"
        return 1
    fi

    local i=1
    for entry in "${TUNNEL_LIST[@]}"; do
        IFS='|' read -r svc cfg label <<< "$entry"
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  ${i}) ${GREEN}[ON]${NC}  ${label}"
        else
            echo -e "  ${i}) ${RED}[OFF]${NC} ${label}"
        fi
        ((i++))
    done

    echo ""
    read -p "Select tunnel: " num
    if [[ -z "$num" || $num -lt 1 || $num -gt ${#TUNNEL_LIST[@]} ]]; then
        return 1
    fi

    IFS='|' read -r SELECTED_SERVICE SELECTED_CONFIG SELECTED_LABEL <<< "${TUNNEL_LIST[$((num-1))]}"
    return 0
}

manage_tunnel() {
    show_banner
    echo -e "${CYAN}MANAGE TUNNEL${NC}"
    echo ""

    if ! select_tunnel; then
        read -p "Press Enter..."
        return
    fi

    echo ""
    echo -e "${CYAN}Selected: ${GREEN}${SELECTED_LABEL}${NC} (${SELECTED_SERVICE})"
    echo ""
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Status"
    echo "  5) View Logs (last 50 lines)"
    echo "  6) Follow Logs (live)"
    echo "  7) View Config"
    echo "  8) Edit Config"
    echo "  9) Delete Tunnel"
    echo ""
    echo "  0) Cancel"
    echo ""
    read -p "Action: " action

    case $action in
        1)
            systemctl start "$SELECTED_SERVICE"
            echo -e "${GREEN}Started${NC}"
            sleep 1
            ;;
        2)
            systemctl stop "$SELECTED_SERVICE"
            echo -e "${GREEN}Stopped${NC}"
            sleep 1
            ;;
        3)
            systemctl restart "$SELECTED_SERVICE"
            echo -e "${GREEN}Restarted${NC}"
            sleep 1
            ;;
        4)
            echo ""
            systemctl status "$SELECTED_SERVICE" --no-pager
            echo ""
            read -p "Press Enter..."
            ;;
        5)
            echo ""
            journalctl -u "$SELECTED_SERVICE" -n 50 --no-pager
            echo ""
            read -p "Press Enter..."
            ;;
        6)
            echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
            journalctl -u "$SELECTED_SERVICE" -f
            ;;
        7)
            echo ""
            echo -e "${CYAN}--- ${SELECTED_CONFIG} ---${NC}"
            cat "$SELECTED_CONFIG"
            echo -e "${CYAN}--- end ---${NC}"
            echo ""
            read -p "Press Enter..."
            ;;
        8)
            ${EDITOR:-nano} "$SELECTED_CONFIG"
            echo ""
            read -p "Restart service to apply changes? [y/N]: " r
            if [[ $r =~ ^[Yy]$ ]]; then
                systemctl restart "$SELECTED_SERVICE"
                echo -e "${GREEN}Restarted${NC}"
                sleep 1
            fi
            ;;
        9)
            echo ""
            read -p "Delete ${SELECTED_LABEL}? This removes config and service. [y/N]: " c
            if [[ $c =~ ^[Yy]$ ]]; then
                systemctl stop "$SELECTED_SERVICE" 2>/dev/null
                systemctl disable "$SELECTED_SERVICE" 2>/dev/null
                rm -f "$SELECTED_CONFIG"
                rm -f "$SYSTEMD_DIR/${SELECTED_SERVICE}.service"
                systemctl daemon-reload
                echo -e "${GREEN}Deleted ${SELECTED_LABEL}${NC}"
                sleep 1
            fi
            ;;
        0|*) ;;
    esac
}

# ═══════════════════════════════════════════════════
#  RESTART ALL TUNNELS
# ═══════════════════════════════════════════════════

restart_all() {
    show_banner
    echo -e "${CYAN}RESTART ALL TUNNELS${NC}"
    echo ""

    collect_tunnels

    if [[ ${#TUNNEL_LIST[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}No tunnels found${NC}"
        read -p "Press Enter..."
        return
    fi

    for entry in "${TUNNEL_LIST[@]}"; do
        IFS='|' read -r svc cfg label <<< "$entry"
        systemctl restart "$svc" 2>/dev/null
        echo -e "  ${GREEN}Restarted:${NC} ${label} (${svc})"
    done

    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  SYSTEM OPTIMIZER
# ═══════════════════════════════════════════════════

optimize_system() {
    show_banner
    echo -e "${CYAN}SYSTEM OPTIMIZATION${NC}"
    echo ""

    # Detect interface
    local IFACE=$(ip link show | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    IFACE=${IFACE:-eth0}
    echo -e "  Interface: ${GREEN}${IFACE}${NC}"

    # TCP optimizations
    echo -e "  ${YELLOW}Applying TCP optimizations...${NC}"
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
    echo -e "  ${GREEN}TCP optimized${NC}"

    # BBR
    if modprobe tcp_bbr 2>/dev/null; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq_codel > /dev/null 2>&1
        echo -e "  ${GREEN}BBR enabled${NC}"
    else
        echo -e "  ${YELLOW}BBR not available, using default${NC}"
    fi

    # Queue discipline
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    if tc qdisc add dev "$IFACE" root fq_codel limit 500 target 3ms interval 50ms quantum 300 ecn 2>/dev/null; then
        echo -e "  ${GREEN}fq_codel configured${NC}"
    fi

    # Persist settings
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
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq_codel
EOF
    echo -e "  ${GREEN}Settings persisted${NC}"

    echo ""
    echo -e "${GREEN}System optimization complete!${NC}"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  UPDATE BINARY
# ═══════════════════════════════════════════════════

update_binary() {
    show_banner
    echo -e "${CYAN}UPDATE DaggerConnect BINARY${NC}"
    echo ""

    local CURRENT=$(get_version)
    echo -e "  Current version: ${GREEN}${CURRENT}${NC}"
    echo ""
    read -p "Download latest version? [y/N]: " c
    [[ ! $c =~ ^[Yy]$ ]] && return

    echo ""
    echo -e "${YELLOW}Stopping all tunnels...${NC}"
    collect_tunnels
    for entry in "${TUNNEL_LIST[@]}"; do
        IFS='|' read -r svc cfg label <<< "$entry"
        systemctl stop "$svc" 2>/dev/null
    done

    download_binary

    echo ""
    echo -e "${YELLOW}Restarting tunnels...${NC}"
    for entry in "${TUNNEL_LIST[@]}"; do
        IFS='|' read -r svc cfg label <<< "$entry"
        systemctl start "$svc" 2>/dev/null
        echo -e "  ${GREEN}Started:${NC} ${label}"
    done

    echo ""
    echo -e "  New version: ${GREEN}$(get_version)${NC}"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  UNINSTALL
# ═══════════════════════════════════════════════════

uninstall_all() {
    show_banner
    echo -e "${RED}UNINSTALL DaggerConnect${NC}"
    echo ""
    echo "  This will remove:"
    echo "    - DaggerConnect binary"
    echo "    - All tunnel configs and certificates"
    echo "    - All systemd services"
    echo "    - System optimizations"
    echo ""
    read -p "Are you sure? [y/N]: " c
    [[ ! $c =~ ^[Yy]$ ]] && return

    # Stop and remove all services
    collect_tunnels
    for entry in "${TUNNEL_LIST[@]}"; do
        IFS='|' read -r svc cfg label <<< "$entry"
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$SYSTEMD_DIR/${svc}.service"
    done

    # Also clean legacy services
    for mode in server client; do
        systemctl stop "DaggerConnect-${mode}" 2>/dev/null
        systemctl disable "DaggerConnect-${mode}" 2>/dev/null
        rm -f "$SYSTEMD_DIR/DaggerConnect-${mode}.service"
    done

    rm -f "$INSTALL_DIR/DaggerConnect"
    rm -rf "$CONFIG_DIR"
    rm -f /etc/sysctl.d/99-daggerconnect.conf
    systemctl daemon-reload

    echo ""
    echo -e "${GREEN}DaggerConnect completely uninstalled${NC}"
    echo ""
    exit 0
}

# ═══════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════

main_menu() {
    while true; do
        show_banner

        local ver=$(get_version)
        [[ "$ver" != "not-installed" ]] && echo -e "  Version: ${GREEN}${ver}${NC}" && echo ""

        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo -e "${CYAN}               MAIN MENU${NC}"
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Add Server Tunnel   (Iran)"
        echo "  2) Add Client Tunnel   (Foreign/Kharej)"
        echo ""
        echo "  3) List All Tunnels"
        echo "  4) Manage Tunnel       (start/stop/logs/edit/delete)"
        echo "  5) Restart All Tunnels"
        echo ""
        echo "  6) System Optimizer"
        echo "  7) Update Binary"
        echo "  8) Uninstall"
        echo ""
        echo "  0) Exit"
        echo ""
        read -p "Choice: " choice

        case $choice in
            1) add_server ;;
            2) add_client ;;
            3) list_tunnels ;;
            4) manage_tunnel ;;
            5) restart_all ;;
            6) optimize_system ;;
            7) update_binary ;;
            8) uninstall_all ;;
            0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) ;;
        esac
    done
}

# ═══════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════

check_root
show_banner
install_deps

if [[ ! -f "$INSTALL_DIR/DaggerConnect" ]]; then
    echo -e "${YELLOW}DaggerConnect binary not found. Downloading...${NC}"
    download_binary
    echo ""
fi

main_menu

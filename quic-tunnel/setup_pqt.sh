#!/bin/bash

# ==========================================
#  PQT QUIC Tunnel Manager v1.0
#  QUIC (Brutal CC) + XOR + Fake-TCP
#  Multi-Tunnel Support
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

PQT_BIN="/usr/local/bin/pqt"
CONFIG_DIR="/etc/pqt"
LOG_DIR="/var/log/pqt"
EXPECTED_SHA256="6e2a74e1604d40ee87c9013972a8dc8f386f4df852d99e661a6eeeba768456fe0"
DL_URL="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/quic-tunnel/pqt"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

mkdir -p "$CONFIG_DIR" "$LOG_DIR"

# ==========================================
# Generate tunnel key (base64, 32 bytes)
# ==========================================
generate_key() {
    openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64
}

# ==========================================
# Install PQT Binary
# ==========================================
install_pqt() {
    if [[ -f "$PQT_BIN" ]]; then
        echo -e "${GREEN}PQT already installed at: ${PQT_BIN}${NC}"
        read -p "Reinstall? (y/N): " r
        [[ ! $r =~ ^[Yy]$ ]] && return
    fi

    echo -e "${YELLOW}Installing PQT...${NC}"
    echo -e "${CYAN}Downloading from: ${DL_URL}${NC}"
    echo ""

    local dl_ok=false
    if command -v wget &>/dev/null; then
        wget --progress=bar:force -O /tmp/pqt "$DL_URL" 2>&1 && dl_ok=true
    fi
    if [[ "$dl_ok" == false ]] && command -v curl &>/dev/null; then
        curl -fL --progress-bar -o /tmp/pqt "$DL_URL" && dl_ok=true
    fi

    echo ""
    if [[ "$dl_ok" == true && -s /tmp/pqt ]]; then
        # Verify checksum
        local actual_sha=$(sha256sum /tmp/pqt | awk '{print $1}')
        if [[ "$actual_sha" != "$EXPECTED_SHA256" ]]; then
            echo -e "${RED}Checksum MISMATCH!${NC}"
            echo -e "  Expected: ${EXPECTED_SHA256}"
            echo -e "  Got:      ${actual_sha}"
            echo -e "${RED}File may be corrupted or tampered. Aborting.${NC}"
            rm -f /tmp/pqt
            return 1
        fi
        echo -e "${GREEN}Checksum verified OK${NC}"
        chmod +x /tmp/pqt
        mv /tmp/pqt "$PQT_BIN"
        echo -e "${GREEN}PQT installed successfully!${NC}"
    else
        rm -f /tmp/pqt
        echo -e "${YELLOW}Download failed. Trying local copy...${NC}"
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$SCRIPT_DIR/pqt" ]]; then
            cp "$SCRIPT_DIR/pqt" "$PQT_BIN"
            chmod +x "$PQT_BIN"
            echo -e "${GREEN}PQT installed from local file${NC}"
        else
            echo -e "${RED}Installation failed! Place 'pqt' binary next to this script.${NC}"
            return 1
        fi
    fi
}

# ==========================================
# Reinstall PQT (delete + fresh download)
# ==========================================
reinstall_pqt() {
    echo -e "${BLUE}--- Reinstall PQT Binary ---${NC}"

    if [[ -f "$PQT_BIN" ]]; then
        local cur_sha=$(sha256sum "$PQT_BIN" | awk '{print $1}')
        echo -e "Current binary: ${PQT_BIN}"
        echo -e "Current SHA256: ${cur_sha}"
        echo ""
        echo -e "${YELLOW}Removing current binary...${NC}"
        rm -f "$PQT_BIN"
        echo -e "${GREEN}Removed.${NC}"
    else
        echo -e "${YELLOW}No existing binary found.${NC}"
    fi

    echo ""
    install_pqt
}

# ==========================================
# Setup Server (Kharej)
# ==========================================
setup_server() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Server (KHAREJ) - PQT${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    # Tunnel port
    read -p "Tunnel Port [9999]: " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-9999}

    # Tunnel key
    DEFAULT_KEY=$(generate_key)
    echo -e "${YELLOW}Generated Key: ${GREEN}${DEFAULT_KEY}${NC}"
    read -p "Use this key or enter your own (Enter to keep): " INPUT_KEY
    [[ ! -z "$INPUT_KEY" ]] && DEFAULT_KEY="$INPUT_KEY"

    # Speed
    read -p "Speed (Mbps, 0=adaptive) [100]: " SPEED
    SPEED=${SPEED:-100}

    # FakeTLS SNI
    read -p "FakeTLS SNI [digikala.com]: " SNI
    SNI=${SNI:-digikala.com}

    # Target address
    read -p "Target address [127.0.0.1]: " TARGET_ADDR
    TARGET_ADDR=${TARGET_ADDR:-127.0.0.1}

    # Log level
    read -p "Log level (debug/info/warning/error) [warning]: " LOG_LEVEL
    LOG_LEVEL=${LOG_LEVEL:-warning}

    # OS Mimicry
    read -p "OS fingerprint (linux/windows/macos) [linux]: " OS_MIMICRY
    OS_MIMICRY=${OS_MIMICRY:-linux}

    # Blackout Detection
    read -p "Enable Blackout Detection? (Y/n): " BLACKOUT_ANS
    if [[ "$BLACKOUT_ANS" =~ ^[Nn]$ ]]; then
        BLACKOUT_ENABLED="false"
    else
        BLACKOUT_ENABLED="true"
    fi

    CONFIG_FILE="${CONFIG_DIR}/server-${TUNNEL_PORT}.yaml"
    SERVICE_NAME="pqt-server-${TUNNEL_PORT}"

    cat > "$CONFIG_FILE" <<EOF
# PQT Server Config — Kharej
# Port: ${TUNNEL_PORT}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

role: "server"

target: "${TARGET_ADDR}"

tunnel:
  port: ${TUNNEL_PORT}
  key: "${DEFAULT_KEY}"
  speed_mbps: ${SPEED}

faketls:
  enabled: true
  sni: "${SNI}"
  reality: true
  fingerprint: "chrome"
  traffic_shaping:
    enabled: true
    padding_pct: 0
    silence_min_ms: 15000
    silence_max_ms: 45000

network:
  pcap_buf_size: 67108864

log:
  level: "${LOG_LEVEL}"

evasion:
  enabled: true
  protocol_smuggle: 0
  rst_injection: true
  tcp_options: true
  decoy_packets: true
  decoy_ttl: 2
  length_morphing: true
  os_mimicry: "${OS_MIMICRY}"

antithrottle:
  fec:
    enabled: false
    group_size: 8
  aggressive_cc:
    enabled: true
    min_ack_rate: 0.5
    cwnd_multiplier: 2
    max_burst: 10
  padding:
    enabled: true
    max_bytes: 150
    jitter_us: 300
  multipath:
    enabled: false
    count: 3

blackout:
  enabled: ${BLACKOUT_ENABLED}
  probes: ["dns", "ntp", "bgp", "https", "normal"]
  timeout_s: 20
EOF

    # Create systemd service
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=PQT QUIC Tunnel Server (port ${TUNNEL_PORT})
After=network.target

[Service]
Type=simple
ExecStart=${PQT_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=5
StartLimitInterval=0
LimitNOFILE=65535
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    sleep 2
    local status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Server Ready! (${status})${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  IP        : ${IP}${NC}"
    echo -e "${GREEN}  Port      : ${TUNNEL_PORT}${NC}"
    echo -e "${GREEN}  Key       : ${DEFAULT_KEY}${NC}"
    echo -e "${GREEN}  Speed     : ${SPEED} Mbps${NC}"
    echo -e "${GREEN}  SNI       : ${SNI}${NC}"
    echo -e "${GREEN}  Service   : ${SERVICE_NAME}${NC}"
    echo -e "${GREEN}  Config    : ${CONFIG_FILE}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Save these values for client setup!${NC}"
    read -p "Press Enter to continue..."
}

# ==========================================
# Setup Client (Iran) — Multi-Tunnel
# ==========================================
setup_client() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Client (IRAN) - PQT${NC}"
    echo -e "${BLUE}  Supports Multiple Tunnels${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    read -p "Server IP (Kharej): " SERVER_IP
    [[ -z "$SERVER_IP" ]] && { echo -e "${RED}Server IP required${NC}"; return; }

    read -p "Tunnel Port [9999]: " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-9999}

    read -p "Tunnel Key: " TUNNEL_KEY
    [[ -z "$TUNNEL_KEY" ]] && { echo -e "${RED}Tunnel key required${NC}"; return; }

    read -p "Speed (Mbps, 0=adaptive) [100]: " SPEED
    SPEED=${SPEED:-100}

    read -p "FakeTLS SNI [digikala.com]: " SNI
    SNI=${SNI:-digikala.com}

    read -p "Log level (debug/info/warning/error) [warning]: " LOG_LEVEL
    LOG_LEVEL=${LOG_LEVEL:-warning}

    read -p "OS fingerprint (linux/windows/macos) [linux]: " OS_MIMICRY
    OS_MIMICRY=${OS_MIMICRY:-linux}

    # Blackout Detection
    read -p "Enable Blackout Detection? (Y/n): " BLACKOUT_ANS
    if [[ "$BLACKOUT_ANS" =~ ^[Nn]$ ]]; then
        BLACKOUT_ENABLED="false"
    else
        BLACKOUT_ENABLED="true"
    fi

    # Port forwarding
    echo ""
    echo -e "${CYAN}PORT FORWARDING${NC}"
    echo -e "  ${YELLOW}Add port forwards (listen:remote_port)${NC}"
    echo -e "  ${YELLOW}Example: listen=:3031  remote_port=3031${NC}"
    echo ""

    FORWARDS=""
    FWD_COUNT=0

    while true; do
        if [[ $FWD_COUNT -eq 0 ]]; then
            read -p "Listen port: " LISTEN_PORT
            if [[ -z "$LISTEN_PORT" ]]; then
                echo -e "  ${RED}At least one port is required! Try again.${NC}"
                continue
            fi
        else
            read -p "Listen port (or Enter to finish): " LISTEN_PORT
            [[ -z "$LISTEN_PORT" ]] && break
        fi

        read -p "Remote port [${LISTEN_PORT}]: " REMOTE_PORT
        REMOTE_PORT=${REMOTE_PORT:-$LISTEN_PORT}

        FORWARDS="${FORWARDS}  - listen: \":${LISTEN_PORT}\"
    remote_port: ${REMOTE_PORT}
"
        FWD_COUNT=$((FWD_COUNT + 1))
        echo -e "  ${GREEN}Added: :${LISTEN_PORT} -> ${REMOTE_PORT}${NC}"
    done

    # Sanitize server IP for filename (replace dots and colons)
    SAFE_IP=$(echo "$SERVER_IP" | tr '.:' '_')
    CONFIG_FILE="${CONFIG_DIR}/client-${SAFE_IP}-${TUNNEL_PORT}.yaml"
    SERVICE_NAME="pqt-client-${SAFE_IP}-${TUNNEL_PORT}"

    cat > "$CONFIG_FILE" <<EOF
# PQT Client Config — Iran
# Server: ${SERVER_IP}:${TUNNEL_PORT}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

role: "client"

server:
  address: "${SERVER_IP}"

tunnel:
  port: ${TUNNEL_PORT}
  key: "${TUNNEL_KEY}"
  speed_mbps: ${SPEED}

faketls:
  enabled: true
  sni: "${SNI}"
  reality: true
  fingerprint: "chrome"
  traffic_shaping:
    enabled: true
    padding_pct: 0
    silence_min_ms: 15000
    silence_max_ms: 45000

forwards:
${FORWARDS}
network:
  pcap_buf_size: 67108864

log:
  level: "${LOG_LEVEL}"

evasion:
  enabled: true
  protocol_smuggle: 0
  rst_injection: true
  tcp_options: true
  decoy_packets: true
  decoy_ttl: 2
  length_morphing: true
  os_mimicry: "${OS_MIMICRY}"

antithrottle:
  fec:
    enabled: false
    group_size: 8
  aggressive_cc:
    enabled: true
    min_ack_rate: 0.5
    cwnd_multiplier: 2
    max_burst: 10
  padding:
    enabled: true
    max_bytes: 150
    jitter_us: 300
  multipath:
    enabled: false
    count: 3

blackout:
  enabled: ${BLACKOUT_ENABLED}
  probes: ["dns", "ntp", "bgp", "https", "normal"]
  timeout_s: 20
EOF

    # Create systemd service
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=PQT QUIC Tunnel Client (${SERVER_IP}:${TUNNEL_PORT})
After=network.target

[Service]
Type=simple
ExecStart=${PQT_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=5
StartLimitInterval=0
LimitNOFILE=65535
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    sleep 2
    local status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Client Ready! (${status})${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Server    : ${SERVER_IP}:${TUNNEL_PORT}${NC}"
    echo -e "${GREEN}  Forwards  : ${FWD_COUNT} port(s)${NC}"
    echo -e "${GREEN}  Service   : ${SERVICE_NAME}${NC}"
    echo -e "${GREEN}  Config    : ${CONFIG_FILE}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""

    # Ask about another tunnel
    read -p "Add another tunnel to a different server? (y/N): " ANOTHER
    if [[ "$ANOTHER" =~ ^[Yy]$ ]]; then
        setup_client
    fi

    read -p "Press Enter to continue..."
}

# ==========================================
# Add Ports to Existing Client Tunnel
# ==========================================
add_ports() {
    echo -e "${BLUE}--- Add Ports to Existing Tunnel ---${NC}"

    local configs=($(ls ${CONFIG_DIR}/client-*.yaml 2>/dev/null))
    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${RED}No client configs found!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Select config to modify:"
    local i=1
    for cfg in "${configs[@]}"; do
        local name=$(basename "$cfg" .yaml)
        echo "  $i) $name"
        i=$((i+1))
    done
    echo "  0) Cancel"

    read -p "Select: " CHOICE
    [[ "$CHOICE" == "0" || -z "$CHOICE" ]] && return

    local idx=$((CHOICE - 1))
    if [[ $idx -lt 0 || $idx -ge ${#configs[@]} ]]; then
        echo -e "${RED}Invalid choice${NC}"
        return
    fi

    local cfg_file="${configs[$idx]}"
    echo -e "${CYAN}Current config: $(basename "$cfg_file")${NC}"
    echo ""

    # Show current forwards
    echo -e "${YELLOW}Current forwards:${NC}"
    grep -A2 "listen:" "$cfg_file" | while read -r line; do
        echo "  $line"
    done
    echo ""

    echo -e "${CYAN}Add new port forwards:${NC}"
    local new_forwards=""
    local count=0

    while true; do
        read -p "Listen port (or Enter to finish): " LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && break

        read -p "Remote port [${LISTEN_PORT}]: " REMOTE_PORT
        REMOTE_PORT=${REMOTE_PORT:-$LISTEN_PORT}

        new_forwards="${new_forwards}  - listen: \":${LISTEN_PORT}\"\n    remote_port: ${REMOTE_PORT}\n"
        count=$((count + 1))
        echo -e "  ${GREEN}Added: :${LISTEN_PORT} -> ${REMOTE_PORT}${NC}"
    done

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}No ports added${NC}"
        return
    fi

    # Append forwards before the 'network:' section
    sed -i "/^network:/i\\$(echo -e "$new_forwards")" "$cfg_file"

    # Restart corresponding service
    local svc_name=$(basename "$cfg_file" .yaml | sed 's/^/pqt-/')
    systemctl restart "$svc_name" 2>/dev/null
    echo -e "${GREEN}${count} port(s) added. Service restarted.${NC}"
    read -p "Press Enter to continue..."
}

# ==========================================
# List Tunnels / Status
# ==========================================
list_tunnels() {
    echo ""
    echo -e "${CYAN}CONFIGURED PQT TUNNELS${NC}"
    echo ""

    local found=false

    # Server tunnels
    for f in /etc/systemd/system/pqt-server-*.service; do
        [[ ! -f "$f" ]] && continue
        found=true
        local svc=$(basename "$f" .service)
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        local port=$(echo "$svc" | sed 's/pqt-server-//')
        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[ON]${NC}  ${MAGENTA}[SERVER]${NC} $svc (port: $port)"
        else
            echo -e "  ${RED}[OFF]${NC} ${MAGENTA}[SERVER]${NC} $svc (port: $port)"
        fi
    done

    # Client tunnels
    for f in /etc/systemd/system/pqt-client-*.service; do
        [[ ! -f "$f" ]] && continue
        found=true
        local svc=$(basename "$f" .service)
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[ON]${NC}  ${CYAN}[CLIENT]${NC} $svc"
        else
            echo -e "  ${RED}[OFF]${NC} ${CYAN}[CLIENT]${NC} $svc"
        fi
    done

    $found || echo -e "  ${YELLOW}No PQT tunnels configured${NC}"

    # Show configs
    echo ""
    echo -e "${CYAN}CONFIG FILES:${NC}"
    if ls ${CONFIG_DIR}/*.yaml &>/dev/null; then
        for cfg in ${CONFIG_DIR}/*.yaml; do
            echo -e "  $(basename "$cfg")"
        done
    else
        echo -e "  ${YELLOW}No config files${NC}"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

# ==========================================
# Check Connection
# ==========================================
check_connection() {
    echo -e "${BLUE}--- Check Tunnel Connection ---${NC}"

    echo -e "${YELLOW}Checking PQT Services...${NC}"
    SERVICES=$(systemctl list-units --type=service --state=running 2>/dev/null | grep "pqt-")

    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No running PQT services found!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${GREEN}Running Services:${NC}"
    echo "$SERVICES"

    # Check listening ports from config
    echo ""
    echo -e "${YELLOW}Checking Forwarded Ports...${NC}"
    for cfg in ${CONFIG_DIR}/client-*.yaml; do
        [[ ! -f "$cfg" ]] && continue
        echo -e "${CYAN}Config: $(basename "$cfg")${NC}"
        # Extract listen ports
        grep "listen:" "$cfg" | while read -r line; do
            port=$(echo "$line" | grep -oP ':\K[0-9]+')
            if [[ ! -z "$port" ]]; then
                if nc -z -w 3 127.0.0.1 "$port" 2>/dev/null; then
                    echo -e "  ${GREEN}Port $port: OPEN${NC}"
                else
                    echo -e "  ${RED}Port $port: CLOSED${NC}"
                fi
            fi
        done
    done

    echo ""
    read -p "Enter a port to test manually (or Enter to skip): " TEST_PORT
    if [[ ! -z "$TEST_PORT" ]]; then
        if nc -z -w 5 127.0.0.1 "$TEST_PORT" 2>/dev/null; then
            echo -e "${GREEN}TCP port $TEST_PORT is OPEN${NC}"
        else
            echo -e "${RED}TCP port $TEST_PORT is CLOSED${NC}"
        fi
    fi

    read -p "Press Enter to continue..."
}

# ==========================================
# View Logs
# ==========================================
view_logs() {
    echo -e "${BLUE}--- View Service Logs ---${NC}"

    local services=()
    local i=1
    for f in /etc/systemd/system/pqt-*.service; do
        [[ ! -f "$f" ]] && continue
        local svc=$(basename "$f" .service)
        services+=("$svc")
        echo "  $i) $svc"
        i=$((i+1))
    done

    if [[ ${#services[@]} -eq 0 ]]; then
        echo -e "${RED}No PQT services found${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "  0) Cancel"
    read -p "Select: " CHOICE
    [[ "$CHOICE" == "0" || -z "$CHOICE" ]] && return

    local idx=$((CHOICE - 1))
    if [[ $idx -lt 0 || $idx -ge ${#services[@]} ]]; then
        echo -e "${RED}Invalid choice${NC}"
        return
    fi

    echo -e "${CYAN}Last 50 lines of ${services[$idx]}:${NC}"
    journalctl -u "${services[$idx]}" -n 50 --no-pager
    read -p "Press Enter to continue..."
}

# ==========================================
# Setup Watchdog
# ==========================================
setup_watchdog() {
    echo -e "${BLUE}--- Setup Auto-Reconnect Watchdog ---${NC}"

    local services=()
    local i=1
    for f in /etc/systemd/system/pqt-client-*.service; do
        [[ ! -f "$f" ]] && continue
        local svc=$(basename "$f" .service)
        services+=("$svc")
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $i) ${GREEN}[ON]${NC}  $svc"
        else
            echo -e "  $i) ${RED}[OFF]${NC} $svc"
        fi
        i=$((i+1))
    done

    if [[ ${#services[@]} -eq 0 ]]; then
        echo -e "${RED}No PQT client services found to monitor${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "  A) All client tunnels"
    echo "  0) Cancel"

    read -p "Select: " CHOICE
    [[ "$CHOICE" == "0" || -z "$CHOICE" ]] && return

    local target_services=()

    if [[ "$CHOICE" =~ ^[Aa]$ ]]; then
        target_services=("${services[@]}")
    else
        local idx=$((CHOICE - 1))
        if [[ $idx -lt 0 || $idx -ge ${#services[@]} ]]; then
            echo -e "${RED}Invalid choice${NC}"
            return
        fi
        target_services=("${services[$idx]}")
    fi

    for svc in "${target_services[@]}"; do
        # Find config file
        local cfg_name=$(echo "$svc" | sed 's/^pqt-//')
        local cfg_file="${CONFIG_DIR}/${cfg_name}.yaml"

        # Extract first listen port for health check
        local check_port=""
        if [[ -f "$cfg_file" ]]; then
            check_port=$(grep "listen:" "$cfg_file" | head -1 | grep -oP ':\K[0-9]+')
        fi

        WATCHDOG_SCRIPT="/usr/local/bin/watchdog-${svc}.sh"

        cat > "$WATCHDOG_SCRIPT" <<WDEOF
#!/bin/bash
# Watchdog for ${svc}
LOG_PREFIX="[\$(date '+%Y-%m-%d %H:%M:%S')] [${svc}]"

# 1. Check systemd service
IS_ACTIVE=\$(systemctl is-active ${svc})
if [ "\$IS_ACTIVE" != "active" ]; then
    echo "\$LOG_PREFIX Service down. Restarting..."
    systemctl restart ${svc}
    exit 0
fi
WDEOF

        # Add port check if we found a port
        if [[ ! -z "$check_port" ]]; then
            cat >> "$WATCHDOG_SCRIPT" <<WDEOF

# 2. TCP port check
nc -z -w 5 127.0.0.1 ${check_port} 2>/dev/null
if [ \$? -ne 0 ]; then
    echo "\$LOG_PREFIX Port ${check_port} not responding. Restarting..."
    systemctl restart ${svc}
fi
WDEOF
        fi

        chmod +x "$WATCHDOG_SCRIPT"

        # Add to crontab
        CRON_CMD="* * * * * $WATCHDOG_SCRIPT >> /var/log/pqt-watchdog.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_CMD") | crontab -

        echo -e "  ${GREEN}Watchdog installed for ${svc}${NC}"
    done

    echo -e "${GREEN}Watchdog checks every minute. Logs: /var/log/pqt-watchdog.log${NC}"
    read -p "Press Enter to continue..."
}

# ==========================================
# Speed Watchdog (Client/Iran Only)
# ==========================================
SPEED_WD_SCRIPT="/usr/local/bin/pqt-speed-watchdog.sh"
SPEED_WD_SERVICE="pqt-speed-watchdog"
SPEED_WD_LOG="/var/log/pqt-speed-watchdog.log"

deploy_speed_watchdog() {
    echo -e "${BLUE}--- Deploy Speed Watchdog (Client/Iran) ---${NC}"
    echo ""

    # Check for client services
    local client_svcs=()
    for f in /etc/systemd/system/pqt-client-*.service; do
        [[ ! -f "$f" ]] && continue
        client_svcs+=("$(basename "$f" .service)")
    done

    if [[ ${#client_svcs[@]} -eq 0 ]]; then
        echo -e "${RED}No PQT client services found!${NC}"
        echo -e "${YELLOW}Speed watchdog only works on client (Iran) side.${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${CYAN}Detected client tunnels:${NC}"
    for s in "${client_svcs[@]}"; do
        echo -e "  ${GREEN}*${NC} $s"
    done
    echo ""

    # Threshold
    read -p "Min upload speed threshold (Mbps) [5]: " THRESHOLD
    THRESHOLD=${THRESHOLD:-5}


    # Detect main network interface
    local NET_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$NET_IF" ]]; then
        NET_IF="eth0"
    fi
    read -p "Network interface [${NET_IF}]: " INPUT_IF
    [[ ! -z "$INPUT_IF" ]] && NET_IF="$INPUT_IF"

    echo ""
    echo -e "${YELLOW}Settings:${NC}"
    echo -e "  Threshold : ${THRESHOLD} Mbps"
    echo -e "  Check     : every 1 second"
    echo -e "  Interface : ${NET_IF}"
    echo -e "  Services  : ${client_svcs[*]}"
    echo ""

    # Build services list string
    local svc_list=""
    for s in "${client_svcs[@]}"; do
        svc_list="${svc_list} \"${s}\""
    done

    # Generate watchdog script
    cat > "${SPEED_WD_SCRIPT}" << 'HEADER'
#!/bin/bash
# PQT Speed Watchdog — Client (Iran) Only
# Monitors upload speed and restarts tunnels if below threshold
HEADER

    cat >> "${SPEED_WD_SCRIPT}" << EOF

THRESHOLD_MBPS=${THRESHOLD}
INTERFACE="${NET_IF}"
LOG_FILE="${SPEED_WD_LOG}"
CLIENT_SERVICES=(${svc_list})
FAIL_COUNT=0
FAIL_LIMIT=3

mkdir -p \$(dirname \$LOG_FILE)
echo "[\$(date)] Speed watchdog started. Threshold=\${THRESHOLD_MBPS}Mbps Interface=\${INTERFACE}" >> \$LOG_FILE

PREV_TX=\$(cat /sys/class/net/\${INTERFACE}/statistics/tx_bytes 2>/dev/null || echo 0)

while true; do
    sleep 1

    CUR_TX=\$(cat /sys/class/net/\${INTERFACE}/statistics/tx_bytes 2>/dev/null)
    if [[ -z "\$CUR_TX" ]]; then
        continue
    fi

    DIFF=\$(( CUR_TX - PREV_TX ))
    PREV_TX=\$CUR_TX

    # bytes/sec -> Mbps
    SPEED_MBPS=\$(echo "scale=2; \$DIFF * 8 / 1000000" | bc 2>/dev/null || echo "0")

    IS_LOW=\$(echo "\$SPEED_MBPS < \$THRESHOLD_MBPS" | bc 2>/dev/null || echo "0")

    if [[ "\$IS_LOW" == "1" ]]; then
        FAIL_COUNT=\$((FAIL_COUNT + 1))

        if [[ \$FAIL_COUNT -ge \$FAIL_LIMIT ]]; then
            echo "[\$(date)] LOW SPEED for \${FAIL_COUNT}s (\${SPEED_MBPS} Mbps). RESTARTING..." >> \$LOG_FILE
            for svc in "\${CLIENT_SERVICES[@]}"; do
                systemctl restart "\$svc"
                echo "[\$(date)] Restarted: \$svc" >> \$LOG_FILE
            done
            FAIL_COUNT=0
            sleep 10
        fi
    else
        FAIL_COUNT=0
    fi
done
EOF

    chmod +x "${SPEED_WD_SCRIPT}"

    # Create systemd service
    cat > "/etc/systemd/system/${SPEED_WD_SERVICE}.service" << EOF
[Unit]
Description=PQT Speed Watchdog (Client/Iran)
After=network.target

[Service]
Type=simple
ExecStart=${SPEED_WD_SCRIPT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SPEED_WD_SERVICE}" &>/dev/null

    echo -e "${GREEN}Speed watchdog deployed and started!${NC}"
    echo -e "${CYAN}Log: ${SPEED_WD_LOG}${NC}"
    read -p "Press Enter to continue..."
}

speed_watchdog_status() {
    echo -e "${BLUE}--- Speed Watchdog Status ---${NC}"
    echo ""

    if [[ ! -f "/etc/systemd/system/${SPEED_WD_SERVICE}.service" ]]; then
        echo -e "${YELLOW}Speed watchdog is not installed.${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${CYAN}Service Status:${NC}"
    systemctl status "${SPEED_WD_SERVICE}" --no-pager -l 2>/dev/null | head -10
    echo ""

    echo -e "${CYAN}Last 20 Log Lines:${NC}"
    if [[ -f "${SPEED_WD_LOG}" ]]; then
        tail -20 "${SPEED_WD_LOG}"
    else
        echo -e "${YELLOW}No log file yet.${NC}"
    fi
    echo ""
    read -p "Press Enter to continue..."
}

remove_speed_watchdog() {
    echo -e "${BLUE}--- Remove Speed Watchdog ---${NC}"
    echo ""

    if [[ ! -f "/etc/systemd/system/${SPEED_WD_SERVICE}.service" ]]; then
        echo -e "${YELLOW}Speed watchdog is not installed.${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Remove speed watchdog? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop "${SPEED_WD_SERVICE}" 2>/dev/null
        systemctl disable "${SPEED_WD_SERVICE}" 2>/dev/null
        rm -f "/etc/systemd/system/${SPEED_WD_SERVICE}.service"
        rm -f "${SPEED_WD_SCRIPT}"
        systemctl daemon-reload
        echo -e "${GREEN}Speed watchdog removed.${NC}"
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
    read -p "Press Enter to continue..."
}

# ==========================================
# Uninstall Service
# ==========================================
uninstall_menu() {
    echo -e "${BLUE}--- Uninstall PQT Service ---${NC}"

    local services=()
    local i=1
    for f in /etc/systemd/system/pqt-*.service; do
        [[ ! -f "$f" ]] && continue
        local svc=$(basename "$f" .service)
        services+=("$svc")
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $i) ${GREEN}[ON]${NC}  $svc"
        else
            echo -e "  $i) ${RED}[OFF]${NC} $svc"
        fi
        i=$((i+1))
    done

    if [[ ${#services[@]} -eq 0 ]]; then
        echo -e "${RED}No PQT services found${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "  A) Remove ALL"
    echo "  0) Cancel"

    read -p "Select: " CHOICE
    [[ "$CHOICE" == "0" || -z "$CHOICE" ]] && return

    if [[ "$CHOICE" =~ ^[Aa]$ ]]; then
        read -p "Remove ALL PQT services? (yes/NO): " confirm
        [[ "$confirm" != "yes" ]] && return

        for svc in "${services[@]}"; do
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            rm -f "/etc/systemd/system/${svc}.service"
            rm -f "/usr/local/bin/watchdog-${svc}.sh"
            crontab -l 2>/dev/null | grep -v "watchdog-${svc}" | crontab - 2>/dev/null

            # Remove config
            local cfg_name=$(echo "$svc" | sed 's/^pqt-//')
            rm -f "${CONFIG_DIR}/${cfg_name}.yaml"
        done
        systemctl daemon-reload
        echo -e "${GREEN}All PQT services removed${NC}"
    else
        local idx=$((CHOICE - 1))
        if [[ $idx -lt 0 || $idx -ge ${#services[@]} ]]; then
            echo -e "${RED}Invalid choice${NC}"
            return
        fi

        local svc="${services[$idx]}"
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "/etc/systemd/system/${svc}.service"
        rm -f "/usr/local/bin/watchdog-${svc}.sh"
        crontab -l 2>/dev/null | grep -v "watchdog-${svc}" | crontab - 2>/dev/null

        local cfg_name=$(echo "$svc" | sed 's/^pqt-//')
        rm -f "${CONFIG_DIR}/${cfg_name}.yaml"

        systemctl daemon-reload
        echo -e "${GREEN}Service '${svc}' removed${NC}"
    fi
    read -p "Press Enter to continue..."
}

# ==========================================
# Full Uninstall
# ==========================================
full_uninstall() {
    echo -e "${RED}FULL UNINSTALL${NC}"
    echo "Removes: all services + PQT binary + configs + watchdogs + cron + logs"
    read -p "Are you sure? (yes/NO): " confirm
    [[ "$confirm" != "yes" ]] && return

    for f in /etc/systemd/system/pqt-*.service; do
        [[ ! -f "$f" ]] && continue
        local svc=$(basename "$f" .service)
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$f"
        rm -f "/usr/local/bin/watchdog-${svc}.sh"
    done

    rm -f "$PQT_BIN"
    rm -rf "$CONFIG_DIR"
    rm -rf "$LOG_DIR"
    crontab -l 2>/dev/null | grep -v "pqt-watchdog\|watchdog-pqt" | crontab - 2>/dev/null
    systemctl daemon-reload

    echo -e "${GREEN}PQT completely removed!${NC}"
    exit 0
}

# ==========================================
# Show Config
# ==========================================
show_config() {
    echo -e "${BLUE}--- View Config File ---${NC}"

    local configs=()
    local i=1
    for cfg in ${CONFIG_DIR}/*.yaml; do
        [[ ! -f "$cfg" ]] && continue
        configs+=("$cfg")
        echo "  $i) $(basename "$cfg")"
        i=$((i+1))
    done

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${RED}No config files found${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "  0) Cancel"
    read -p "Select: " CHOICE
    [[ "$CHOICE" == "0" || -z "$CHOICE" ]] && return

    local idx=$((CHOICE - 1))
    if [[ $idx -lt 0 || $idx -ge ${#configs[@]} ]]; then
        echo -e "${RED}Invalid choice${NC}"
        return
    fi

    echo ""
    echo -e "${CYAN}=== $(basename "${configs[$idx]}") ===${NC}"
    cat "${configs[$idx]}"
    echo ""
    read -p "Press Enter to continue..."
}

# ==========================================
# Edit Config
# ==========================================
edit_config() {
    echo -e "${BLUE}--- Edit Config File ---${NC}"

    local configs=()
    local i=1
    for cfg in ${CONFIG_DIR}/*.yaml; do
        [[ ! -f "$cfg" ]] && continue
        configs+=("$cfg")
        echo "  $i) $(basename "$cfg")"
        i=$((i+1))
    done

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${RED}No config files found${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "  0) Cancel"
    read -p "Select config to edit: " CHOICE
    [[ "$CHOICE" == "0" || -z "$CHOICE" ]] && return

    local idx=$((CHOICE - 1))
    if [[ $idx -lt 0 || $idx -ge ${#configs[@]} ]]; then
        echo -e "${RED}Invalid choice${NC}"
        return
    fi

    local cfg_file="${configs[$idx]}"

    # Pick editor
    local EDITOR_CMD=""
    if command -v nano &>/dev/null; then
        EDITOR_CMD="nano"
    elif command -v vi &>/dev/null; then
        EDITOR_CMD="vi"
    elif command -v vim &>/dev/null; then
        EDITOR_CMD="vim"
    else
        echo -e "${RED}No editor found (nano/vi/vim)${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${CYAN}Opening ${cfg_file} with ${EDITOR_CMD}...${NC}"
    $EDITOR_CMD "$cfg_file"

    # Ask to restart related service
    local svc_name="pqt-$(basename "$cfg_file" .yaml)"
    if systemctl list-unit-files "${svc_name}.service" &>/dev/null; then
        echo ""
        read -p "Restart service '${svc_name}' to apply changes? (Y/n): " restart_ans
        if [[ ! "$restart_ans" =~ ^[Nn]$ ]]; then
            systemctl restart "$svc_name"
            echo -e "${GREEN}Service '${svc_name}' restarted${NC}"
        fi
    fi

    read -p "Press Enter to continue..."
}

# ==========================================
# Restart Service
# ==========================================
restart_service() {
    echo -e "${BLUE}--- Restart PQT Service ---${NC}"

    local services=()
    local i=1
    for f in /etc/systemd/system/pqt-*.service; do
        [[ ! -f "$f" ]] && continue
        local svc=$(basename "$f" .service)
        services+=("$svc")
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $i) ${GREEN}[ON]${NC}  $svc"
        else
            echo -e "  $i) ${RED}[OFF]${NC} $svc"
        fi
        i=$((i+1))
    done

    if [[ ${#services[@]} -eq 0 ]]; then
        echo -e "${RED}No PQT services found${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "  A) Restart ALL"
    echo "  0) Cancel"

    read -p "Select: " CHOICE
    [[ "$CHOICE" == "0" || -z "$CHOICE" ]] && return

    if [[ "$CHOICE" =~ ^[Aa]$ ]]; then
        for svc in "${services[@]}"; do
            systemctl restart "$svc"
            echo -e "  ${GREEN}Restarted: $svc${NC}"
        done
    else
        local idx=$((CHOICE - 1))
        if [[ $idx -lt 0 || $idx -ge ${#services[@]} ]]; then
            echo -e "${RED}Invalid choice${NC}"
            return
        fi
        systemctl restart "${services[$idx]}"
        echo -e "${GREEN}Restarted: ${services[$idx]}${NC}"
    fi
    read -p "Press Enter to continue..."
}

# ==========================================
# Main Menu
# ==========================================
while true; do
    clear
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  ${BOLD}PQT QUIC Tunnel Manager v1.0${NC}"
    echo -e "${GREEN}  QUIC + Brutal CC + FakeTLS + XOR${NC}"
    echo -e "${GREEN}  Multi-Tunnel Support${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}--- Setup ---${NC}"
    echo "  1) Install PQT"
    echo "  2) Reinstall PQT (Delete + Download)"
    echo "  3) Setup Server (Kharej)"
    echo "  4) Setup Client (Iran) + Port Forward"
    echo "  5) Add Ports to Existing Tunnel"
    echo ""
    echo -e "${CYAN}--- Management ---${NC}"
    echo "  6) List Tunnels / Status"
    echo "  7) Check Connection"
    echo "  8) View Logs"
    echo "  9) View Config"
    echo "  10) Edit Config"
    echo "  11) Restart Service"
    echo ""
    echo -e "${CYAN}--- Watchdog ---${NC}"
    echo "  12) Setup Watchdog (Auto-Reconnect)"
    echo ""
    echo -e "${CYAN}--- Uninstall ---${NC}"
    echo "  13) Uninstall Service"
    echo "  14) Full Uninstall (Everything)"
    echo ""
    echo -e "${CYAN}--- Speed Watchdog (Iran/Client) ---${NC}"
    echo "  15) Deploy Speed Watchdog"
    echo "  16) Speed Watchdog Status & Logs"
    echo "  17) Remove Speed Watchdog"
    echo ""
    echo "  0) Exit"
    echo ""
    read -p "Select: " OPTION

    case $OPTION in
        1)
            install_pqt
            read -p "Press Enter to continue..."
            ;;
        2)
            reinstall_pqt
            read -p "Press Enter to continue..."
            ;;
        3)
            install_pqt
            setup_server
            ;;
        4)
            install_pqt
            setup_client
            ;;
        5)
            add_ports
            ;;
        6)
            list_tunnels
            ;;
        7)
            check_connection
            ;;
        8)
            view_logs
            ;;
        9)
            show_config
            ;;
        10)
            edit_config
            ;;
        11)
            restart_service
            ;;
        12)
            setup_watchdog
            ;;
        15)
            deploy_speed_watchdog
            ;;
        16)
            speed_watchdog_status
            ;;
        17)
            remove_speed_watchdog
            ;;
        13)
            uninstall_menu
            ;;
        14)
            full_uninstall
            ;;
        0)
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            ;;
    esac
done

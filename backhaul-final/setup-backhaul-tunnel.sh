#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  BACKHAUL TUNNEL SETUP - TUN/IPX Mode                        ║
# ║  Iran (Server) & Kharej (Client) Setup Script                ║
# ╚════════════════════════════════════════════════════════════════╝

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────
CORE_DIR="/root/backhaul-core"
BINARY_PATH="${CORE_DIR}/backhaul_premium"
SYSTEMD_DIR="/etc/systemd/system"

# ─── Default PSK (fixed across all tunnels, can be overridden) ───
DEFAULT_PSK="pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="

# ─── Helpers ──────────────────────────────────────────────────────

print_line() {
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
}

print_double_line() {
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║     BACKHAUL TUNNEL SETUP - TUN/IPX Mode      ║"
    echo " ╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

msg_info() {
    echo -e " ${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e " ${GREEN}[OK]${NC} $1"
}

msg_warn() {
    echo -e " ${YELLOW}[WARN]${NC} $1"
}

msg_err() {
    echo -e " ${RED}[ERR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        msg_err "This script must be run as root."
        exit 1
    fi
}

check_binary() {
    if [ ! -f "${BINARY_PATH}" ]; then
        msg_err "Binary not found at ${BINARY_PATH}"
        msg_warn "Please place 'backhaul_premium' binary in ${CORE_DIR}/"
        exit 1
    fi
    if [ ! -x "${BINARY_PATH}" ]; then
        chmod +x "${BINARY_PATH}"
        msg_info "Made binary executable."
    fi
}

# ─── Auto-Detect Network Interface ───────────────────────────────

detect_interface() {
    # Try to find the default route interface
    local iface=""
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)

    if [ -z "$iface" ]; then
        # Fallback: first non-lo interface that is UP
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    fi

    if [ -z "$iface" ]; then
        iface="eth0"
    fi

    echo "$iface"
}

# ─── Input Helpers ────────────────────────────────────────────────

read_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [ -n "$default" ]; then
        read -p "  ${prompt} [${default}]: " input_val
        eval "${var_name}=\"${input_val:-$default}\""
    else
        read -p "  ${prompt}: " input_val
        eval "${var_name}=\"${input_val}\""
    fi
}

# ─── Review Box ───────────────────────────────────────────────────

show_review_box() {
    local mode="$1"  # iran or kharej

    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  REVIEW YOUR SETTINGS${NC}"
    print_double_line
    echo ""
    echo -e "  ${MAGENTA}Tunnel ID:${NC}       ${WHITE}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "  ${MAGENTA}Tunnel Name:${NC}     ${WHITE}${BOLD}${TUN_NAME}${NC}"
    echo -e "  ${MAGENTA}Health Port:${NC}     ${WHITE}${BOLD}${HEALTH_PORT}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}TUN Network:${NC}"
    if [ "$mode" = "iran" ]; then
        echo -e "    Local  (Iran):   ${GREEN}${BOLD}10.10.${TUNNEL_ID}.1/24${NC}"
        echo -e "    Remote (Kharej): ${BLUE}${BOLD}10.10.${TUNNEL_ID}.2/24${NC}"
    else
        echo -e "    Local  (Kharej): ${GREEN}${BOLD}10.10.${TUNNEL_ID}.2/24${NC}"
        echo -e "    Remote (Iran):   ${BLUE}${BOLD}10.10.${TUNNEL_ID}.1/24${NC}"
    fi
    echo -e "    MTU:             ${WHITE}${MTU}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}IPX Network:${NC}"
    echo -e "    Listen IP:       ${GREEN}${BOLD}${LISTEN_IP}${NC}"
    echo -e "    Dest IP:         ${BLUE}${BOLD}${DST_IP}${NC}"
    echo -e "    Interface:       ${WHITE}${BOLD}${INTERFACE}${NC}  ${DIM}(auto-detected)${NC}"
    echo -e "    Mode:            ${YELLOW}${BOLD}$([ \"$mode\" = \"iran\" ] && echo 'server' || echo 'client')${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Security:${NC}"
    echo -e "    Encryption:      ${WHITE}${ENCRYPTION}${NC}"
    echo -e "    Algorithm:       ${WHITE}${ALGORITHM}${NC}"
    echo -e "    PSK:             ${YELLOW}${BOLD}${PSK}${NC}"
    echo -e "    KDF Iterations:  ${WHITE}${KDF_ITERATIONS}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Transport:${NC}"
    echo -e "    Heartbeat:       ${WHITE}${HEARTBEAT_INTERVAL}s interval / ${HEARTBEAT_TIMEOUT}s timeout${NC}"
    echo -e "    Log Level:       ${WHITE}${LOG_LEVEL}${NC}"
    echo ""
    print_double_line
    echo ""
}

# ─── Config Generators ───────────────────────────────────────────

generate_iran_config() {
    local config_file="$1"
    cat > "${config_file}" << EOF
[transport]
type = "tun"
heartbeat_interval = ${HEARTBEAT_INTERVAL}
heartbeat_timeout = ${HEARTBEAT_TIMEOUT}

[tun]
encapsulation = "ipx"
name = "${TUN_NAME}"
local_addr = "${LOCAL_TUN_ADDR}"
remote_addr = "${REMOTE_TUN_ADDR}"
health_port = ${HEALTH_PORT}
mtu = ${MTU}

[ipx]
mode = "server"
profile = "bip"
listen_ip = "${LISTEN_IP}"
dst_ip = "${DST_IP}"
interface = "${INTERFACE}"

[security]
enable_encryption = ${ENCRYPTION}
algorithm = "${ALGORITHM}"
psk = "${PSK}"
kdf_iterations = ${KDF_ITERATIONS}

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 10_000
so_sndbuf = 0
batch_size = 2048

[logging]
log_level = "${LOG_LEVEL}"

[ports]
forwarder = "backhaul"
mapping = [
]
EOF
}

generate_kharej_config() {
    local config_file="$1"
    cat > "${config_file}" << EOF
[transport]
type = "tun"
heartbeat_interval = ${HEARTBEAT_INTERVAL}
heartbeat_timeout = ${HEARTBEAT_TIMEOUT}

[tun]
encapsulation = "ipx"
name = "${TUN_NAME}"
local_addr = "${LOCAL_TUN_ADDR}"
remote_addr = "${REMOTE_TUN_ADDR}"
health_port = ${HEALTH_PORT}
mtu = ${MTU}

[ipx]
mode = "client"
profile = "bip"
listen_ip = "${LISTEN_IP}"
dst_ip = "${DST_IP}"
interface = "${INTERFACE}"

[security]
enable_encryption = ${ENCRYPTION}
algorithm = "${ALGORITHM}"
psk = "${PSK}"
kdf_iterations = ${KDF_ITERATIONS}

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 10_000
so_sndbuf = 0
batch_size = 2048

[logging]
log_level = "${LOG_LEVEL}"
EOF
}

create_systemd_service() {
    local service_name="$1"
    local config_file="$2"
    local description="$3"
    local service_path="${SYSTEMD_DIR}/${service_name}.service"

    cat > "${service_path}" << EOF
[Unit]
Description=${description}
After=network.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} -c ${config_file}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}" &>/dev/null
    systemctl start "${service_name}"
}

# ─── Setup Functions ─────────────────────────────────────────────

setup_iran() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup Iran Server (IPX Server Mode)${NC}"
    echo ""
    print_line

    # Auto-detect interface
    INTERFACE=$(detect_interface)

    # ── Step 1: Tunnel Identity ──
    echo -e "\n ${MAGENTA}${BOLD}[1/4] Tunnel Identity${NC}"
    read_input "Tunnel ID (e.g. 10, 12, 50)" "" TUNNEL_ID
    if [ -z "$TUNNEL_ID" ]; then
        msg_err "Tunnel ID is required!"
        exit 1
    fi
    read_input "Tunnel name" "backhaul${TUNNEL_ID}" TUN_NAME
    read_input "Health port" "1234" HEALTH_PORT
    read_input "MTU" "1320" MTU

    # Auto-generate TUN addresses from ID
    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"

    # ── Step 2: IPX Network ──
    echo -e "\n ${MAGENTA}${BOLD}[2/4] IPX Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${INTERFACE}${NC}"
    read_input "Change interface? (press Enter to keep)" "${INTERFACE}" INTERFACE
    read_input "Listen IP (this server's public IP)" "" LISTEN_IP
    if [ -z "$LISTEN_IP" ]; then
        msg_err "Listen IP is required!"
        exit 1
    fi
    read_input "Destination IP (Kharej public IP)" "" DST_IP
    if [ -z "$DST_IP" ]; then
        msg_err "Destination IP is required!"
        exit 1
    fi

    # ── Step 3: Security ──
    echo -e "\n ${MAGENTA}${BOLD}[3/4] Security${NC}"
    read_input "Enable encryption (true/false)" "true" ENCRYPTION
    read_input "Algorithm" "aes-256-gcm" ALGORITHM
    echo -e "  ${DIM}Default PSK: ${DEFAULT_PSK}${NC}"
    read_input "PSK (Enter to use default)" "${DEFAULT_PSK}" PSK
    read_input "KDF iterations" "100000" KDF_ITERATIONS

    # ── Step 4: Transport ──
    echo -e "\n ${MAGENTA}${BOLD}[4/4] Transport & Logging${NC}"
    read_input "Heartbeat interval (sec)" "10" HEARTBEAT_INTERVAL
    read_input "Heartbeat timeout (sec)" "25" HEARTBEAT_TIMEOUT
    read_input "Log level (info/debug/warn/error)" "info" LOG_LEVEL

    # ── Review ──
    show_review_box "iran"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # ── Generate ──
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/iran${HEALTH_PORT}.toml"
    local service_name="backhaul-iran${HEALTH_PORT}"

    generate_iran_config "${config_file}"
    msg_ok "Config saved: ${config_file}"

    create_systemd_service "${service_name}" "${config_file}" "Backhaul Iran - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

    # ── Final Summary ──
    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Iran Server Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  Config:    ${BLUE}${config_file}${NC}"
    echo -e "  Service:   ${BLUE}${service_name}.service${NC}"
    echo ""
    echo -e " ${YELLOW}${BOLD}  For Kharej setup, use:${NC}"
    echo -e "    Tunnel ID:  ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "    Dest IP:    ${CYAN}${BOLD}${LISTEN_IP}${NC}"
    echo -e "    PSK:        ${CYAN}${BOLD}${PSK}${NC}"
    echo ""

    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

setup_kharej() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup Kharej Client (IPX Client Mode)${NC}"
    echo ""
    print_line

    # Auto-detect interface
    INTERFACE=$(detect_interface)

    # ── Step 1: Tunnel Identity ──
    echo -e "\n ${MAGENTA}${BOLD}[1/4] Tunnel Identity${NC}"
    read_input "Tunnel ID (must match Iran, e.g. 10, 12, 50)" "" TUNNEL_ID
    if [ -z "$TUNNEL_ID" ]; then
        msg_err "Tunnel ID is required!"
        exit 1
    fi
    read_input "Tunnel name" "back${TUNNEL_ID}" TUN_NAME
    read_input "Health port" "1234" HEALTH_PORT
    read_input "MTU" "1320" MTU

    # Auto-generate TUN addresses from ID (reversed for kharej)
    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"

    # ── Step 2: IPX Network ──
    echo -e "\n ${MAGENTA}${BOLD}[2/4] IPX Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${INTERFACE}${NC}"
    read_input "Change interface? (press Enter to keep)" "${INTERFACE}" INTERFACE
    read_input "Listen IP (this server's public IP)" "" LISTEN_IP
    if [ -z "$LISTEN_IP" ]; then
        msg_err "Listen IP is required!"
        exit 1
    fi
    read_input "Destination IP (Iran public IP)" "" DST_IP
    if [ -z "$DST_IP" ]; then
        msg_err "Destination IP is required!"
        exit 1
    fi

    # ── Step 3: Security ──
    echo -e "\n ${MAGENTA}${BOLD}[3/4] Security${NC}"
    read_input "Enable encryption (true/false)" "true" ENCRYPTION
    read_input "Algorithm" "aes-256-gcm" ALGORITHM
    echo -e "  ${DIM}Default PSK: ${DEFAULT_PSK}${NC}"
    read_input "PSK (Enter to use default, must match Iran)" "${DEFAULT_PSK}" PSK
    read_input "KDF iterations" "100000" KDF_ITERATIONS

    # ── Step 4: Transport ──
    echo -e "\n ${MAGENTA}${BOLD}[4/4] Transport & Logging${NC}"
    read_input "Heartbeat interval (sec)" "10" HEARTBEAT_INTERVAL
    read_input "Heartbeat timeout (sec)" "25" HEARTBEAT_TIMEOUT
    read_input "Log level (info/debug/warn/error)" "info" LOG_LEVEL

    # ── Review ──
    show_review_box "kharej"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # ── Generate ──
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/kharej${HEALTH_PORT}.toml"
    local service_name="backhaul-kharej${HEALTH_PORT}"

    generate_kharej_config "${config_file}"
    msg_ok "Config saved: ${config_file}"

    create_systemd_service "${service_name}" "${config_file}" "Backhaul Kharej - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

    # ── Final Summary ──
    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Kharej Client Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  Config:    ${BLUE}${config_file}${NC}"
    echo -e "  Service:   ${BLUE}${service_name}.service${NC}"
    echo ""

    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

# ─── Management Helpers ───────────────────────────────────────────

list_tunnels() {
    echo ""
    echo -e " ${CYAN}${BOLD}Active Backhaul Tunnels:${NC}"
    print_line

    local found=0
    local i=1
    TUNNEL_LIST=()

    for svc in $(systemctl list-units --type=service --all --no-legend | grep "backhaul-" | awk '{print $1}'); do
        found=1
        local name="${svc%.service}"
        local status=$(systemctl is-active "${name}" 2>/dev/null)
        TUNNEL_LIST+=("${name}")

        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${i})${NC} ${name}  ${GREEN}[active]${NC}"
        else
            echo -e "  ${RED}●${NC} ${BOLD}${i})${NC} ${name}  ${RED}[${status}]${NC}"
        fi
        ((i++))
    done

    if [ $found -eq 0 ]; then
        msg_warn "No backhaul tunnels found."
        return 1
    fi
    echo ""
    return 0
}

# Show tunnel list and let user pick one by number or name
pick_tunnel() {
    list_tunnels || return 1

    read -p "  Enter number or service name: " pick

    # If it's a number, resolve from list
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#TUNNEL_LIST[@]}" ]; then
        SELECTED_TUNNEL="${TUNNEL_LIST[$((pick-1))]}"
    else
        SELECTED_TUNNEL="$pick"
    fi

    # Validate
    if ! systemctl list-units --type=service --all --no-legend | grep -q "${SELECTED_TUNNEL}"; then
        msg_err "Service '${SELECTED_TUNNEL}' not found."
        return 1
    fi

    return 0
}

do_restart() {
    pick_tunnel || return
    systemctl restart "${SELECTED_TUNNEL}"
    msg_ok "${SELECTED_TUNNEL} restarted."
}

do_stop() {
    pick_tunnel || return
    systemctl stop "${SELECTED_TUNNEL}"
    msg_ok "${SELECTED_TUNNEL} stopped."
}

do_start() {
    pick_tunnel || return
    systemctl start "${SELECTED_TUNNEL}"
    systemctl enable "${SELECTED_TUNNEL}" &>/dev/null
    msg_ok "${SELECTED_TUNNEL} started & enabled."
}

do_disable() {
    pick_tunnel || return
    systemctl stop "${SELECTED_TUNNEL}" 2>/dev/null
    systemctl disable "${SELECTED_TUNNEL}" 2>/dev/null
    msg_ok "${SELECTED_TUNNEL} stopped & disabled. Config files kept."
}

do_logs() {
    pick_tunnel || return
    echo ""
    journalctl -u "${SELECTED_TUNNEL}" -n 50 --no-pager
}

do_live_logs() {
    pick_tunnel || return
    msg_info "Live logs for ${SELECTED_TUNNEL} (Ctrl+C to exit):"
    journalctl -u "${SELECTED_TUNNEL}" -f
}

do_view_config() {
    pick_tunnel || return
    local cfg=$(grep "ExecStart=" "${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service" 2>/dev/null | sed 's/.*-c //')
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
        echo ""
        print_line
        cat "$cfg"
        print_line
    else
        msg_err "Config file not found."
    fi
}

do_delete() {
    pick_tunnel || return
    echo ""
    echo -e " ${RED}${BOLD}This will permanently delete ${SELECTED_TUNNEL} and its config.${NC}"
    read -p "  Type 'DELETE' to confirm: " confirm
    if [ "$confirm" = "DELETE" ]; then
        systemctl stop "${SELECTED_TUNNEL}" 2>/dev/null
        systemctl disable "${SELECTED_TUNNEL}" 2>/dev/null
        local cfg=$(grep "ExecStart=" "${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service" 2>/dev/null | sed 's/.*-c //')
        rm -f "${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service"
        [ -n "$cfg" ] && rm -f "$cfg"
        systemctl daemon-reload
        msg_ok "${SELECTED_TUNNEL} deleted."
    else
        msg_warn "Cancelled."
    fi
}

# ─── Watchdog (Kharej Only) ────────────────────────────────────────

WATCHDOG_SCRIPT="/usr/local/bin/backhaul-watchdog.sh"
WATCHDOG_SERVICE="backhaul-watchdog"
WATCHDOG_SERVICE_FILE="${SYSTEMD_DIR}/${WATCHDOG_SERVICE}.service"
WATCHDOG_LOG="/var/log/backhaul-watchdog.log"

# Scan kharej configs and build "IP|SERVICE" targets
build_watchdog_targets() {
    local targets=()

    for toml_file in "${CORE_DIR}"/kharej*.toml; do
        [ -f "$toml_file" ] || continue

        local filename=$(basename "$toml_file")
        local svc_name="backhaul-${filename%.toml}"

        # Extract remote_addr from [tun] section
        local remote_addr=""
        local in_tun=0
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            [[ -z "$line" || "$line" == \#* ]] && continue

            if [[ "$line" == "[tun]" ]]; then
                in_tun=1
                continue
            elif [[ "$line" == \[* ]]; then
                in_tun=0
                continue
            fi

            if [ $in_tun -eq 1 ]; then
                if echo "$line" | grep -q '^remote_addr'; then
                    remote_addr=$(echo "$line" | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | cut -d'/' -f1)
                fi
            fi
        done < "$toml_file"

        if [ -n "$remote_addr" ]; then
            targets+=("${remote_addr}|${svc_name}")
        fi
    done

    echo "${targets[@]}"
}

deploy_watchdog() {
    echo ""
    echo -e " ${GREEN}${BOLD}>>> Deploy Watchdog (Kharej Only)${NC}"
    print_line

    # Build targets
    local raw_targets
    raw_targets=$(build_watchdog_targets)

    if [ -z "$raw_targets" ]; then
        msg_err "No kharej tunnel configs found in ${CORE_DIR}/"
        msg_warn "Watchdog only works on Kharej (client) side."
        return
    fi

    # Format for TARGETS array in script
    local targets_formatted=""
    for t in $raw_targets; do
        targets_formatted="${targets_formatted} \"${t}\""
    done

    echo ""
    msg_info "Detected targets:"
    for t in $raw_targets; do
        local ip="${t%%|*}"
        local svc="${t#*|}"
        echo -e "    ${GREEN}●${NC} ${BOLD}${svc}${NC}  →  ping ${CYAN}${ip}${NC}"
    done
    echo ""

    # Generate watchdog script (exactly matching backhaul-manager-app)
    cat > "${WATCHDOG_SCRIPT}" << 'WATCHDOG_HEADER'
#!/bin/bash
# Backhaul Watchdog
# Generated by Backhaul Setup Script

WATCHDOG_HEADER

    cat >> "${WATCHDOG_SCRIPT}" << EOF
TARGETS=(${targets_formatted})
LOG_FILE="${WATCHDOG_LOG}"
mkdir -p \$(dirname \$LOG_FILE)

echo "[\$(date)] Watchdog started with \${#TARGETS[@]} targets." >> \$LOG_FILE

while true; do
  for item in "\${TARGETS[@]}"; do
    IP="\${item%%|*}"
    SVC="\${item#*|}"

    # Logic: 6 Pings. If 3 or more fail, RESTART.
    # We allow 2 seconds per ping.
    # Total 6. If Received <= 3 (means 3,4,5,6 failed), then Restart.

    LOSS_COUNT=0
    for i in {1..6}; do
        if ! ping -c 1 -W 2 "\$IP" > /dev/null 2>&1; then
            ((LOSS_COUNT++))
        fi
    done

    # Threshold: If 3 or more failed
    if [ "\$LOSS_COUNT" -ge 3 ]; then
       echo "[\$(date)] FAIL: \$IP had \$LOSS_COUNT/6 packet loss. Restarting \$SVC..." >> \$LOG_FILE
       systemctl restart "\$SVC"
       sleep 5
    fi
  done

  # Run every 60 seconds (1 minute)
  sleep 60
done
EOF

    chmod +x "${WATCHDOG_SCRIPT}"
    msg_ok "Watchdog script created: ${WATCHDOG_SCRIPT}"

    # Create systemd service
    cat > "${WATCHDOG_SERVICE_FILE}" << EOF
[Unit]
Description=Backhaul Connectivity Watchdog
After=network.target

[Service]
Type=simple
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${WATCHDOG_SERVICE}" &>/dev/null
    msg_ok "Watchdog service deployed and started."

    echo ""
    echo -e " ${CYAN}Watchdog status:${NC}"
    systemctl status "${WATCHDOG_SERVICE}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

remove_watchdog() {
    echo ""
    if [ ! -f "${WATCHDOG_SERVICE_FILE}" ]; then
        msg_warn "Watchdog is not installed."
        return
    fi

    read -p "  Type 'DELETE' to remove watchdog: " confirm
    if [ "$confirm" = "DELETE" ]; then
        systemctl stop "${WATCHDOG_SERVICE}" 2>/dev/null
        systemctl disable "${WATCHDOG_SERVICE}" 2>/dev/null
        rm -f "${WATCHDOG_SERVICE_FILE}"
        rm -f "${WATCHDOG_SCRIPT}"
        systemctl daemon-reload
        msg_ok "Watchdog removed."
    else
        msg_warn "Cancelled."
    fi
}

watchdog_status() {
    echo ""
    if [ ! -f "${WATCHDOG_SERVICE_FILE}" ]; then
        msg_warn "Watchdog is not installed."
        return
    fi

    echo -e " ${CYAN}${BOLD}Watchdog Status:${NC}"
    systemctl status "${WATCHDOG_SERVICE}" --no-pager -l 2>/dev/null | head -10
    echo ""
    echo -e " ${CYAN}Last 20 Watchdog Logs:${NC}"
    if [ -f "${WATCHDOG_LOG}" ]; then
        tail -20 "${WATCHDOG_LOG}"
    else
        msg_info "No watchdog log file yet."
    fi
}

# ─── Main Menu ────────────────────────────────────────────────────

main_menu() {
    while true; do
        print_header
        echo -e " ${BOLD}${WHITE}Setup${NC}"
        echo -e "  ${GREEN}1)${NC} Setup Iran Server (IPX Server)"
        echo -e "  ${BLUE}2)${NC} Setup Kharej Client (IPX Client)"
        echo ""
        echo -e " ${BOLD}${WHITE}Tunnels${NC}"
        echo -e "  ${CYAN}3)${NC} List All Tunnels"
        echo -e "  ${GREEN}4)${NC} Start a Tunnel"
        echo -e "  ${YELLOW}5)${NC} Restart a Tunnel"
        echo -e "  ${YELLOW}6)${NC} Stop a Tunnel"
        echo -e "  ${MAGENTA}7)${NC} Stop & Disable (keep files)"
        echo ""
        echo -e " ${BOLD}${WHITE}Info & Logs${NC}"
        echo -e "  ${CYAN}8)${NC} View Last 50 Logs"
        echo -e "  ${CYAN}9)${NC} View Live Logs"
        echo -e "  ${BLUE}10)${NC} View Config"
        echo ""
        echo -e " ${BOLD}${WHITE}Watchdog (Kharej)${NC}"
        echo -e "  ${GREEN}12)${NC} Deploy Watchdog"
        echo -e "  ${CYAN}13)${NC} Watchdog Status & Logs"
        echo -e "  ${RED}14)${NC} Remove Watchdog"
        echo ""
        echo -e " ${BOLD}${WHITE}Danger${NC}"
        echo -e "  ${RED}11)${NC} Delete a Tunnel"
        echo ""
        echo -e "  ${DIM}0)${NC} Exit"
        echo ""
        read -p "  Select: " choice

        case $choice in
            1)  setup_iran ;;
            2)  setup_kharej ;;
            3)  list_tunnels ;;
            4)  do_start ;;
            5)  do_restart ;;
            6)  do_stop ;;
            7)  do_disable ;;
            8)  do_logs ;;
            9)  do_live_logs ;;
            10) do_view_config ;;
            11) do_delete ;;
            12) deploy_watchdog ;;
            13) watchdog_status ;;
            14) remove_watchdog ;;
            0)
                echo -e "\n ${GREEN}Goodbye!${NC}\n"
                exit 0
                ;;
            *)
                msg_err "Invalid option."
                ;;
        esac

        echo ""
        read -p "  Press Enter to continue..."
    done
}

# ─── Entry Point ──────────────────────────────────────────────────

check_root
check_binary
main_menu


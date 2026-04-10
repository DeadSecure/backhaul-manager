#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  SPOOF TUNNEL CORE - Setup & Manager                         ║
# ║  Iran (Server) & Kharej (Client) - Peer-to-Peer IPX Tunnel   ║
# ╚════════════════════════════════════════════════════════════════╝

VERSION="2.1.0"

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
CORE_DIR="/root/spoof-tunnel"
BINARY_SPOOF="${CORE_DIR}/spoof-tunnel-core"
BINARY_BACKHAUL="${CORE_DIR}/backhaul_premium"
BINARY_PATH="${BINARY_SPOOF}"  # default engine
SYSTEMD_DIR="/etc/systemd/system"

# ─── Download Sources ─────────────────────────────────────────────
MIRROR_URL="http://79.175.188.86:8443/spoof-tunnel"
GITHUB_URL="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/spoof-tunnel-manager/tunnel-core"
BACKHAUL_DOWNLOAD_URL="http://79.175.188.86:8443/backhaul/backhaul_premium"

# ─── Helpers ──────────────────────────────────────────────────────

print_line() {
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
}

print_double_line() {
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

print_header() {
    clear
    local server_ip
    server_ip=$(detect_public_ip 2>/dev/null)
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║     SPOOF TUNNEL CORE - Setup & Manager       ║"
    echo -e " ║     ${DIM}v${VERSION}${CYAN}${BOLD}                                      ║"
    echo " ╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
    if [ -n "$server_ip" ]; then
        echo -e "  ${DIM}Server IP: ${WHITE}${BOLD}${server_ip}${NC}"
    fi
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
        msg_warn "Binary not found at ${BINARY_PATH}"
        msg_info "Use menu option 12 to download, or place 'spoof-tunnel-core' in ${CORE_DIR}/"
        return 1
    fi
    if [ ! -x "${BINARY_PATH}" ]; then
        chmod +x "${BINARY_PATH}"
        msg_info "Made binary executable."
    fi
    return 0
}

# ─── Download Binary ───────────────────────────────────────────

download_binary() {
    echo ""
    echo -e " ${GREEN}${BOLD}>>> Download Spoof Tunnel Core Binary${NC}"
    print_line
    echo ""
    echo -e "  ${WHITE}1)${NC} Download from ${CYAN}Iran Mirror${NC}       ${DIM}(79.175.188.86 — fast for Iran)${NC}"
    echo -e "  ${WHITE}2)${NC} Download from ${BLUE}GitHub${NC}            ${DIM}(github.com/alireza-2030 — international)${NC}"
    echo -e "  ${DIM}0)${NC} Cancel"
    echo ""
    read -p "  Select mirror: " mirror_choice

    mkdir -p "${CORE_DIR}"

    local url=""
    case $mirror_choice in
        1) url="${MIRROR_URL}/spoof-tunnel-core" ;;
        2) url="${GITHUB_URL}/spoof-tunnel-core" ;;
        0) return ;;
        *) msg_err "Invalid option."; return ;;
    esac

    msg_info "Downloading: ${url}"
    echo ""
    if curl -L --max-time 60 --progress-bar -o "${BINARY_PATH}" "${url}"; then
        local fsize=$(stat -c%s "${BINARY_PATH}" 2>/dev/null || stat -f%z "${BINARY_PATH}" 2>/dev/null)
        if [ "${fsize:-0}" -gt 500000 ]; then
            chmod +x "${BINARY_PATH}"
            msg_ok "Binary installed: ${BINARY_PATH} ($(( fsize / 1024 / 1024 )) MB)"
        else
            msg_err "Downloaded file is too small, download may have failed."
            rm -f "${BINARY_PATH}" 2>/dev/null
        fi
    else
        msg_err "Download failed."
    fi
}

# ─── Auto-Detect ──────────────────────────────────────────────────

detect_interface() {
    local iface=""
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    fi
    echo "${iface:-eth0}"
}

detect_public_ip() {
    local iface
    iface=$(detect_interface)
    local ip=""
    if [ -n "$iface" ]; then
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# ─── Input Helper ─────────────────────────────────────────────────

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
    local mode="$1"

    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  REVIEW YOUR SETTINGS${NC}"
    print_double_line
    echo ""
    echo -e "  ${MAGENTA}Tunnel ID:${NC}       ${WHITE}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "  ${MAGENTA}Tunnel Name:${NC}     ${WHITE}${BOLD}${TUN_NAME}${NC}"
    echo -e "  ${MAGENTA}Tunnel Port:${NC}     ${WHITE}${BOLD}${TUNNEL_PORT}${NC}"
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
    echo -e "  ${CYAN}IPX Spoof Network:${NC}"
    echo -e "    Listen IP:       ${GREEN}${BOLD}${LISTEN_IP}${NC}"
    echo -e "    Dest IP:         ${BLUE}${BOLD}${DST_IP}${NC}"
    echo -e "    Spoof Src IP:    ${MAGENTA}${BOLD}${SPOOF_SRC_IP}${NC}"
    echo -e "    Spoof Dst IP:    ${MAGENTA}${BOLD}${SPOOF_DST_IP}${NC}"
    echo -e "    Interface:       ${WHITE}${BOLD}${INTERFACE}${NC}  ${DIM}(auto-detected)${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Transport:${NC}"
    echo -e "    Heartbeat:       ${WHITE}${HEARTBEAT_INTERVAL}s interval / ${HEARTBEAT_TIMEOUT}s timeout${NC}"
    echo -e "    Workers:         ${WHITE}${WORKERS} (0=auto)${NC}"
    echo -e "    Channel Size:    ${WHITE}${CHANNEL_SIZE}${NC}"
    echo ""
    print_double_line
    echo ""
}

# ─── Config Generator ────────────────────────────────────────────

generate_config() {
    local config_file="$1"
    local mode="$2"

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
health_port = ${TUNNEL_PORT}
mtu = ${MTU}

[ipx]
mode = "${mode}"
profile = "udp"
listen_ip = "${LISTEN_IP}"
dst_ip = "${DST_IP}"
spoof_src_ip = "${SPOOF_SRC_IP}"
spoof_dst_ip = "${SPOOF_DST_IP}"
interface = "${INTERFACE}"

[security]
enable_encryption = false

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = ${WORKERS}
channel_size = ${CHANNEL_SIZE}
so_sndbuf = 0
batch_size = 2048
packet_multiply = 1  # 1=normal, 2=duplicate packets (anti packet-loss)

[logging]
log_level = "info"
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
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} --config ${config_file}
Restart=always
RestartSec=3
LimitNOFILE=65535
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN
NoNewPrivileges=yes
PrivateTmp=yes

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
    echo -e " ${GREEN}${BOLD}>>> Setup Iran Server (Peer — Server Mode)${NC}"
    echo ""
    print_line

    INTERFACE=$(detect_interface)
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    # ── Step 1: Tunnel Identity ──
    echo -e "\n ${MAGENTA}${BOLD}[1/4] Tunnel Identity${NC}"
    read_input "Tunnel ID (e.g. 10, 12, 50)" "" TUNNEL_ID
    if [ -z "$TUNNEL_ID" ]; then
        msg_err "Tunnel ID is required!"
        return
    fi
    read_input "Tunnel name" "spoof${TUNNEL_ID}" TUN_NAME
    read_input "Tunnel port" "2222" TUNNEL_PORT
    read_input "MTU" "1320" MTU

    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"

    # ── Step 2: IPX Network ──
    echo -e "\n ${MAGENTA}${BOLD}[2/4] IPX Spoof Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${INTERFACE}${NC}"
    read_input "Change interface? (Enter to keep)" "${INTERFACE}" INTERFACE
    if [ -n "$AUTO_IP" ]; then
        msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"
    fi
    read_input "Listen IP (this server's public IP)" "${AUTO_IP}" LISTEN_IP
    if [ -z "$LISTEN_IP" ]; then
        msg_err "Listen IP is required!"
        return
    fi
    read_input "Destination IP (Kharej public IP)" "" DST_IP
    if [ -z "$DST_IP" ]; then
        msg_err "Destination IP is required!"
        return
    fi
    read_input "Spoof Source IP" "" SPOOF_SRC_IP
    if [ -z "$SPOOF_SRC_IP" ]; then
        msg_err "Spoof Source IP is required!"
        return
    fi
    read_input "Spoof Destination IP" "" SPOOF_DST_IP
    if [ -z "$SPOOF_DST_IP" ]; then
        msg_err "Spoof Destination IP is required!"
        return
    fi

    # ── Step 3: Transport ──
    echo -e "\n ${MAGENTA}${BOLD}[3/4] Transport & Tuning${NC}"
    read_input "Heartbeat interval (sec)" "10" HEARTBEAT_INTERVAL
    read_input "Heartbeat timeout (sec)" "25" HEARTBEAT_TIMEOUT
    read_input "Workers (0=auto)" "0" WORKERS
    read_input "Channel size" "10000" CHANNEL_SIZE

    # ── Step 4: Review ──
    show_review_box "iran"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # ── Generate ──
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/iran${TUNNEL_PORT}.toml"
    local service_name="spoof-iran${TUNNEL_PORT}"

    generate_config "${config_file}" "server"
    msg_ok "Config saved: ${config_file}"

    if ! check_binary; then
        msg_warn "Binary not found. Download it first (option 12)."
        msg_ok "Config saved but service NOT started."
        return
    fi

    create_systemd_service "${service_name}" "${config_file}" "Spoof Tunnel Iran - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Iran Server Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  Config:    ${BLUE}${config_file}${NC}"
    echo -e "  Service:   ${BLUE}${service_name}.service${NC}"
    echo ""
    echo -e " ${YELLOW}${BOLD}  For Kharej setup, use:${NC}"
    echo -e "    Tunnel ID:     ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "    Dest IP:       ${CYAN}${BOLD}${LISTEN_IP}${NC}"
    echo -e "    Spoof Src IP:  ${CYAN}${BOLD}${SPOOF_DST_IP}${NC}  ${DIM}(swap src<->dst on Kharej)${NC}"
    echo -e "    Spoof Dst IP:  ${CYAN}${BOLD}${SPOOF_SRC_IP}${NC}  ${DIM}(swap src<->dst on Kharej)${NC}"
    echo ""

    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

setup_kharej() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup Kharej Client (Peer — Client Mode)${NC}"
    echo ""
    print_line

    INTERFACE=$(detect_interface)
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    # ── Step 1: Tunnel Identity ──
    echo -e "\n ${MAGENTA}${BOLD}[1/4] Tunnel Identity${NC}"
    read_input "Tunnel ID (must match Iran, e.g. 10, 12, 50)" "" TUNNEL_ID
    if [ -z "$TUNNEL_ID" ]; then
        msg_err "Tunnel ID is required!"
        return
    fi
    read_input "Tunnel name" "spoof${TUNNEL_ID}" TUN_NAME
    read_input "Tunnel port" "2222" TUNNEL_PORT
    read_input "MTU" "1320" MTU

    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"

    # ── Step 2: IPX Network ──
    echo -e "\n ${MAGENTA}${BOLD}[2/4] IPX Spoof Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${INTERFACE}${NC}"
    read_input "Change interface? (Enter to keep)" "${INTERFACE}" INTERFACE
    if [ -n "$AUTO_IP" ]; then
        msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"
    fi
    read_input "Listen IP (this server's public IP)" "${AUTO_IP}" LISTEN_IP
    if [ -z "$LISTEN_IP" ]; then
        msg_err "Listen IP is required!"
        return
    fi
    read_input "Destination IP (Iran public IP)" "" DST_IP
    if [ -z "$DST_IP" ]; then
        msg_err "Destination IP is required!"
        return
    fi
    msg_info "Note: In Kharej, spoof src/dst are SWAPPED vs Iran side."
    read_input "Spoof Source IP (= Iran's spoof_dst_ip)" "" SPOOF_SRC_IP
    if [ -z "$SPOOF_SRC_IP" ]; then
        msg_err "Spoof Source IP is required!"
        return
    fi
    read_input "Spoof Destination IP (= Iran's spoof_src_ip)" "" SPOOF_DST_IP
    if [ -z "$SPOOF_DST_IP" ]; then
        msg_err "Spoof Destination IP is required!"
        return
    fi

    # ── Step 3: Transport ──
    echo -e "\n ${MAGENTA}${BOLD}[3/4] Transport & Tuning${NC}"
    read_input "Heartbeat interval (sec)" "10" HEARTBEAT_INTERVAL
    read_input "Heartbeat timeout (sec)" "25" HEARTBEAT_TIMEOUT
    read_input "Workers (0=auto)" "0" WORKERS
    read_input "Channel size" "10000" CHANNEL_SIZE

    # ── Step 4: Review ──
    show_review_box "kharej"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # ── Generate ──
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/kharej${TUNNEL_PORT}.toml"
    local service_name="spoof-kharej${TUNNEL_PORT}"

    generate_config "${config_file}" "client"
    msg_ok "Config saved: ${config_file}"

    if ! check_binary; then
        msg_warn "Binary not found. Download it first (option 12)."
        msg_ok "Config saved but service NOT started."
        return
    fi

    create_systemd_service "${service_name}" "${config_file}" "Spoof Tunnel Kharej - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

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

# ─── Management ───────────────────────────────────────────────────

list_tunnels() {
    echo ""
    echo -e " ${CYAN}${BOLD}Active Spoof Tunnels:${NC}"
    print_line

    local found=0
    local i=1
    TUNNEL_LIST=()

    for svc in $(systemctl list-units --type=service --all --no-legend | grep "spoof-" | awk '{print $1}'); do
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
        msg_warn "No spoof tunnels found."
        return 1
    fi
    echo ""
    return 0
}

pick_tunnel() {
    list_tunnels || return 1

    read -p "  Enter number or service name: " pick

    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#TUNNEL_LIST[@]}" ]; then
        SELECTED_TUNNEL="${TUNNEL_LIST[$((pick-1))]}"
    else
        SELECTED_TUNNEL="$pick"
    fi

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
    systemctl status "${SELECTED_TUNNEL}" --no-pager -l 2>/dev/null | head -5
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
    systemctl status "${SELECTED_TUNNEL}" --no-pager -l 2>/dev/null | head -5
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

    local cfg="${CORE_DIR}/${SELECTED_TUNNEL#spoof-}.toml"

    if [ -f "$cfg" ]; then
        echo ""
        print_line
        cat "$cfg"
        print_line
    else
        msg_err "Config file not found at ${cfg}."
    fi
}

do_edit_config() {
    pick_tunnel || return

    local cfg="${CORE_DIR}/${SELECTED_TUNNEL#spoof-}.toml"

    if [ -f "$cfg" ]; then
        ${EDITOR:-nano} "$cfg"
        echo ""
        msg_warn "Restart the tunnel to apply changes."
        read -p "  Restart now? (Y/n): " restart_confirm
        if [[ ! "$restart_confirm" =~ ^[Nn]$ ]]; then
            systemctl restart "${SELECTED_TUNNEL}"
            msg_ok "${SELECTED_TUNNEL} restarted."
        fi
    else
        msg_err "Config file not found at ${cfg}."
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

        local cfg="${CORE_DIR}/${SELECTED_TUNNEL#spoof-}.toml"

        rm -f "${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service"
        if [ -f "$cfg" ]; then
            rm -f "$cfg"
            msg_ok "${SELECTED_TUNNEL} and config (${cfg}) deleted."
        else
            msg_ok "${SELECTED_TUNNEL} deleted. (Config already removed)"
        fi

        systemctl daemon-reload
    else
        msg_warn "Cancelled."
    fi
}

# ─── Switch Engine ────────────────────────────────────────────────

detect_current_engine() {
    local svc_name="$1"
    local svc_file="${SYSTEMD_DIR}/${svc_name}.service"
    if [ ! -f "$svc_file" ]; then
        echo "unknown"
        return
    fi
    local exec_line
    exec_line=$(grep '^ExecStart=' "$svc_file" 2>/dev/null)
    if echo "$exec_line" | grep -q 'backhaul_premium'; then
        echo "backhaul"
    elif echo "$exec_line" | grep -q 'spoof-tunnel-core'; then
        echo "spoof"
    else
        echo "unknown"
    fi
}

switch_engine() {
    echo ""
    echo -e " ${GREEN}${BOLD}>>> Switch Tunnel Engine${NC}"
    print_line
    echo ""

    pick_tunnel || return

    local current_engine
    current_engine=$(detect_current_engine "${SELECTED_TUNNEL}")

    echo ""
    echo -e "  Current engine: ${BOLD}${WHITE}${current_engine}${NC}"
    echo ""
    echo -e "  ${WHITE}1)${NC} ${CYAN}spoof-tunnel-core${NC}  ${DIM}(custom zero-alloc engine)${NC}"
    echo -e "  ${WHITE}2)${NC} ${BLUE}backhaul_premium${NC}   ${DIM}(backhaul official binary)${NC}"
    echo -e "  ${DIM}0)${NC} Cancel"
    echo ""
    read -p "  Select engine: " engine_choice

    local new_binary=""
    local engine_name=""
    case $engine_choice in
        1)
            new_binary="${BINARY_SPOOF}"
            engine_name="spoof-tunnel-core"
            ;;
        2)
            new_binary="${BINARY_BACKHAUL}"
            engine_name="backhaul_premium"
            ;;
        0) return ;;
        *) msg_err "Invalid option."; return ;;
    esac

    # Check binary exists
    if [ ! -f "${new_binary}" ]; then
        msg_warn "Binary ${new_binary} not found!"
        if [ "$engine_choice" = "2" ]; then
            echo ""
            read -p "  Download backhaul_premium now? (Y/n): " dl_confirm
            if [[ ! "$dl_confirm" =~ ^[Nn]$ ]]; then
                msg_info "Downloading backhaul_premium..."
                if curl -L --max-time 120 --progress-bar -o "${BINARY_BACKHAUL}" "${BACKHAUL_DOWNLOAD_URL}"; then
                    chmod +x "${BINARY_BACKHAUL}"
                    msg_ok "Downloaded: ${BINARY_BACKHAUL}"
                else
                    msg_err "Download failed."
                    return
                fi
            else
                return
            fi
        else
            msg_info "Use menu option 12 to download spoof-tunnel-core first."
            return
        fi
    fi

    # Update systemd service ExecStart
    local svc_file="${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service"
    local config_file
    config_file=$(grep '^ExecStart=' "$svc_file" | sed 's/.*--config //')

    # Stop, update, restart
    systemctl stop "${SELECTED_TUNNEL}" 2>/dev/null

    sed -i "s|^ExecStart=.*|ExecStart=${new_binary} --config ${config_file}|" "$svc_file"

    systemctl daemon-reload
    systemctl start "${SELECTED_TUNNEL}"

    echo ""
    msg_ok "Engine switched to ${BOLD}${engine_name}${NC} for ${SELECTED_TUNNEL}"
    systemctl status "${SELECTED_TUNNEL}" --no-pager -l 2>/dev/null | head -5
}

# ─── Main Menu ────────────────────────────────────────────────────

main_menu() {
    while true; do
        print_header
        echo -e " ${BOLD}${WHITE}Setup${NC}"
        echo -e "  ${GREEN}1)${NC} Setup Iran Server"
        echo -e "  ${BLUE}2)${NC} Setup Kharej Client"
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
        echo -e "  ${BLUE}11)${NC} Edit Config"
        echo ""
        echo -e " ${BOLD}${WHITE}Install & Tools${NC}"
        echo -e "  ${MAGENTA}12)${NC} Download Binary"
        echo -e "  ${YELLOW}14)${NC} Switch Engine (Spoof/Backhaul)"
        echo ""
        echo -e " ${BOLD}${WHITE}Danger${NC}"
        echo -e "  ${RED}13)${NC} Delete a Tunnel"
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
            11) do_edit_config ;;
            12) download_binary ;;
            13) do_delete ;;
            14) switch_engine ;;
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
main_menu

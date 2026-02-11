#!/bin/bash
# ═══════════════════════════════════════════════════
#  MOH-Tunel (wg-obfuscator) Multi-Tunnel Manager
#  WireGuard obfuscation layer for bypassing DPI
# ═══════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/moh-tunnel"
SYSTEMD_DIR="/etc/systemd/system"
BINARY_NAME="wg"
BINARY_URL="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/MOH-Tunel/wg"

# ═══════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════

show_banner() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}       MOH-Tunel (wg-obfuscator)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""
}

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}This script must be run as root${NC}"; exit 1; }
}

download_binary() {
    echo -e "${YELLOW}Downloading wg binary...${NC}"
    mkdir -p "$INSTALL_DIR"

    if [[ -f "$INSTALL_DIR/$BINARY_NAME" ]]; then
        cp "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/${BINARY_NAME}.backup"
    fi

    if wget -q --show-progress "$BINARY_URL" -O "$INSTALL_DIR/$BINARY_NAME"; then
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        echo -e "${GREEN}Binary downloaded successfully${NC}"
        rm -f "$INSTALL_DIR/${BINARY_NAME}.backup"
    else
        echo -e "${RED}Download failed${NC}"
        [[ -f "$INSTALL_DIR/${BINARY_NAME}.backup" ]] && mv "$INSTALL_DIR/${BINARY_NAME}.backup" "$INSTALL_DIR/$BINARY_NAME"
        return 1
    fi
}

# ═══════════════════════════════════════════════════
#  SYSTEMD SERVICE
# ═══════════════════════════════════════════════════

create_service() {
    local SERVICE_NAME=$1
    local CONFIG_FILE=$2

    cat > "$SYSTEMD_DIR/${SERVICE_NAME}.service" << EOF
[Unit]
Description=MOH-Tunel wg-obfuscator - ${SERVICE_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=$INSTALL_DIR/$BINARY_NAME --config ${CONFIG_FILE}
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
#  ADD SERVER (Foreign/Kharej)
# ═══════════════════════════════════════════════════

add_server() {
    show_banner
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ADD SERVER (Run on FOREIGN/Kharej)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""

    read -p "Tunnel ID [1]: " ID
    ID=${ID:-1}

    local SERVICE_NAME="moh-server-${ID}"
    local CONFIG_FILE="$CONFIG_DIR/server-${ID}.conf"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}server-${ID}.conf already exists!${NC}"
        read -p "Overwrite? [y/N]: " ow
        [[ ! $ow =~ ^[Yy]$ ]] && return
        systemctl stop "$SERVICE_NAME" 2>/dev/null
    fi

    mkdir -p "$CONFIG_DIR"

    # Listen port
    local DEFAULT_PORT=$((8080 + ID - 1))
    read -p "Listen port (obfuscated port, clients connect here) [${DEFAULT_PORT}]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-$DEFAULT_PORT}

    # Target (local WireGuard)
    read -p "WireGuard target (local WG listen) [127.0.0.1:3031]: " TARGET
    TARGET=${TARGET:-127.0.0.1:3031}

    # Key
    while true; do
        read -sp "Obfuscation key (must match client): " KEY
        echo ""
        [[ -n "$KEY" ]] && break
        echo -e "${RED}Key cannot be empty${NC}"
    done

    # Masking
    echo ""
    echo -e "${YELLOW}Masking mode:${NC}"
    echo "  1) raw   - Raw obfuscation"
    echo "  2) quic  - QUIC masking"
    read -p "Choice [1]: " mask_choice
    case $mask_choice in
        2) MASKING="quic" ;;
        *) MASKING="raw" ;;
    esac

    # Workers
    read -p "Workers (CPU cores) [4]: " WORKERS
    WORKERS=${WORKERS:-4}

    # Redundancy
    read -p "Redundancy (1-3) [1]: " REDUNDANCY
    REDUNDANCY=${REDUNDANCY:-1}

    # Max clients
    read -p "Max clients [50]: " MAX_CLIENTS
    MAX_CLIENTS=${MAX_CLIENTS:-50}

    # Verbose
    read -p "Verbose level (1=ERROR 2=INFO 3=DEBUG) [2]: " VERBOSE
    VERBOSE=${VERBOSE:-2}

    # Write config
    cat > "$CONFIG_FILE" << EOF
[main]
source-if    = 0.0.0.0
source-lport = ${LISTEN_PORT}
target       = ${TARGET}
key          = ${KEY}
masking      = ${MASKING}
workers      = ${WORKERS}
redundancy   = ${REDUNDANCY}
max-clients  = ${MAX_CLIENTS}
max-dummy    = 2
idle-timeout = 300
verbose      = ${VERBOSE}
EOF

    create_service "$SERVICE_NAME" "$CONFIG_FILE"

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Server #${ID} is ready!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "  Listen     : ${GREEN}0.0.0.0:${LISTEN_PORT}${NC}"
    echo -e "  Target     : ${GREEN}${TARGET}${NC}"
    echo -e "  Masking    : ${GREEN}${MASKING}${NC}"
    echo -e "  Workers    : ${GREEN}${WORKERS}${NC}"
    echo -e "  Config     : ${CONFIG_FILE}"
    echo -e "  Logs       : journalctl -u ${SERVICE_NAME} -f"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  ADD CLIENT (Iran)
# ═══════════════════════════════════════════════════

add_client() {
    show_banner
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ADD CLIENT (Run on IRAN)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""

    read -p "Tunnel ID [1]: " ID
    ID=${ID:-1}

    local SERVICE_NAME="moh-client-${ID}"
    local CONFIG_FILE="$CONFIG_DIR/client-${ID}.conf"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}client-${ID}.conf already exists!${NC}"
        read -p "Overwrite? [y/N]: " ow
        [[ ! $ow =~ ^[Yy]$ ]] && return
        systemctl stop "$SERVICE_NAME" 2>/dev/null
    fi

    mkdir -p "$CONFIG_DIR"

    # Local listen port (WireGuard connects here)
    read -p "Local listen port (WireGuard Endpoint = 127.0.0.1:THIS) [3031]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-3031}

    # Remote server
    read -p "Foreign server IP:PORT (e.g., 8.208.9.104:8080): " TARGET
    if [[ -z "$TARGET" ]]; then
        echo -e "${RED}Cannot be empty${NC}"
        read -p "Press Enter..."
        return
    fi

    # Key
    while true; do
        read -sp "Obfuscation key (must match server): " KEY
        echo ""
        [[ -n "$KEY" ]] && break
        echo -e "${RED}Key cannot be empty${NC}"
    done

    # Masking
    echo ""
    echo -e "${YELLOW}Masking mode:${NC}"
    echo "  1) raw   - Raw obfuscation"
    echo "  2) quic  - QUIC masking"
    read -p "Choice [1]: " mask_choice
    case $mask_choice in
        2) MASKING="quic" ;;
        *) MASKING="raw" ;;
    esac

    # Redundancy
    read -p "Redundancy (1=normal, 2=packet loss, 3=heavy loss) [2]: " REDUNDANCY
    REDUNDANCY=${REDUNDANCY:-2}

    # Verbose
    read -p "Verbose level (1=ERROR 2=INFO 3=DEBUG) [2]: " VERBOSE
    VERBOSE=${VERBOSE:-2}

    # Write config
    cat > "$CONFIG_FILE" << EOF
[main]
source-if    = 0.0.0.0
source-lport = ${LOCAL_PORT}
target       = ${TARGET}
key          = ${KEY}
masking      = ${MASKING}
workers      = 1
redundancy   = ${REDUNDANCY}
max-dummy    = 2
idle-timeout = 300
verbose      = ${VERBOSE}
EOF

    create_service "$SERVICE_NAME" "$CONFIG_FILE"

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Client #${ID} is ready!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "  Local port : ${GREEN}127.0.0.1:${LOCAL_PORT}${NC}"
    echo -e "  Server     : ${GREEN}${TARGET}${NC}"
    echo -e "  Masking    : ${GREEN}${MASKING}${NC}"
    echo -e "  Redundancy : ${GREEN}${REDUNDANCY}${NC}"
    echo -e "  Config     : ${CONFIG_FILE}"
    echo -e "  Logs       : journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo -e "${YELLOW}Set WireGuard Endpoint to: 127.0.0.1:${LOCAL_PORT}${NC}"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  LIST TUNNELS
# ═══════════════════════════════════════════════════

list_tunnels() {
    show_banner
    echo -e "${CYAN}CONFIGURED TUNNELS${NC}"
    echo ""

    local found=false

    for f in "$CONFIG_DIR"/server-*.conf "$CONFIG_DIR"/client-*.conf; do
        [[ ! -f "$f" ]] && continue
        found=true

        local base=$(basename "$f" .conf)
        local mode=$(echo "$base" | cut -d- -f1)
        local id=$(echo "$base" | sed "s/${mode}-//")
        local service="moh-${mode}-${id}"
        local status=$(systemctl is-active "$service" 2>/dev/null)
        local port=$(grep "source-lport" "$f" | awk -F= '{print $2}' | tr -d ' ')
        local target=$(grep "target" "$f" | awk -F= '{print $2}' | tr -d ' ')

        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[ACTIVE]${NC}  ${mode^} #${id}  |  Port: ${port}  |  Target: ${target}  |  ${service}"
        else
            echo -e "  ${RED}[STOP]${NC}   ${mode^} #${id}  |  Port: ${port}  |  Target: ${target}  |  ${service}"
        fi
    done

    $found || echo -e "  ${YELLOW}No tunnels configured${NC}"
    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  MANAGE TUNNEL
# ═══════════════════════════════════════════════════

collect_tunnels() {
    TUNNEL_LIST=()
    for f in "$CONFIG_DIR"/server-*.conf "$CONFIG_DIR"/client-*.conf; do
        [[ ! -f "$f" ]] && continue
        local base=$(basename "$f" .conf)
        local mode=$(echo "$base" | cut -d- -f1)
        local id=$(echo "$base" | sed "s/${mode}-//")
        local service="moh-${mode}-${id}"
        TUNNEL_LIST+=("${service}|${f}|${mode^} #${id}")
    done
}

manage_tunnel() {
    show_banner
    echo -e "${CYAN}MANAGE TUNNEL${NC}"
    echo ""

    collect_tunnels

    if [[ ${#TUNNEL_LIST[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}No tunnels found${NC}"
        read -p "Press Enter..."
        return
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
    [[ -z "$num" || $num -lt 1 || $num -gt ${#TUNNEL_LIST[@]} ]] && return

    IFS='|' read -r SEL_SVC SEL_CFG SEL_LABEL <<< "${TUNNEL_LIST[$((num-1))]}"

    echo ""
    echo -e "${CYAN}Selected: ${GREEN}${SEL_LABEL}${NC}"
    echo ""
    echo "  1) Start       5) View Logs"
    echo "  2) Stop        6) Follow Logs (live)"
    echo "  3) Restart     7) View Config"
    echo "  4) Status      8) Edit Config"
    echo "                 9) Delete"
    echo ""
    echo "  0) Cancel"
    echo ""
    read -p "Action: " action

    case $action in
        1) systemctl start "$SEL_SVC"; echo -e "${GREEN}Started${NC}"; sleep 1 ;;
        2) systemctl stop "$SEL_SVC"; echo -e "${GREEN}Stopped${NC}"; sleep 1 ;;
        3) systemctl restart "$SEL_SVC"; echo -e "${GREEN}Restarted${NC}"; sleep 1 ;;
        4) echo ""; systemctl status "$SEL_SVC" --no-pager; echo ""; read -p "Press Enter..." ;;
        5) echo ""; journalctl -u "$SEL_SVC" -n 50 --no-pager; echo ""; read -p "Press Enter..." ;;
        6) echo -e "${YELLOW}Ctrl+C to stop${NC}"; journalctl -u "$SEL_SVC" -f ;;
        7) echo ""; cat "$SEL_CFG"; echo ""; read -p "Press Enter..." ;;
        8)
            ${EDITOR:-nano} "$SEL_CFG"
            read -p "Restart service? [y/N]: " r
            [[ $r =~ ^[Yy]$ ]] && systemctl restart "$SEL_SVC" && echo -e "${GREEN}Restarted${NC}" && sleep 1
            ;;
        9)
            read -p "Delete ${SEL_LABEL}? [y/N]: " c
            if [[ $c =~ ^[Yy]$ ]]; then
                systemctl stop "$SEL_SVC" 2>/dev/null
                systemctl disable "$SEL_SVC" 2>/dev/null
                rm -f "$SEL_CFG" "$SYSTEMD_DIR/${SEL_SVC}.service"
                systemctl daemon-reload
                echo -e "${GREEN}Deleted${NC}"; sleep 1
            fi
            ;;
        0|*) ;;
    esac
}

# ═══════════════════════════════════════════════════
#  RESTART ALL
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
        echo -e "  ${GREEN}Restarted:${NC} ${label}"
    done

    echo ""
    read -p "Press Enter to return..."
}

# ═══════════════════════════════════════════════════
#  UNINSTALL
# ═══════════════════════════════════════════════════

uninstall_all() {
    show_banner
    echo -e "${RED}UNINSTALL MOH-Tunel${NC}"
    echo ""
    echo "  This will remove:"
    echo "    - wg binary"
    echo "    - All tunnel configs"
    echo "    - All systemd services"
    echo ""
    read -p "Are you sure? [y/N]: " c
    [[ ! $c =~ ^[Yy]$ ]] && return

    collect_tunnels
    for entry in "${TUNNEL_LIST[@]}"; do
        IFS='|' read -r svc cfg label <<< "$entry"
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$SYSTEMD_DIR/${svc}.service"
    done

    rm -f "$INSTALL_DIR/$BINARY_NAME"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload

    echo ""
    echo -e "${GREEN}MOH-Tunel uninstalled${NC}"
    exit 0
}

# ═══════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════

main_menu() {
    while true; do
        show_banner
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo -e "${CYAN}              MAIN MENU${NC}"
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Add Server    (Foreign/Kharej)"
        echo "  2) Add Client    (Iran)"
        echo ""
        echo "  3) List Tunnels"
        echo "  4) Manage Tunnel  (start/stop/logs/edit/delete)"
        echo "  5) Restart All"
        echo ""
        echo "  6) Update Binary"
        echo "  7) Uninstall"
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
            6) download_binary; read -p "Press Enter..." ;;
            7) uninstall_all ;;
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

if [[ ! -f "$INSTALL_DIR/$BINARY_NAME" ]]; then
    echo -e "${YELLOW}wg binary not found. Downloading...${NC}"
    download_binary
    echo ""
fi

main_menu

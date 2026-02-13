#!/bin/bash

# ==========================================
#  Gost SSH Tunnel Manager v4.0
#  Protocol: relay+ssh (fixed)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

GOST_BIN="/usr/local/bin/gost"
PROTOCOL="relay+ssh"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# ==========================================
# Install Gost (from GitHub binary)
# ==========================================
install_gost() {
    if [[ -f "$GOST_BIN" ]]; then
        local ver=$($GOST_BIN -V 2>&1 | head -1)
        echo -e "${GREEN}Gost already installed: ${ver}${NC}"
        read -p "Reinstall? (y/N): " r
        [[ ! $r =~ ^[Yy]$ ]] && return
    fi
    
    echo -e "${YELLOW}Installing Gost from GitHub...${NC}"
    apt remove -y gost 2>/dev/null
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            DL_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
            ;;
        aarch64)
            DL_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-arm64-2.11.5.gz"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            return 1
            ;;
    esac

    mkdir -p /usr/local/bin
    wget -O /tmp/gost.gz "$DL_URL"
    gunzip -f /tmp/gost.gz
    chmod +x /tmp/gost
    mv /tmp/gost "$GOST_BIN"
    echo -e "${GREEN}Gost installed: $($GOST_BIN -V 2>&1 | head -1)${NC}"
}

# ==========================================
# Generate random password
# ==========================================
generate_password() {
    < /dev/urandom tr -dc A-Za-z0-9 | head -c 16
}

# ==========================================
# Check Connection (FIXED: searches correct service names)
# ==========================================
check_connection() {
    echo -e "${BLUE}--- Check Tunnel Connection ---${NC}"
    
    echo -e "${YELLOW}Checking Systemd Services...${NC}"
    SERVICES=$(systemctl list-units --type=service --state=running | grep -E "gost-(server|client)-")
    
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No running Gost services found!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${GREEN}Running Services:${NC}"
    echo "$SERVICES"
    
    # Check listening ports
    echo -e "\n${YELLOW}Checking Listening Ports...${NC}"
    if command -v ss &> /dev/null; then
        ss -tunlp | grep gost
    elif command -v netstat &> /dev/null; then
        netstat -tunlp | grep gost
    fi
    
    # Connectivity test via curl
    echo -e "\n${YELLOW}Testing Connectivity...${NC}"
    read -p "Enter local port to test (or Enter to skip): " TEST_PORT
    if [[ ! -z "$TEST_PORT" ]]; then
        echo -e "Testing TCP connection to port ${TEST_PORT}..."
        
        # Method 1: Direct TCP check
        if nc -z -w 5 127.0.0.1 $TEST_PORT 2>/dev/null; then
            echo -e "${GREEN}TCP port $TEST_PORT is OPEN${NC}"
        else
            echo -e "${RED}TCP port $TEST_PORT is CLOSED${NC}"
        fi

        # Method 2: curl through tunnel (if it acts as proxy)
        echo -e "Testing data transfer via curl..."
        RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -x socks5h://127.0.0.1:$TEST_PORT https://api.ipify.org 2>/dev/null)
        if [[ ! -z "$RESPONSE" ]]; then
             echo -e "${GREEN}SOCKS5 Proxy Test OK! Remote IP: $RESPONSE${NC}"
        else
             RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -x http://127.0.0.1:$TEST_PORT https://api.ipify.org 2>/dev/null)
             if [[ ! -z "$RESPONSE" ]]; then
                 echo -e "${GREEN}HTTP Proxy Test OK! Remote IP: $RESPONSE${NC}"
             else
                 echo -e "${YELLOW}Proxy test skipped (port is likely a raw forward, not a proxy)${NC}"
             fi
        fi
    fi
    
    read -p "Press Enter to continue..."
}

# ==========================================
# Setup Watchdog (FIXED: searches correct service names)
# ==========================================
setup_watchdog() {
    echo -e "${BLUE}--- Setup Auto-Reconnect Watchdog ---${NC}"
    
    SERVICES=$(ls /etc/systemd/system/gost-client-*.service 2>/dev/null)
    if [ -z "$SERVICES" ]; then
         echo -e "${RED}No Gost Client services found to monitor.${NC}"
         read -p "Press Enter to continue..."
         return
    fi
    
    echo "Select service to monitor:"
    i=1
    declare -A SERVICE_MAP
    declare -A PORT_MAP
    for svc_path in $SERVICES; do
        svc_name=$(basename "$svc_path" .service)
        PORT=$(echo "$svc_name" | sed 's/gost-client-//')
        echo "$i) $svc_name (Port: $PORT)"
        SERVICE_MAP[$i]=$svc_name
        PORT_MAP[$i]=$PORT
        i=$((i+1))
    done
    echo "0) Cancel"
    
    read -p "Select: " OPTION
    if [ "$OPTION" == "0" ]; then return; fi
    
    SVC=${SERVICE_MAP[$OPTION]}
    PORT=${PORT_MAP[$OPTION]}
    
    if [ -z "$SVC" ]; then echo "Invalid option"; return; fi
    
    WATCHDOG_SCRIPT="/usr/local/bin/watchdog-$SVC.sh"
    
    cat <<EOF > $WATCHDOG_SCRIPT
#!/bin/bash
# Watchdog for $SVC (port $PORT)
# Checks: systemd status -> curl SOCKS5 -> curl HTTP -> nc TCP

LOG_PREFIX="[\$(date '+%Y-%m-%d %H:%M:%S')] [$SVC]"
TARGET="https://www.google.com"

# 1. Check systemd service status
IS_ACTIVE=\$(systemctl is-active $SVC)
if [ "\$IS_ACTIVE" != "active" ]; then
    echo "\$LOG_PREFIX Service is not active. Restarting..."
    systemctl restart $SVC
    exit 0
fi

# 2. SOCKS5 Proxy Check
curl -s --connect-timeout 5 --max-time 10 -x socks5h://127.0.0.1:$PORT \$TARGET > /dev/null 2>&1
if [ \$? -eq 0 ]; then
    echo "\$LOG_PREFIX SOCKS5 check passed."
    exit 0
fi

# 3. HTTP Proxy Check
curl -s --connect-timeout 5 --max-time 10 -x http://127.0.0.1:$PORT \$TARGET > /dev/null 2>&1
if [ \$? -eq 0 ]; then
    echo "\$LOG_PREFIX HTTP check passed."
    exit 0
fi

# 4. TCP Port Check (raw forward)
nc -z -w 5 127.0.0.1 $PORT 2>/dev/null
if [ \$? -eq 0 ]; then
    echo "\$LOG_PREFIX TCP port open. Assuming healthy."
    exit 0
fi

echo "\$LOG_PREFIX All checks FAILED. Restarting service..."
systemctl restart $SVC
EOF
    
    chmod +x $WATCHDOG_SCRIPT
    
    # Add to crontab (replace if exists)
    CRON_CMD="* * * * * $WATCHDOG_SCRIPT >> /var/log/gost-watchdog.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_CMD") | crontab -
    
    echo -e "${GREEN}Watchdog installed for $SVC!${NC}"
    echo -e "Checks every minute. Logs: /var/log/gost-watchdog.log"
    read -p "Press Enter to continue..."
}

# ==========================================
# Server Setup (Kharej)
# ==========================================
setup_server() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Server (KHAREJ) - relay+ssh${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    read -p "Enter Port for Tunnel [8443]: " PORT
    PORT=${PORT:-8443}
    
    read -p "Enter Username [admin]: " USERNAME
    USERNAME=${USERNAME:-admin}
    
    PASSWORD=$(generate_password)
    echo -e "${YELLOW}Generated Password: ${GREEN}$PASSWORD${NC}"
    read -p "Use this password or enter your own (Press Enter to keep): " INPUT_PASS
    [[ ! -z "$INPUT_PASS" ]] && PASSWORD=$INPUT_PASS
    
    SERVICE_NAME="gost-server-${PORT}"
    
    cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Gost relay+ssh Server (port ${PORT})
After=network.target

[Service]
Type=simple
ExecStart=$GOST_BIN -L "${PROTOCOL}://${USERNAME}:${PASSWORD}@:${PORT}"
Restart=always
RestartSec=3
StartLimitInterval=0
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    
    sleep 2
    IP=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Server Ready!${NC}"
    echo -e "${GREEN}  IP       : ${IP}${NC}"
    echo -e "${GREEN}  Port     : ${PORT}${NC}"
    echo -e "${GREEN}  User     : ${USERNAME}${NC}"
    echo -e "${GREEN}  Pass     : ${PASSWORD}${NC}"
    echo -e "${GREEN}  Protocol : ${PROTOCOL}${NC}"
    echo -e "${GREEN}  Service  : ${SERVICE_NAME}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Copy these for client setup!${NC}"
    read -p "Press Enter to continue..."
}

# ==========================================
# Client Setup (Iran)
# ==========================================
setup_client() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Client (IRAN) - relay+ssh${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    read -p "Server IP: " SERVER_IP
    [[ -z "$SERVER_IP" ]] && { echo -e "${RED}IP required${NC}"; return; }

    read -p "Server Port [8443]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-8443}

    read -p "Username [admin]: " USERNAME
    USERNAME=${USERNAME:-admin}

    read -p "Password: " PASSWORD
    [[ -z "$PASSWORD" ]] && { echo -e "${RED}Password required${NC}"; return; }
    
    echo ""
    echo -e "${CYAN}PORT FORWARDING${NC}"
    echo -e "  ${YELLOW}Local${NC}  = Port on this Iran server"
    echo -e "  ${YELLOW}Remote${NC} = Port on Kharej server"
    echo ""

    local MAP_COUNT=0
    local SERVICES_LIST=""

    while true; do
        read -p "Local port (or Enter to finish): " LOCAL_PORT
        [[ -z "$LOCAL_PORT" ]] && break

        read -p "Remote destination [127.0.0.1:${LOCAL_PORT}]: " DEST_ADDR
        DEST_ADDR=${DEST_ADDR:-127.0.0.1:${LOCAL_PORT}}

        read -p "Protocol (tcp/udp/both) [both]: " FWD_PROTO
        FWD_PROTO=${FWD_PROTO:-both}

        SERVICE_NAME="gost-client-${LOCAL_PORT}"

        case $FWD_PROTO in
            tcp)
                EXEC_CMD="$GOST_BIN -L tcp://:${LOCAL_PORT}/${DEST_ADDR} -F \"${PROTOCOL}://${USERNAME}:${PASSWORD}@${SERVER_IP}:${SERVER_PORT}\""
                ;;
            udp)
                EXEC_CMD="$GOST_BIN -L udp://:${LOCAL_PORT}/${DEST_ADDR} -F \"${PROTOCOL}://${USERNAME}:${PASSWORD}@${SERVER_IP}:${SERVER_PORT}\""
                ;;
            *)
                EXEC_CMD="$GOST_BIN -L tcp://:${LOCAL_PORT}/${DEST_ADDR} -L udp://:${LOCAL_PORT}/${DEST_ADDR} -F \"${PROTOCOL}://${USERNAME}:${PASSWORD}@${SERVER_IP}:${SERVER_PORT}\""
                ;;
        esac

        cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Gost relay+ssh Client (${LOCAL_PORT} -> ${DEST_ADDR})
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_CMD
Restart=always
RestartSec=3
StartLimitInterval=0
User=root

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable $SERVICE_NAME > /dev/null 2>&1
        systemctl restart $SERVICE_NAME

        MAP_COUNT=$((MAP_COUNT + 1))
        SERVICES_LIST="${SERVICES_LIST}  ${LOCAL_PORT} -> ${DEST_ADDR} (${FWD_PROTO})\n"
        echo -e "  ${GREEN}Added: ${LOCAL_PORT} -> ${DEST_ADDR} (${FWD_PROTO})${NC}"
    done

    if [[ $MAP_COUNT -eq 0 ]]; then
        echo -e "${RED}No port mappings added${NC}"
        return
    fi

    # Watchdog
    read -p "Enable Auto-Reconnect Watchdog? (y/N): " WD
    if [[ "$WD" =~ ^[Yy]$ ]]; then
        for svc_file in /etc/systemd/system/gost-client-*.service; do
            [[ ! -f "$svc_file" ]] && continue
            local svc_name=$(basename "$svc_file" .service)
            local port=$(echo "$svc_name" | sed 's/gost-client-//')
            local wd_script="/usr/local/bin/watchdog-${svc_name}.sh"

            cat > "$wd_script" <<WDEOF
#!/bin/bash
LOG_PREFIX="[\$(date '+%Y-%m-%d %H:%M:%S')] [$svc_name]"
TARGET="https://www.google.com"

IS_ACTIVE=\$(systemctl is-active $svc_name)
if [ "\$IS_ACTIVE" != "active" ]; then
    echo "\$LOG_PREFIX Service down. Restarting..."
    systemctl restart $svc_name
    exit 0
fi

# SOCKS5 Check
curl -s --connect-timeout 5 --max-time 10 -x socks5h://127.0.0.1:$port \$TARGET > /dev/null 2>&1
if [ \$? -eq 0 ]; then exit 0; fi

# HTTP Check
curl -s --connect-timeout 5 --max-time 10 -x http://127.0.0.1:$port \$TARGET > /dev/null 2>&1
if [ \$? -eq 0 ]; then exit 0; fi

# TCP Fallback
nc -z -w 5 127.0.0.1 $port 2>/dev/null
if [ \$? -ne 0 ]; then
    echo "\$LOG_PREFIX All checks failed. Restarting..."
    systemctl restart $svc_name
fi
WDEOF
            chmod +x "$wd_script"
            CRON_CMD="* * * * * $wd_script >> /var/log/gost-watchdog.log 2>&1"
            (crontab -l 2>/dev/null | grep -v "$wd_script"; echo "$CRON_CMD") | crontab -
        done
        echo -e "${GREEN}Watchdog enabled for all client ports${NC}"
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Client Ready!${NC}"
    echo -e "${GREEN}  Server   : ${SERVER_IP}:${SERVER_PORT}${NC}"
    echo -e "${GREEN}  Protocol : ${PROTOCOL}${NC}"
    echo -e "${GREEN}  Mappings : ${MAP_COUNT}${NC}"
    printf "$SERVICES_LIST"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    read -p "Press Enter to continue..."
}

# ==========================================
# List / Status (FIXED: correct service patterns)
# ==========================================
list_tunnels() {
    echo ""
    echo -e "${CYAN}CONFIGURED TUNNELS${NC}"
    echo ""

    local found=false
    for f in /etc/systemd/system/gost-server-*.service /etc/systemd/system/gost-client-*.service; do
        [[ ! -f "$f" ]] && continue
        found=true
        local svc=$(basename "$f" .service)
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[ON]${NC}  $svc"
        else
            echo -e "  ${RED}[OFF]${NC} $svc"
        fi
    done

    $found || echo -e "  ${YELLOW}No tunnels configured${NC}"
    echo ""
    read -p "Press Enter to continue..."
}

# ==========================================
# Uninstall
# ==========================================
uninstall_menu() {
    echo -e "${BLUE}--- Uninstall Service ---${NC}"
    
    SERVICES=$(ls /etc/systemd/system/gost-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No Gost services found.${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo "Found services:"
    i=1
    declare -A SERVICE_MAP
    for svc_path in $SERVICES; do
        svc_name=$(basename "$svc_path" .service)
        local status=$(systemctl is-active "$svc_name" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $i) ${GREEN}[ON]${NC}  $svc_name"
        else
            echo -e "  $i) ${RED}[OFF]${NC} $svc_name"
        fi
        SERVICE_MAP[$i]=$svc_name
        i=$((i+1))
    done
    echo "  A) Uninstall ALL"
    echo "  0) Cancel"
    
    read -p "Select: " CHOICE
    
    [[ "$CHOICE" == "0" ]] && return

    if [[ "$CHOICE" =~ ^[Aa]$ ]]; then
        read -p "Remove ALL Gost services? (yes/NO): " c
        [[ "$c" != "yes" ]] && return
        for svc_path in $SERVICES; do
            local svc=$(basename "$svc_path" .service)
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            rm -f "$svc_path"
            rm -f "/usr/local/bin/watchdog-${svc}.sh"
            # Clean crontab entry
            crontab -l 2>/dev/null | grep -v "watchdog-${svc}" | crontab - 2>/dev/null
        done
        systemctl daemon-reload
        echo -e "${GREEN}All services removed${NC}"
    else
        SVC=${SERVICE_MAP[$CHOICE]}
        if [ ! -z "$SVC" ]; then
            systemctl stop $SVC
            systemctl disable $SVC
            rm -f "/etc/systemd/system/$SVC.service"
            rm -f "/usr/local/bin/watchdog-$SVC.sh"
            crontab -l 2>/dev/null | grep -v "watchdog-$SVC" | crontab - 2>/dev/null
            systemctl daemon-reload
            echo -e "${GREEN}Service '$SVC' removed${NC}"
        else
            echo "Invalid choice."
        fi
    fi
    read -p "Press Enter to continue..."
}

# ==========================================
# Full Uninstall
# ==========================================
full_uninstall() {
    echo -e "${RED}FULL UNINSTALL${NC}"
    echo "Removes: all services + gost binary + watchdogs + cron entries"
    read -p "Are you sure? (yes/NO): " c
    [[ "$c" != "yes" ]] && return

    for f in /etc/systemd/system/gost-*.service; do
        [[ ! -f "$f" ]] && continue
        local svc=$(basename "$f" .service)
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$f"
        rm -f "/usr/local/bin/watchdog-${svc}.sh"
    done

    rm -f "$GOST_BIN"
    crontab -l 2>/dev/null | grep -v "gost-watchdog\|watchdog-gost" | crontab - 2>/dev/null
    systemctl daemon-reload

    echo -e "${GREEN}Everything removed!${NC}"
    exit 0
}

# ==========================================
# Main Menu
# ==========================================
while true; do
    clear
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Gost SSH Tunnel Manager v4.0${NC}"
    echo -e "${GREEN}  Protocol: relay+ssh${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo "1) Install Gost"
    echo "2) Setup Server (Kharej)"
    echo "3) Setup Client (Iran) + Port Forwarding"
    echo "4) List Tunnels / Status"
    echo "5) Check Connection"
    echo "6) Setup Watchdog (Auto-Reconnect)"
    echo "7) Uninstall Service"
    echo "8) Full Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select: " OPTION

    case $OPTION in
        1)
            install_gost
            read -p "Press Enter to continue..."
            ;;
        2)
            install_gost
            setup_server
            ;;
        3)
            install_gost
            setup_client
            ;;
        4)
            list_tunnels
            ;;
        5)
            check_connection
            ;;
        6)
            setup_watchdog
            ;;
        7)
            uninstall_menu
            ;;
        8)
            full_uninstall
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done

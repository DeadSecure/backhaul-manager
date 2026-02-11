#!/bin/bash

# ==========================================
#  Gost Tunnel Manager v3.0
#  Supports: relay+ssh, relay+tls, relay+wss
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

GOST_BIN="/usr/local/bin/gost"
GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Function to install Gost (from GitHub, NOT apt)
install_gost() {
    if [[ -f "$GOST_BIN" ]]; then
        local ver=$($GOST_BIN -V 2>&1 | head -1)
        echo -e "${GREEN}Gost already installed: ${ver}${NC}"
        read -p "Reinstall? (y/N): " r
        [[ ! $r =~ ^[Yy]$ ]] && return
    fi
    
    echo -e "${YELLOW}Installing Gost from GitHub...${NC}"
    # Remove apt version if exists
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

    wget -O /tmp/gost.gz "$DL_URL"
    gunzip -f /tmp/gost.gz
    chmod +x /tmp/gost
    mv /tmp/gost "$GOST_BIN"
    echo -e "${GREEN}Gost installed: $($GOST_BIN -V 2>&1 | head -1)${NC}"
}

# Protocol Selection
select_protocol() {
    echo ""
    echo -e "${CYAN}Select Protocol:${NC}"
    echo "  1) relay+tls   - TLS encryption [Recommended]"
    echo "  2) relay+wss   - WebSocket Secure (looks like HTTPS)"
    echo "  3) relay+grpc  - gRPC (HTTP/2 + TLS)"
    echo "  4) relay+ssh   - SSH tunnel"
    echo ""
    read -p "Protocol [1]: " proto_opt
    case $proto_opt in
        2) PROTOCOL="relay+wss" ;;
        3) PROTOCOL="relay+grpc" ;;
        4) PROTOCOL="relay+ssh" ;;
        *) PROTOCOL="relay+tls" ;;
    esac
    echo -e "${GREEN}Protocol: ${PROTOCOL}${NC}"
}

# Function to verify connection
check_connection() {
    echo -e "${BLUE}--- Check Tunnel Connection ---${NC}"
    
    # 1. Check services status
    echo -e "${YELLOW}Checking Systemd Services...${NC}"
    SERVICES=$(systemctl list-units --type=service --state=running | grep "gost-ssh-")
    
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No running Gost services found!${NC}"
        read -p "Press Enter to continue..."
        return
    else
        echo -e "${GREEN}Running Services:${NC}"
        echo "$SERVICES"
    fi
    
    # 2. Check listening ports
    echo -e "\n${YELLOW}Checking Listening Ports...${NC}"
    # Extract ports from running services or just show all gost ports
    if command -v netstat &> /dev/null; then
        netstat -tunlp | grep gost
    else
        ss -tunlp | grep gost
    fi
    
    # 3. Simple connectivity test
    echo -e "\n${YELLOW}Testing Connectivity...${NC}"
    read -p "Enter local port to test (e.g. 1080 or 5000): " TEST_PORT
    if [[ ! -z "$TEST_PORT" ]]; then
        echo -e "Testing via SOCKS5..."
        RESPONSE=$(curl -x socks5h://127.0.0.1:$TEST_PORT -s --connect-timeout 5 https://api.ipify.org)
        
        if [[ ! -z "$RESPONSE" ]]; then
             echo -e "${GREEN}SOCKS5 Test Passed! Your IP: $RESPONSE${NC}"
        else
             echo -e "${RED}SOCKS5 Test Failed. (This is expected if port is not a SOCKS proxy)${NC}"
             
             echo -e "Testing via HTTP/Forward..."
             nc -z -v -w5 127.0.0.1 $TEST_PORT
        fi
    fi
    
    read -p "Press Enter to continue..."
}

# Function to create Watchdog
setup_watchdog() {
    echo -e "${BLUE}--- Setup Auto-Reconnect Watchdog ---${NC}"
    
    # Check for installed client services
    SERVICES=$(ls /etc/systemd/system/gost-ssh-client-*.service 2>/dev/null)
    if [ -z "$SERVICES" ]; then
         echo -e "${RED}No Gost Client services found to monitor.${NC}"
         read -p "Press Enter to continue..."
         return
    fi
    
    echo "Select service to monitor:"
    i=1
    declare -A SERVICE_MAP
    for svc_path in $SERVICES; do
        svc_name=$(basename "$svc_path" .service)
        # Extract port from name gost-ssh-client-PORT
        PORT=$(echo "$svc_name" | awk -F'-' '{print $4}')
        echo "$i) $svc_name (Port: $PORT)"
        SERVICE_MAP[$i]=$svc_name
        PORT_MAP[$i]=$PORT
        i=$((i+1))
    done
    echo "0) Cancel"
    
    read -p "Select options: " OPTION
    if [ "$OPTION" == "0" ]; then return; fi
    
    SVC=${SERVICE_MAP[$OPTION]}
    PORT=${PORT_MAP[$OPTION]}
    
    if [ -z "$SVC" ]; then echo "Invalid option"; return; fi
    
    WATCHDOG_SCRIPT="/usr/local/bin/watchdog-$SVC.sh"
    
    # Create monitoring script
    # It checks if port is listening AND if we can connect to it.
    # If not, it restarts the service.
    cat <<EOF > $WATCHDOG_SCRIPT
#!/bin/bash
# Check if service is active
IS_ACTIVE=\$(systemctl is-active $SVC)
if [ "\$IS_ACTIVE" != "active" ]; then
    echo "Service $SVC is not active. Restarting..."
    systemctl restart $SVC
    exit 0
fi

# Check connection (TCP connect)
nc -z -w 5 127.0.0.1 $PORT
if [ \$? -ne 0 ]; then
    echo "Port $PORT is not reachable. Restarting tunnel..."
    systemctl restart $SVC
else
    echo "Tunnel $SVC on port $PORT is healthy."
fi
EOF
    
    chmod +x $WATCHDOG_SCRIPT
    
    # Add to crontab if not exists
    CRON_CMD="* * * * * $WATCHDOG_SCRIPT >> /var/log/gost-watchdog.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_CMD") | crontab -
    
    echo -e "${GREEN}Watchdog installed!${NC}"
    echo -e "It will check the connection every minute and restart if down."
    read -p "Press Enter to continue..."
}

# Function to generate random password
generate_password() {
    < /dev/urandom tr -dc A-Za-z0-9 | head -c 16
}

# Server Setup (Kharej)
setup_server() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Server (KHAREJ)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    select_protocol

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
Description=Gost ${PROTOCOL} Server (port ${PORT})
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

# Client Setup (Iran)
setup_client() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Client (IRAN)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    select_protocol

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

    local MAPS=""
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
Description=Gost ${PROTOCOL} Client (${LOCAL_PORT} -> ${DEST_ADDR})
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
IS_ACTIVE=\$(systemctl is-active $svc_name)
if [ "\$IS_ACTIVE" != "active" ]; then
    systemctl restart $svc_name
    exit 0
fi
nc -z -w 5 127.0.0.1 $port
if [ \$? -ne 0 ]; then
    systemctl restart $svc_name
fi
WDEOF
            chmod +x "$wd_script"
            CRON_CMD="* * * * * $wd_script >> /var/log/gost-watchdog.log 2>&1"
            (crontab -l 2>/dev/null | grep -v "$wd_script"; echo "$CRON_CMD") | crontab -
        done
        echo -e "${GREEN}Watchdog enabled for all ports${NC}"
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
# List / Status
# ==========================================
list_tunnels() {
    echo ""
    echo -e "${CYAN}CONFIGURED TUNNELS${NC}"
    echo ""

    local found=false
    for f in /etc/systemd/system/gost-server-*.service /etc/systemd/system/gost-client-*.service /etc/systemd/system/gost-ssh-*.service /etc/systemd/system/gost-tls-*.service; do
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
    echo "Removes: all services + gost binary + watchdogs"
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
    crontab -l 2>/dev/null | grep -v "gost-watchdog" | crontab - 2>/dev/null
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
    echo -e "${GREEN}  Gost Tunnel Manager v3.0${NC}"
    echo -e "${GREEN}  relay+tls / relay+wss / relay+ssh${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo "1) Install Gost"
    echo "2) Setup Server (Kharej)"
    echo "3) Setup Client (Iran) + Port Forwarding"
    echo "4) List Tunnels / Status"
    echo "5) Check Connection"
    echo "6) Uninstall Service"
    echo "7) Full Uninstall"
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
            uninstall_menu
            ;;
        7)
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

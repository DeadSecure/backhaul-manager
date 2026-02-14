#!/bin/bash

# ==========================================
#  Reverse SSH Tunnel Manager v1.0
#  Native OpenSSH | Optimized for Speed
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SSH_KEY="/root/.ssh/rssh_key"
SYSCTL_CONF="/etc/sysctl.d/99-rssh-optimization.conf"
PREFIX="rssh-tunnel"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

# ==========================================
# Kernel Optimization (TCP + BBR)
# ==========================================
optimize_kernel() {
    echo -e "${BLUE}--- Kernel TCP/BBR Optimization ---${NC}"

    # Check current BBR status
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo -e "  Current congestion control: ${YELLOW}${current_cc}${NC}"

    cat <<EOF > $SYSCTL_CONF
# ==========================================
# Reverse SSH Tunnel Optimization
# ==========================================

# TCP Buffer Sizes (16MB max)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# BBR Congestion Control (Google)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Performance
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

# Connection Tracking
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
EOF

    sysctl -p $SYSCTL_CONF > /dev/null 2>&1

    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo -e "  New congestion control: ${GREEN}${new_cc}${NC}"
    echo -e "${GREEN}Kernel optimization applied!${NC}"
}

# ==========================================
# Setup Server (Kharej - Outside)
# ==========================================
setup_server() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Server (KHAREJ) - Reverse SSH${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    local SSHD_CONF="/etc/ssh/sshd_config"
    local BACKUP="/etc/ssh/sshd_config.bak.$(date +%s)"

    # Backup sshd_config
    cp "$SSHD_CONF" "$BACKUP"
    echo -e "${YELLOW}Backup: ${BACKUP}${NC}"

    # Function to set or add a config line
    set_sshd_param() {
        local key="$1"
        local val="$2"
        if grep -qE "^#?${key}" "$SSHD_CONF"; then
            sed -i "s|^#*${key}.*|${key} ${val}|" "$SSHD_CONF"
        else
            echo "${key} ${val}" >> "$SSHD_CONF"
        fi
    }

    # Apply server-side optimizations
    set_sshd_param "GatewayPorts" "yes"
    set_sshd_param "UseDNS" "no"
    set_sshd_param "ClientAliveInterval" "15"
    set_sshd_param "ClientAliveCountMax" "4"
    set_sshd_param "MaxSessions" "20"
    set_sshd_param "MaxStartups" "10:30:60"
    set_sshd_param "TCPKeepAlive" "yes"
    set_sshd_param "PermitRootLogin" "yes"
    set_sshd_param "PubkeyAuthentication" "yes"

    # Restart sshd
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null

    # Kernel optimization
    optimize_kernel

    local IP=$(hostname -I | awk '{print $1}')
    local SSH_PORT=$(grep -E "^Port " "$SSHD_CONF" | awk '{print $2}')
    SSH_PORT=${SSH_PORT:-22}

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Server Ready!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  IP         : ${IP}${NC}"
    echo -e "${GREEN}  SSH Port   : ${SSH_PORT}${NC}"
    echo -e "${GREEN}  GatewayPorts: yes${NC}"
    echo -e "${GREEN}  BBR        : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Now run the CLIENT setup on your Iran server.${NC}"
    read -p "Press Enter to continue..."
}

# ==========================================
# Generate SSH Key
# ==========================================
generate_ssh_key() {
    if [[ -f "$SSH_KEY" ]]; then
        echo -e "${GREEN}SSH Key already exists: ${SSH_KEY}${NC}"
        read -p "Regenerate? (y/N): " r
        [[ ! $r =~ ^[Yy]$ ]] && return 0
    fi

    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    echo -e "${GREEN}SSH Key generated: ${SSH_KEY}${NC}"
}

# ==========================================
# Copy Key to Server
# ==========================================
copy_key_to_server() {
    local server_ip="$1"
    local ssh_port="$2"
    local ssh_user="$3"

    echo -e "${YELLOW}Copying SSH key to ${ssh_user}@${server_ip}:${ssh_port}...${NC}"
    echo -e "${CYAN}You will be asked for the server password (one time only)${NC}"

    ssh-copy-id -i "${SSH_KEY}.pub" -p "$ssh_port" -o StrictHostKeyChecking=no "${ssh_user}@${server_ip}"

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Key copied successfully!${NC}"
        return 0
    else
        echo -e "${RED}Failed to copy key. Check password and connectivity.${NC}"
        return 1
    fi
}

# ==========================================
# Setup Client (Iran)
# ==========================================
setup_client() {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setup Client (IRAN) - Reverse SSH${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    read -p "Server (Kharej) IP: " SERVER_IP
    [[ -z "$SERVER_IP" ]] && { echo -e "${RED}IP required${NC}"; return; }

    read -p "Server SSH Port [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    read -p "Server SSH User [root]: " SSH_USER
    SSH_USER=${SSH_USER:-root}

    # Generate key & copy
    generate_ssh_key
    copy_key_to_server "$SERVER_IP" "$SSH_PORT" "$SSH_USER"
    if [[ $? -ne 0 ]]; then
        read -p "Continue anyway? (y/N): " c
        [[ ! $c =~ ^[Yy]$ ]] && return
    fi

    # Kernel optimization (client side)
    optimize_kernel

    echo ""
    echo -e "${CYAN}PORT FORWARDING${NC}"
    echo -e "  ${YELLOW}Local${NC}  = Port on this Iran server"
    echo -e "  ${YELLOW}Remote${NC} = Port exposed on Kharej server"
    echo ""

    local MAP_COUNT=0
    local SERVICES_LIST=""

    while true; do
        read -p "Local port (or Enter to finish): " LOCAL_PORT
        [[ -z "$LOCAL_PORT" ]] && break

        read -p "Remote port [${LOCAL_PORT}]: " REMOTE_PORT
        REMOTE_PORT=${REMOTE_PORT:-$LOCAL_PORT}

        SERVICE_NAME="${PREFIX}-${LOCAL_PORT}"

        # Build optimized SSH command
        EXEC_CMD="/usr/bin/ssh -N \
-R 0.0.0.0:${REMOTE_PORT}:127.0.0.1:${LOCAL_PORT} \
-o Ciphers=aes128-gcm@openssh.com \
-o Compression=no \
-o IPQoS=throughput \
-o ServerAliveInterval=15 \
-o ServerAliveCountMax=4 \
-o TCPKeepAlive=yes \
-o ExitOnForwardFailure=yes \
-o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null \
-o BatchMode=yes \
-i ${SSH_KEY} \
${SSH_USER}@${SERVER_IP} -p ${SSH_PORT}"

        cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Reverse SSH Tunnel (${LOCAL_PORT} -> ${REMOTE_PORT} on ${SERVER_IP})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${EXEC_CMD}
Restart=always
RestartSec=10
StartLimitInterval=0
User=root

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable $SERVICE_NAME > /dev/null 2>&1
        systemctl restart $SERVICE_NAME

        MAP_COUNT=$((MAP_COUNT + 1))
        SERVICES_LIST="${SERVICES_LIST}  ${LOCAL_PORT} -> ${REMOTE_PORT} on ${SERVER_IP}\n"
        echo -e "  ${GREEN}Added: ${LOCAL_PORT} -> ${REMOTE_PORT}${NC}"
    done

    if [[ $MAP_COUNT -eq 0 ]]; then
        echo -e "${RED}No port mappings added${NC}"
        return
    fi

    # Offer watchdog
    read -p "Enable Watchdog (Auto-Reconnect)? (Y/n): " WD
    WD=${WD:-Y}
    if [[ "$WD" =~ ^[Yy]$ ]]; then
        install_watchdog_for_all
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Client Ready!${NC}"
    echo -e "${GREEN}  Server     : ${SSH_USER}@${SERVER_IP}:${SSH_PORT}${NC}"
    echo -e "${GREEN}  Cipher     : aes128-gcm (HW accelerated)${NC}"
    echo -e "${GREEN}  BBR        : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC}"
    echo -e "${GREEN}  Mappings   : ${MAP_COUNT}${NC}"
    printf "$SERVICES_LIST"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    read -p "Press Enter to continue..."
}

# ==========================================
# Install Watchdog for all client tunnels
# ==========================================
install_watchdog_for_all() {
    for svc_file in /etc/systemd/system/${PREFIX}-*.service; do
        [[ ! -f "$svc_file" ]] && continue
        local svc_name=$(basename "$svc_file" .service)
        local port=$(echo "$svc_name" | sed "s/${PREFIX}-//")

        # Extract server IP from service file
        local server_ip=$(grep "ExecStart" "$svc_file" | grep -oP '[^@]+@\K[^ ]+' | head -1)

        local wd_script="/usr/local/bin/watchdog-${svc_name}.sh"

        cat > "$wd_script" <<WDEOF
#!/bin/bash
# Watchdog for $svc_name
LOG_PREFIX="[\$(date '+%Y-%m-%d %H:%M:%S')] [$svc_name]"

# 1. Check systemd service
IS_ACTIVE=\$(systemctl is-active $svc_name)
if [ "\$IS_ACTIVE" != "active" ]; then
    echo "\$LOG_PREFIX Service down. Restarting..."
    systemctl restart $svc_name
    exit 0
fi

# 2. Check SSH process is alive
SSH_PID=\$(systemctl show -p MainPID --value $svc_name)
if [ -z "\$SSH_PID" ] || [ "\$SSH_PID" -eq 0 ]; then
    echo "\$LOG_PREFIX No SSH process. Restarting..."
    systemctl restart $svc_name
    exit 0
fi

# 3. Check remote port is accepting connections (via SSH)
ssh -i ${SSH_KEY} -p \$(grep -oP '\-p \K[0-9]+' /etc/systemd/system/${svc_name}.service | head -1) \
    -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
    ${server_ip} "nc -z 127.0.0.1 ${port} 2>/dev/null" 2>/dev/null

if [ \$? -ne 0 ]; then
    echo "\$LOG_PREFIX Remote port ${port} not open. Restarting..."
    systemctl restart $svc_name
fi
WDEOF
        chmod +x "$wd_script"

        CRON_CMD="* * * * * $wd_script >> /var/log/rssh-watchdog.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "$wd_script"; echo "$CRON_CMD") | crontab -
    done
    echo -e "${GREEN}Watchdog enabled for all tunnels${NC}"
}

# ==========================================
# Setup Watchdog (Manual)
# ==========================================
setup_watchdog() {
    echo -e "${BLUE}--- Setup Watchdog ---${NC}"

    SERVICES=$(ls /etc/systemd/system/${PREFIX}-*.service 2>/dev/null)
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No Reverse SSH tunnel services found.${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Select service to monitor:"
    local i=1
    declare -A SERVICE_MAP
    for svc_path in $SERVICES; do
        local svc_name=$(basename "$svc_path" .service)
        local status=$(systemctl is-active "$svc_name" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $i) ${GREEN}[ON]${NC}  $svc_name"
        else
            echo -e "  $i) ${RED}[OFF]${NC} $svc_name"
        fi
        SERVICE_MAP[$i]=$svc_name
        i=$((i+1))
    done
    echo "  A) All services"
    echo "  0) Cancel"

    read -p "Select: " CHOICE

    [[ "$CHOICE" == "0" ]] && return

    if [[ "$CHOICE" =~ ^[Aa]$ ]]; then
        install_watchdog_for_all
    else
        local svc=${SERVICE_MAP[$CHOICE]}
        if [ -z "$svc" ]; then
            echo "Invalid option"
            return
        fi
        # Install for single service
        local port=$(echo "$svc" | sed "s/${PREFIX}-//")
        local server_ip=$(grep "ExecStart" "/etc/systemd/system/${svc}.service" | grep -oP '[^@]+@\K[^ ]+' | head -1)
        local wd_script="/usr/local/bin/watchdog-${svc}.sh"

        cat > "$wd_script" <<WDEOF
#!/bin/bash
LOG_PREFIX="[\$(date '+%Y-%m-%d %H:%M:%S')] [$svc]"

IS_ACTIVE=\$(systemctl is-active $svc)
if [ "\$IS_ACTIVE" != "active" ]; then
    echo "\$LOG_PREFIX Service down. Restarting..."
    systemctl restart $svc
    exit 0
fi

SSH_PID=\$(systemctl show -p MainPID --value $svc)
if [ -z "\$SSH_PID" ] || [ "\$SSH_PID" -eq 0 ]; then
    echo "\$LOG_PREFIX No SSH process. Restarting..."
    systemctl restart $svc
    exit 0
fi
WDEOF
        chmod +x "$wd_script"
        CRON_CMD="* * * * * $wd_script >> /var/log/rssh-watchdog.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "$wd_script"; echo "$CRON_CMD") | crontab -
        echo -e "${GREEN}Watchdog installed for $svc${NC}"
    fi
    read -p "Press Enter to continue..."
}

# ==========================================
# Check Connection
# ==========================================
check_connection() {
    echo -e "${BLUE}--- Check Tunnel Connection ---${NC}"

    SERVICES=$(systemctl list-units --type=service --state=running | grep "${PREFIX}-")

    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No running Reverse SSH tunnel services found!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${GREEN}Running Services:${NC}"
    echo "$SERVICES"

    # Check listening ports
    echo -e "\n${YELLOW}Checking Listening Ports...${NC}"
    if command -v ss &> /dev/null; then
        ss -tunlp | grep ssh | head -20
    elif command -v netstat &> /dev/null; then
        netstat -tunlp | grep ssh | head -20
    fi

    # Show detailed service info
    echo -e "\n${YELLOW}Service Details:${NC}"
    for svc_file in /etc/systemd/system/${PREFIX}-*.service; do
        [[ ! -f "$svc_file" ]] && continue
        local svc_name=$(basename "$svc_file" .service)
        local status=$(systemctl is-active "$svc_name" 2>/dev/null)
        local uptime=$(systemctl show "$svc_name" --property=ActiveEnterTimestamp --value 2>/dev/null)
        local pid=$(systemctl show -p MainPID --value "$svc_name" 2>/dev/null)

        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[ON]${NC}  $svc_name | PID: $pid | Since: $uptime"
        else
            echo -e "  ${RED}[OFF]${NC} $svc_name"
        fi
    done

    # Manual test
    echo ""
    read -p "Test a specific local port (or Enter to skip): " TEST_PORT
    if [[ ! -z "$TEST_PORT" ]]; then
        if nc -z -w 5 127.0.0.1 $TEST_PORT 2>/dev/null; then
            echo -e "${GREEN}TCP port $TEST_PORT is OPEN${NC}"
        else
            echo -e "${RED}TCP port $TEST_PORT is CLOSED${NC}"
        fi
    fi

    read -p "Press Enter to continue..."
}

# ==========================================
# List Tunnels
# ==========================================
list_tunnels() {
    echo ""
    echo -e "${CYAN}CONFIGURED REVERSE SSH TUNNELS${NC}"
    echo ""

    local found=false
    for f in /etc/systemd/system/${PREFIX}-*.service; do
        [[ ! -f "$f" ]] && continue
        found=true
        local svc=$(basename "$f" .service)
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        local desc=$(grep "Description=" "$f" | sed 's/Description=//')

        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[ON]${NC}  $svc"
            echo -e "        ${CYAN}${desc}${NC}"
        else
            echo -e "  ${RED}[OFF]${NC} $svc"
            echo -e "        ${CYAN}${desc}${NC}"
        fi
    done

    $found || echo -e "  ${YELLOW}No tunnels configured${NC}"
    echo ""
    read -p "Press Enter to continue..."
}

# ==========================================
# View Logs
# ==========================================
view_logs() {
    echo -e "${BLUE}--- View Logs ---${NC}"

    SERVICES=$(ls /etc/systemd/system/${PREFIX}-*.service 2>/dev/null)
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No services found.${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Select service:"
    local i=1
    declare -A SERVICE_MAP
    for svc_path in $SERVICES; do
        local svc_name=$(basename "$svc_path" .service)
        echo "  $i) $svc_name"
        SERVICE_MAP[$i]=$svc_name
        i=$((i+1))
    done
    echo "  W) Watchdog logs"
    echo "  0) Cancel"

    read -p "Select: " CHOICE

    [[ "$CHOICE" == "0" ]] && return

    if [[ "$CHOICE" =~ ^[Ww]$ ]]; then
        if [[ -f /var/log/rssh-watchdog.log ]]; then
            tail -50 /var/log/rssh-watchdog.log
        else
            echo -e "${YELLOW}No watchdog log found${NC}"
        fi
    else
        local svc=${SERVICE_MAP[$CHOICE]}
        if [ -z "$svc" ]; then
            echo "Invalid option"
        else
            journalctl -u "$svc" --no-pager -n 50
        fi
    fi

    read -p "Press Enter to continue..."
}

# ==========================================
# Uninstall Service
# ==========================================
uninstall_menu() {
    echo -e "${BLUE}--- Uninstall Service ---${NC}"

    SERVICES=$(ls /etc/systemd/system/${PREFIX}-*.service 2>/dev/null)

    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No Reverse SSH services found.${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Found services:"
    local i=1
    declare -A SERVICE_MAP
    for svc_path in $SERVICES; do
        local svc_name=$(basename "$svc_path" .service)
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
        read -p "Remove ALL Reverse SSH services? (yes/NO): " c
        [[ "$c" != "yes" ]] && return
        for svc_path in $SERVICES; do
            local svc=$(basename "$svc_path" .service)
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            rm -f "$svc_path"
            rm -f "/usr/local/bin/watchdog-${svc}.sh"
            crontab -l 2>/dev/null | grep -v "watchdog-${svc}" | crontab - 2>/dev/null
        done
        systemctl daemon-reload
        echo -e "${GREEN}All services removed${NC}"
    else
        local SVC=${SERVICE_MAP[$CHOICE]}
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
    echo "Removes: all services + SSH keys + watchdogs + cron + kernel config"
    read -p "Are you sure? (yes/NO): " c
    [[ "$c" != "yes" ]] && return

    # Stop and remove all services
    for f in /etc/systemd/system/${PREFIX}-*.service; do
        [[ ! -f "$f" ]] && continue
        local svc=$(basename "$f" .service)
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$f"
        rm -f "/usr/local/bin/watchdog-${svc}.sh"
    done

    # Remove SSH key
    rm -f "$SSH_KEY" "${SSH_KEY}.pub"

    # Remove kernel config
    rm -f "$SYSCTL_CONF"

    # Clean crontab
    crontab -l 2>/dev/null | grep -v "rssh-tunnel\|rssh-watchdog\|watchdog-rssh" | crontab - 2>/dev/null

    # Remove watchdog log
    rm -f /var/log/rssh-watchdog.log

    systemctl daemon-reload

    echo -e "${GREEN}Everything removed!${NC}"
    exit 0
}

# ==========================================
# Main Menu
# ==========================================
while true; do
    clear
    echo -e "${MAGENTA}═══════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  Reverse SSH Tunnel Manager v1.0${NC}"
    echo -e "${MAGENTA}  Native OpenSSH | BBR Optimized${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}--- Setup ---${NC}"
    echo "1) Setup Server (Kharej - Outside)"
    echo "2) Setup Client (Iran) + Port Forwarding"
    echo ""
    echo -e "${CYAN}--- Management ---${NC}"
    echo "3) List Tunnels"
    echo "4) Check Connection"
    echo "5) View Logs"
    echo "6) Setup Watchdog"
    echo ""
    echo -e "${CYAN}--- Remove ---${NC}"
    echo "7) Uninstall Service"
    echo "8) Full Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select: " OPTION

    case $OPTION in
        1) setup_server ;;
        2) setup_client ;;
        3) list_tunnels ;;
        4) check_connection ;;
        5) view_logs ;;
        6) setup_watchdog ;;
        7) uninstall_menu ;;
        8) full_uninstall ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done

#!/bin/bash

# Coloring
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Function to install Gost
install_gost() {
    if command -v gost &> /dev/null; then
        echo -e "${GREEN}Gost is already installed.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Installing Gost...${NC}"
    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
            ;;
        aarch64)
            GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-arm64-2.11.5.gz"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac

    wget -O gost.gz "$GOST_URL"
    gunzip gost.gz
    chmod +x gost
    mv gost /usr/local/bin/
    echo -e "${GREEN}Gost installed successfully!${NC}"
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
    echo -e "${BLUE}--- Setup Server (Outside Iran) ---${NC}"
    read -p "Enter Port for Tunnel (Default: 2222): " PORT
    PORT=${PORT:-2222}
    
    read -p "Enter Username (Default: admin): " USERNAME
    USERNAME=${USERNAME:-admin}
    
    PASSWORD=$(generate_password)
    echo -e "${YELLOW}Generated Password: ${GREEN}$PASSWORD${NC}"
    read -p "Use this password or enter your own (Press Enter to keep): " INPUT_PASS
    if [[ ! -z "$INPUT_PASS" ]]; then
        PASSWORD=$INPUT_PASS
    fi

    # MTU Configuration
    read -p "Enter MTU (Default: 140): " MTU
    MTU=${MTU:-140}
    
    SERVICE_NAME="gost-ssh-server"
    
    cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Gost SSH Tunnel Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L "relay+ssh://$USERNAME:$PASSWORD@:$PORT"
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
    
    # Get IP
    IP=$(hostname -I | awk '{print $1}')
    
    echo -e "${GREEN}Server Setup Complete!${NC}"
    echo -e "----------------------------------------"
    echo -e "Server IP: ${YELLOW}$IP${NC}"
    echo -e "Port:      ${YELLOW}$PORT${NC}"
    echo -e "User:      ${YELLOW}$USERNAME${NC}"
    echo -e "Pass:      ${YELLOW}$PASSWORD${NC}"
    echo -e "Protocol:  ${YELLOW}relay+ssh${NC}"
    echo -e "MTU:       ${YELLOW}$MTU (Set on Client)${NC}"
    echo -e "----------------------------------------"
    echo -e "Copy these details for the client setup."
    read -p "Press Enter to continue..."
}

# Client Setup (Iran)
setup_client() {
    echo -e "${BLUE}--- Setup Client (Iran) ---${NC}"
    echo "This will forward traffic from a local port to a destination port on the server side."
    
    read -p "Enter Server IP: " SERVER_IP
    read -p "Enter Server Port (Tunnel Port, e.g. 2222): " SERVER_PORT
    read -p "Enter Username: " USERNAME
    read -p "Enter Password: " PASSWORD
    
    echo -e "\n${YELLOW}--- Forwarding Configuration ---${NC}"
    read -p "Enter Local Listening Port (e.g. 5000): " LOCAL_PORT
    read -p "Enter Destination IP:Port on Server (e.g. 127.0.0.1:3000): " DEST_ADDR

    # MTU Configuration
    read -p "Enter MTU for connect (Default: 140): " MTU
    MTU=${MTU:-140}

    SERVICE_NAME="gost-ssh-client-$LOCAL_PORT"
    
    EXEC_CMD="/usr/local/bin/gost -L tcp://:$LOCAL_PORT/$DEST_ADDR -L udp://:$LOCAL_PORT/$DEST_ADDR -F \"relay+ssh://$USERNAME:$PASSWORD@$SERVER_IP:$SERVER_PORT?mtu=$MTU\""

    cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Gost SSH Forwarding Client ($LOCAL_PORT -> $DEST_ADDR)
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
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    
    echo -e "${GREEN}Client Setup Complete!${NC}"
    echo -e "Traffic on Local Port ${YELLOW}$LOCAL_PORT${NC} is now forwarded to ${YELLOW}$DEST_ADDR${NC} via the tunnel."
    echo -e "Using UDP & TCP."
    
    # Ask for Watchdog Auto-Setup
    read -p "Do you want to enable Auto-Reconnect Watchdog? (y/n): " WD
    if [[ "$WD" == "y" ]]; then
         # Manually invoke watchdog logic for this service
         WATCHDOG_SCRIPT="/usr/local/bin/watchdog-$SERVICE_NAME.sh"
         cat <<EOF > \$WATCHDOG_SCRIPT
#!/bin/bash
IS_ACTIVE=\$(systemctl is-active $SERVICE_NAME)
if [ "\$IS_ACTIVE" != "active" ]; then
    systemctl restart $SERVICE_NAME
    exit 0
fi
nc -z -w 5 127.0.0.1 $LOCAL_PORT
if [ \$? -ne 0 ]; then
    systemctl restart $SERVICE_NAME
fi
EOF
        chmod +x \$WATCHDOG_SCRIPT
        CRON_CMD="* * * * * \$WATCHDOG_SCRIPT >> /var/log/gost-watchdog.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "\$WATCHDOG_SCRIPT"; echo "\$CRON_CMD") | crontab -
        echo -e "${GREEN}Watchdog enabled.${NC}"
    fi

    read -p "Press Enter to continue..."
}

uninstall_menu() {
    echo -e "${BLUE}--- Uninstall Service ---${NC}"
    
    # List all gost services
    echo "Found services:"
    # Use grep to find services starting with gost-ssh-
    SERVICES=$(ls /etc/systemd/system/gost-ssh-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No Gost services found.${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    
    i=1
    declare -A SERVICE_MAP
    for svc_path in $SERVICES; do
        svc_name=$(basename "$svc_path" .service)
        echo "$i) $svc_name"
        SERVICE_MAP[$i]=$svc_name
        i=$((i+1))
    done
    echo "0) Cancel"
    
    read -p "Select service to uninstall: " CHOICE
    
    if [ "$CHOICE" == "0" ]; then
        return
    fi
    
    SVC=${SERVICE_MAP[$CHOICE]}
    
    if [ ! -z "$SVC" ]; then
        systemctl stop $SVC
        systemctl disable $SVC
        rm /etc/systemd/system/$SVC.service
        
        # Remove watchdog if exists
        WD_SCRIPT="/usr/local/bin/watchdog-$SVC.sh"
        if [ -f "$WD_SCRIPT" ]; then
            rm "$WD_SCRIPT"
            # Remove from cron
            crontab -l | grep -v "$WD_SCRIPT" | crontab -
            echo "Watchdog removed."
        fi
        
        systemctl daemon-reload
        echo -e "${GREEN}Service '$SVC' removed successfully.${NC}"
    else
         echo "Invalid choice."
    fi
    read -p "Press Enter to continue..."
}


# Main Menu
while true; do
    clear
    echo -e "${BLUE}=== Gost SSH+Relay Tunnel Manager (Port Forwarding & MTU) ===${NC}"
    echo "1) Install Gost"
    echo "2) Setup Server (Kharej / Destination)"
    echo "3) Setup Client (Iran / Origin) - Port Forwarding"
    echo "4) Uninstall Service"
    echo "5) Check Connection / Status"
    echo "6) Setup Watchdog (Auto Reconnect)"
    echo "0) Exit"
    read -p "Select option: " OPTION

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
            uninstall_menu
            ;;
        5)
            check_connection
            ;;
        6)
           setup_watchdog
           ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done

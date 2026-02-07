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
    
    # Logic:
    # -L tcp://:LOCAL_PORT/DEST_ADDR -L udp://:LOCAL_PORT/DEST_ADDR
    # -F relay+ssh://...
    
    # Explanation:
    # We want to listen on LOCAL_PORT (tcp/udp) and forward specifically to DEST_ADDR via the tunnel.
    # The default behavior of -L :LOCAL_PORT acts as a generic proxy (socks5/http).
    # To do port forwarding, we specify the target in -L.
    
    EXEC_CMD="/usr/local/bin/gost -L tcp://:$LOCAL_PORT/$DEST_ADDR -L udp://:$LOCAL_PORT/$DEST_ADDR -F \"relay+ssh://$USERNAME:$PASSWORD@$SERVER_IP:$SERVER_PORT?mtu=$MTU\""

    cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Gost SSH Forwarding Client ($LOCAL_PORT -> $DEST_ADDR)
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_CMD
Restart=always
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
}

uninstall_menu() {
    echo -e "${BLUE}--- Uninstall Service ---${NC}"
    
    # List all gost services
    echo "Found services:"
    # Use grep to find services starting with gost-ssh-
    SERVICES=$(ls /etc/systemd/system/gost-ssh-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${RED}No Gost services found.${NC}"
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
        systemctl daemon-reload
        echo -e "${GREEN}Service '$SVC' removed successfully.${NC}"
    else
         echo "Invalid choice."
    fi
}


# Main Menu
while true; do
clear
    echo -e "${BLUE}=== Gost SSH+Relay Tunnel Manager (Port Forwarding & MTU) ===${NC}"
    echo "1) Install Gost"
    echo "2) Setup Server (Kharej / Destination)"
    echo "3) Setup Client (Iran / Origin) - Port Forwarding"
    echo "4) Uninstall Service"
    echo "0) Exit"
    read -p "Select option: " OPTION

    case $OPTION in
        1)
            install_gost
            ;;
        2)
            install_gost
            setup_server
            exit 0
            ;;
        3)
            install_gost
            setup_client
            exit 0
            ;;
        4)
            uninstall_menu
            read -p "Press Enter to continue..."
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done

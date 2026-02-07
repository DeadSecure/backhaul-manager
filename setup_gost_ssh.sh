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
    
    read -p "Enter Server IP: " SERVER_IP
    read -p "Enter Server Port: " SERVER_PORT
    read -p "Enter Username: " USERNAME
    read -p "Enter Password: " PASSWORD
    
    read -p "Enter Local Binding Port (SOCKS5/HTTP) (Default: 1080): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-1080}

    # MTU Configuration
    read -p "Enter MTU for connect (Default: 140): " MTU
    MTU=${MTU:-140}

    SERVICE_NAME="gost-ssh-client"
    
    EXEC_CMD="/usr/local/bin/gost -L :$LOCAL_PORT -F \"relay+ssh://$USERNAME:$PASSWORD@$SERVER_IP:$SERVER_PORT?mtu=$MTU\""

    cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Gost SSH Tunnel Client
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
    echo -e "SOCKS5/HTTP Proxy is now running on port: ${YELLOW}$LOCAL_PORT${NC}"
    echo -e "Connect with MTU: ${YELLOW}$MTU${NC}"
    echo -e "You can test it with: curl -x socks5h://127.0.0.1:$LOCAL_PORT https://api.ipify.org"
}

uninstall_menu() {
    echo -e "${BLUE}--- Uninstall Service ---${NC}"
    
    # Check for installed services
    SERVER_EXISTS=false
    CLIENT_EXISTS=false
    
    if [ -f "/etc/systemd/system/gost-ssh-server.service" ]; then
        SERVER_EXISTS=true
    fi
    if [ -f "/etc/systemd/system/gost-ssh-client.service" ]; then
        CLIENT_EXISTS=true
    fi
    
    if [ "$SERVER_EXISTS" = false ] && [ "$CLIENT_EXISTS" = false ]; then
        echo -e "${RED}No Gost services found.${NC}"
        return
    fi
    
    echo "Found services:"
    if [ "$SERVER_EXISTS" = true ]; then
        echo "1) gost-ssh-server"
    fi
    if [ "$CLIENT_EXISTS" = true ]; then
        echo "2) gost-ssh-client"
    fi
    echo "0) Cancel"
    
    read -p "Select service to uninstall: " CHOICE
    
    SVC=""
    case $CHOICE in
        1)
            if [ "$SERVER_EXISTS" = true ]; then
                SVC="gost-ssh-server"
            else
                echo "Invalid choice."
            fi
            ;;
        2)
            if [ "$CLIENT_EXISTS" = true ]; then
                SVC="gost-ssh-client"
            else
                echo "Invalid choice."
            fi
            ;;
        0)
            return
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
    
    if [ ! -z "$SVC" ]; then
        systemctl stop $SVC
        systemctl disable $SVC
        rm /etc/systemd/system/$SVC.service
        systemctl daemon-reload
        echo -e "${GREEN}Service '$SVC' removed successfully.${NC}"
    fi
}


# Main Menu
while true; do
    echo -e "${BLUE}=== Gost SSH+Relay Tunnel Manager (MTU Support) ===${NC}"
    echo "1) Install Gost"
    echo "2) Setup Server (Kharej / Destination)"
    echo "3) Setup Client (Iran / Origin)"
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
            exit 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done

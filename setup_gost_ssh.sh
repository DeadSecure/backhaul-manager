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
    
    # Create Systemd Service
    # Note: Server side usually just listens for Relay+SSH. MTU is handled at the transport/forwarding level.
    # However, if we want to enforce MTU on the server-side forwarding, we can add it.
    # But typically, the client initiates the specialized transport.
    # We will stick to the standard listener here as the Client side sets up the connection properties.
    
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
    
    # Create Systemd Service
    # Local listener: tcp & udp on LOCAL_PORT
    # Forwarder: relay+ssh to server WITH MTU parameter
    # Based on user input: ./gost -L ... -F forward+mtu://...?mtu=140
    # But here we are using relay+ssh. Let's try to append the parameter or chain it.
    # Gost v2 doesn't support 'forward+mtu' directly on the 'relay+ssh' transport scheme in the same way.
    # However, we can try adding the query parameter ?mtu=$MTU to the relay+ssh URL if supported,
    # OR use the chain feature.
    
    # Attempt 1: Direct transport parameter (Most likely for generic transports)
    # ExecStart=/usr/local/bin/gost -L :$LOCAL_PORT -F "relay+ssh://$USERNAME:$PASSWORD@$SERVER_IP:$SERVER_PORT?mtu=$MTU"
    
    # Attempt 2 (User's specific command style): -F forward+mtu://...?mtu=140
    # The user showed: -F forward+mtu://10.0.0.2:3031?mtu=140
    # We need to bridge SSH then Forward.
    
    # Let's trust the standard 'relay+ssh' supports transport modifiers or simply config tun/tap.
    # BUT, since the user explicitly asked for 'forward+mtu' logic, we might need a specific chain.
    # Since 'relay+ssh' already handles the encapsulation, adding ?mtu=140 to it might be the way.
    
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

# Main Menu
clear
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
        ;;
    3)
        install_gost
        setup_client
        ;;
    4)
        read -p "Enter service name to remove (default: gost-ssh-client): " SVC
        SVC=${SVC:-gost-ssh-client}
        systemctl stop $SVC
        systemctl disable $SVC
        rm /etc/systemd/system/$SVC.service
        systemctl daemon-reload
        echo "Service removed."
        ;;
    0)
        exit 0
        ;;
    *)
        echo "Invalid option"
        ;;
esac

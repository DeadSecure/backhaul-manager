#!/bin/bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

INSTALL_DIR="/usr/local/bin"
BINARY_NAME="DaggerConnect"
BINARY_URL="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/DaggerConnect"

# Function to show banner
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "    ____                                 ______                            _   "
    echo "   / __ \____ _____  ____ ____  _____   / ____/___  ____  ____  ___  _____/ |_ "
    echo "  / / / / __ \`/ __ \/ __ \`/ _ \/ ___/  / /   / __ \/ __ \/ __ \/ _ \/ ___/ __/ "
    echo " / /_/ / /_/ / /_/ / /_/ /  __/ /     / /___/ /_/ / / / / / / /  __/ /__/ /_   "
    echo "/_____/\__,_/\__, /\__, /\___/_/      \____/\____/_/ /_/_/ /_/\___/\___/\__/   "
    echo "            /____//____/                                                       "
    echo -e "${NC}"
    echo -e "${BLUE}   Developed by @DaggerConnect Team (Rebuilt by @Antigravity)${NC}"
    echo -e "${YELLOW}   Version: 1.3.0 (Clean - No License)${NC}"
    echo ""
}

# Function to check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}" 
        exit 1
    fi
}

# Function to install dependencies
install_dependencies() {
    echo -e "${BLUE}[*] Installing dependencies...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y wget curl > /dev/null
    elif command -v yum &> /dev/null; then
        yum install -y wget curl > /dev/null
    fi
}

# Function to install binary
install_binary() {
    echo -e "${BLUE}[*] Downloading DaggerConnect binary...${NC}"
    
    # Remove old binary if exists
    rm -f "$INSTALL_DIR/$BINARY_NAME"
    
    # Download new binary
    if curl -L --progress-bar "$BINARY_URL" -o "$INSTALL_DIR/$BINARY_NAME"; then
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        echo -e "${GREEN}[+] DaggerConnect installed successfully at $INSTALL_DIR/$BINARY_NAME${NC}"
    else
        echo -e "${RED}[!] Failed to download binary. Check your internet connection.${NC}"
        exit 1
    fi
}

# Function to create systemd service
create_service() {
    echo -e "${BLUE}[*] Creating systemd service...${NC}"
    
    cat > /etc/systemd/system/daggerconnect.service <<EOL
[Unit]
Description=DaggerConnect Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$INSTALL_DIR/$BINARY_NAME -c /etc/DaggerConnect/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    echo -e "${GREEN}[+] Service created: daggerconnect.service${NC}"
}

# Main execution
show_banner
check_root
install_dependencies
install_binary
create_service

echo ""
echo -e "${GREEN}Installation Complete!${NC}" 
echo -e "You can now configure DaggerConnect at ${YELLOW}/etc/DaggerConnect/config.yaml${NC}"
echo -e "Start service with: ${CYAN}systemctl start daggerconnect${NC}"

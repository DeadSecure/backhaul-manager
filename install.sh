#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════
#  Backhaul Manager - Quick Install Script
# ═══════════════════════════════════════════════════════════════════════════════

set -e

REPO_URL="https://raw.githubusercontent.com/AhmadXp/backhaul-manager/main"
INSTALL_PATH="/root/backhaul-manager.sh"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║           Backhaul Manager - Quick Installer                      ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

echo -e "${GREEN}[1/3]${NC} Downloading Backhaul Manager..."
wget -q -O "$INSTALL_PATH" "${REPO_URL}/backhaul-manager.sh"

echo -e "${GREEN}[2/3]${NC} Setting permissions..."
chmod +x "$INSTALL_PATH"

echo -e "${GREEN}[3/3]${NC} Installation complete!"
echo ""
echo -e "${CYAN}Run the manager with:${NC}"
echo -e "  ${GREEN}./backhaul-manager.sh${NC}"
echo ""

# Run it
exec "$INSTALL_PATH"

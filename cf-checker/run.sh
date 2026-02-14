#!/bin/bash

# Cloudflare IP Checker Wrapper
# Installs Python dependencies and runs the checker script

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}--- Preparing CF IP Checker ---${NC}"

# 1. Update & Install System Dependencies
if ! command -v python3 &> /dev/null || ! command -v pip3 &> /dev/null; then
    echo -e "${GREEN}Installing Python3 & Pip...${NC}"
    apt-get update -qq
    apt-get install -y python3 python3-pip unzip wget
fi

# 2. Download cf_checker.py (if missing or outdated)
echo -e "${GREEN}Downloading script...${NC}"
wget -q -O cf_checker.py https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/cf-checker/cf_checker.py

if [ ! -f "cf_checker.py" ]; then
    echo -e "${RED}Error: Failed to download cf_checker.py${NC}"
    exit 1
fi

# 3. Install Python Dependencies
echo -e "${GREEN}Installing Python libraries...${NC}"
# Use --break-system-packages on newer Ubuntu/Debian versions if needed, or fallback to standard install
pip3 install requests --quiet --break-system-packages 2>/dev/null || pip3 install requests --quiet || pip install requests --quiet

# 4. Create Sample IP List if missing
if [ ! -f "ip.txt" ]; then
    echo -e "173.245.48.1\n162.159.135.42\n1.1.1.1\n1.0.0.1" > ip.txt
    echo "Created sample ip.txt"
fi

# 5. Run Checker
echo -e "${GREEN}Starting Checker...${NC}"
python3 cf_checker.py ip.txt

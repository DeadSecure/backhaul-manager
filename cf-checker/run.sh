#!/bin/bash

# Cloudflare IP Checker Wrapper
# Installs Python dependencies and runs the checker script

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Preparing CF IP Checker...${NC}"

# 1. Update & Install Python/Pip
if ! command -v python3 &> /dev/null; then
    echo "Installing Python3..."
    apt-get update -qq
    apt-get install -y python3 python3-pip unzip wget
fi

# 2. Install Requests Library
echo "Installing Python requests..."
pip3 install requests --quiet || pip install requests --quiet

# 3. Create Sample IP List if missing
if [ ! -f "ip.txt" ]; then
    echo -e "173.245.48.1\n162.159.135.42\n1.1.1.1\n1.0.0.1" > ip.txt
    echo "Created sample ip.txt"
fi

# 4. Run Checker
echo -e "${GREEN}Starting Checker...${NC}"
python3 cf_checker.py ip.txt

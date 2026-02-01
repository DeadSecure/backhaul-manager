#!/bin/bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Starting Hetzner IPv6 Static Configuration Setup...${NC}"

# 1. Detect Main Interface
DEFAULT_ROUTE_IF=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -z "$DEFAULT_ROUTE_IF" ]; then
    echo -e "${RED}Error: Could not detect the default network interface.${NC}"
    exit 1
fi

echo -e "Detected Main Interface: ${GREEN}$DEFAULT_ROUTE_IF${NC}"

# 2. Get MAC Address (CRITICAL: Must be preserved)
CURRENT_MAC=$(cat /sys/class/net/$DEFAULT_ROUTE_IF/address)

if [ -z "$CURRENT_MAC" ]; then
    echo -e "${RED}Error: Could not detect MAC address for $DEFAULT_ROUTE_IF.${NC}"
    exit 1
fi

echo -e "Detected MAC Address: ${GREEN}$CURRENT_MAC${NC}"

# 3. Get IPv6 Input
echo -e "${YELLOW}Please enter your IPv6 Subnet (e.g., 2a01:4f8:1c1b:1e1d::/64):${NC}"
read -r IPV6_INPUT

if [[ ! "$IPV6_INPUT" =~ .*/64$ ]]; then
    echo -e "${RED}Warning: Input does not end with /64. Assuming you entered the prefix correctly, but double check!${NC}"
fi

# Convert prefix to address ending in ::1
# Remove the /64 if present just for base calculation logic (though we just append ::1/64 usually)
IPV6_PREFIX=$(echo "$IPV6_INPUT" | sed 's/\/.*//')
# Remove trailing :: if present to avoid ::::1
IPV6_CLEAN=$(echo "$IPV6_PREFIX" | sed 's/::$//')
IPV6_ADDRESS="${IPV6_CLEAN}::1/64"

echo -e "Will configure IPv6 Address: ${GREEN}$IPV6_ADDRESS${NC}"
echo -e "Gateway: fe80::1"
echo -e "MAC Address: $CURRENT_MAC"

# 4. Backup Existing Netplan
echo -e "${YELLOW}Backing up existing Netplan configurations...${NC}"
mkdir -p /etc/netplan/backup_$(date +%s)
cp /etc/netplan/*.yaml /etc/netplan/backup_$(date +%s)/ 2>/dev/null || true

# 5. Create New Netplan Config
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml" 
# Note: Cloud-init usually generates this. We might want to overwrite or create a higher priority one like 99-static.yaml
# But user requested "converting" the example which implies modifying the main config. 
# Safe bet for Hetzner cloud-init setup: /etc/netplan/50-cloud-init.yaml is standard.

echo -e "${YELLOW}Writing new configuration to $NETPLAN_FILE...${NC}"

cat > "$NETPLAN_FILE" <<EOF
network:
    version: 2
    ethernets:
        $DEFAULT_ROUTE_IF:
            match:
                macaddress: $CURRENT_MAC
            set-name: $DEFAULT_ROUTE_IF
            dhcp4: true
            dhcp6: false
            addresses:
                - $IPV6_ADDRESS
            routes:
                - to: default
                  via: fe80::1
            nameservers:
                addresses:
                    - 1.1.1.1
                    - 8.8.8.8
                    - 2606:4700:4700::1111
EOF

# 6. Apply Changes
echo -e "${YELLOW}Verifying configuration...${NC}"
netplan generate

echo -e "${YELLOW}Applying configuration... (WARNING: If settings are wrong, you might lose connectivity)${NC}"
read -p "Are you sure you want to apply? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    netplan apply
    echo -e "${GREEN}Configuration applied successfully!${NC}"
    echo -e "Configured IPv6 Address: ${GREEN}$IPV6_ADDRESS${NC}"
    
    echo -e "${YELLOW}Testing IPv6 connectivity... (Press Ctrl+C to stop)${NC}"
    ping6 google.com
else
    echo -e "${RED}Changes NOT applied. File is saved at $NETPLAN_FILE but not active.${NC}"
fi

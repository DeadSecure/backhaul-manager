#!/bin/bash

# ==========================================
# GREtap Tunnel Manager v2.0 (Pro Edition)
# Style: Inspired by ssh-network-manager
# Features: Smart Watchdog, Auto-Repair, Systemd Integration
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging Functions
log() { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Check Root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root"
    exit 1
fi

# Fix for curl | bash (Input Redirection)
# If script is run via pipe, stdin is closed/occupied. We must reopen it from /dev/tty.
if ! [ -t 0 ]; then
    if [ -e /dev/tty ]; then
        log "Detected curl pipe execution. Switching input to /dev/tty..."
        exec < /dev/tty
    else
        error "Cannot find /dev/tty. Please download the script and run it manually."
    fi
fi

# ==========================================
# 1. FIX & REPAIR FUNCTION
# ==========================================
fix_services() {
    echo -e "\n${YELLOW}--- Starting Service Repair (Fix Mode) ---${NC}"
    
    # 1. Reload Systemd
    log "Reloading systemd daemon..."
    systemctl daemon-reload
    
    # 2. Restart/Fix Tunnels
    log "Scanning for GREtap services..."
    SERVICES=$(ls /etc/systemd/system/gretap-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        log "No GREtap services found to fix."
    else
        for svc_path in $SERVICES; do
            svc_name=$(basename "$svc_path" .service)
            # Extract ID from name (gretap-1.service -> 1)
            ID=$(echo "$svc_name" | sed 's/gretap-//')
            
            log "Fixing Tunnel ${ID} ($svc_name)..."
            
            # Restart Main Service
            systemctl restart "$svc_name"
            
            # Restart Watchdog (if exists)
            if [ -f "/etc/systemd/system/gretap-keepalive-${ID}.service" ]; then
                log "  Restarting Watchdog for Tunnel ${ID}..."
                systemctl restart "gretap-keepalive-${ID}"
            fi
        done
        success "All services restarted and refreshed."
    fi
    
    # 3. Clean Zombies (Stuck Interfaces without service)
    # logic: if interface gt4_X exists but service is stopped -> delete it? 
    # For now, let's just log status.
    log "Current Interfaces:"
    ip link show type gretap
    
    success "Repair Complete!"
    read -p "Press Enter to continue..."
}

# ==========================================
# 2. INSTALL TUNNEL FUNCTION
# ==========================================
install_tunnel() {
    echo -e "\n${CYAN}--- Install New GREtap Tunnel ---${NC}"
    
    # Prerequisite Check
    if ! lsmod | grep -q "ip_gre"; then
        log "Loading ip_gre module..."
        modprobe ip_gre
        echo "ip_gre" > /etc/modules-load.d/ip_gre.conf
    fi

    # 1. Gather Info
    read -p "Tunnel ID (e.g. 1): " ID
    ID=${ID:-1}
    
    # Detect Public IP
    local MY_IP=$(hostname -I | awk '{print $1}')
    read -p "Local IP (this server) [${MY_IP}]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$MY_IP}
    
    read -p "Remote IP (peer server): " REMOTE_IP
    if [ -z "$REMOTE_IP" ]; then error "Remote IP required!"; return; fi
    
    # Inner IP Helper
    echo -e "\n${YELLOW}Addressing Plan:${NC}"
    echo "1) Server (Hub) -> 10.10.${ID}.1/30"
    echo "2) Client (Spoke) -> 10.10.${ID}.2/30"
    echo "3) Custom"
    read -p "Select Mode: " MODE
    
    if [ "$MODE" == "1" ]; then
        TUN_IP="10.10.${ID}.1/30"
        REMOTE_TUN_IP="10.10.${ID}.2"
    elif [ "$MODE" == "2" ]; then
        TUN_IP="10.10.${ID}.2/30"
        REMOTE_TUN_IP="10.10.${ID}.1"
    else
        read -p "Enter Tunnel IP CIDR (e.g. 10.10.1.1/30): " TUN_IP
        read -p "Enter Remote Tunnel IP (for Ping check): " REMOTE_TUN_IP
    fi

    IF_NAME="gt4_${ID}"
    
    log "Configuration:"
    log "  Interface: $IF_NAME"
    log "  Local: $LOCAL_IP -> Remote: $REMOTE_IP"
    log "  IP: $TUN_IP"
    log "  Target for Watchdog: $REMOTE_TUN_IP"
    
    read -p "Press Enter to Install..."
    
    # 2. Create Up Script
    SCRIPT_PATH="/usr/local/bin/gretap-up-${ID}.sh"
    log "Creating Script: $SCRIPT_PATH"
    
    cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash
# GREtap Setup Script for Tunnel ${ID}

# Cleanup
ip link set $IF_NAME down 2>/dev/null
ip link del $IF_NAME 2>/dev/null || true

# Header
echo "Setting up $IF_NAME..."

# Create
ip link add dev $IF_NAME type gretap local $LOCAL_IP remote $REMOTE_IP ttl 255
ip link set $IF_NAME mtu 1450
ip link set $IF_NAME up
ip addr add $TUN_IP dev $IF_NAME

echo "$IF_NAME is UP."
EOF
    chmod +x "$SCRIPT_PATH"
    
    # 3. Create Systemd Service
    SERVICE_NAME="gretap-${ID}"
    SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME.service"
    log "Creating Service: $SERVICE_PATH"
    
    cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=GREtap Tunnel ${ID} ($IF_NAME)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_PATH
ExecStop=/sbin/ip link set $IF_NAME down ; /sbin/ip link del $IF_NAME

[Install]
WantedBy=multi-user.target
EOF

    # 4. Create Smart Watchdog
    WD_SCRIPT="/usr/local/bin/gretap-keepalive-${ID}.sh"
    log "Creating Watchdog: $WD_SCRIPT"
    
    cat <<EOF > "$WD_SCRIPT"
#!/bin/bash
TARGET="$REMOTE_TUN_IP"
IFACE="$IF_NAME"
SERVICE="$SERVICE_NAME"
LOGFILE="/var/log/gretap-wd-${ID}.log"

log() {
    echo "[(\$(date)] \$1"
}

while true; do
    FAIL=0
    
    # Check 1: Interface Existence
    if ! ip link show "\$IFACE" > /dev/null 2>&1; then
        log "CRITICAL: Interface \$IFACE missing!"
        FAIL=1
    fi
    
    # Check 2: Ping (Only if interface exists)
    if [ \$FAIL -eq 0 ]; then
        # -c 3: Try 3 packets
        # -W 2: Wait max 2 seconds per packet
        if ! ping -c 3 -W 2 "\$TARGET" > /dev/null 2>&1; then
            log "WARNING: Ping to \$TARGET failed."
            FAIL=1
        fi
    fi
    
    # Action
    if [ \$FAIL -eq 1 ]; then
        log "Repairing tunnel..."
        systemctl restart "\$SERVICE"
        sleep 5
        
        # Post-Repair Check
        if ping -c 1 -W 1 "\$TARGET" > /dev/null 2>&1; then
             log "RECOVERED: Tunnel is back up."
        else
             log "ERROR: Repair attempt failed. Retrying in next cycle."
        fi
    fi
    
    sleep 10
done
EOF
    chmod +x "$WD_SCRIPT"
    
    # 5. Watchdog Service
    WD_SERVICE="gretap-keepalive-${ID}"
    WD_SVC_PATH="/etc/systemd/system/$WD_SERVICE.service"
    
    cat <<EOF > "$WD_SVC_PATH"
[Unit]
Description=Keepalive for GREtap Tunnel ${ID}
After=$SERVICE_NAME.service

[Service]
ExecStart=$WD_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 6. Activation
    log "Enabling Services..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" "$WD_SERVICE"
    
    log "Starting Tunnel..."
    systemctl start "$SERVICE_NAME"
    
    log "Starting Watchdog..."
    systemctl start "$WD_SERVICE"
    
    success "Tunnel ${ID} Installed Successfully!"
    echo -e "  IP: $TUN_IP"
    echo -e "  Testing Ping to $REMOTE_TUN_IP..."
    ping -c 3 -W 1 "$REMOTE_TUN_IP"
    read -p "Press Enter to continue..." < /dev/tty
}

# ==========================================
# 3. UNINSTALL FUNCTION
# ==========================================
uninstall_tunnel() {
    echo -e "\n${RED}--- Uninstall Menu ---${NC}"
    read -p "Enter Tunnel ID to remove: " ID
    
    if [ -z "$ID" ]; then return; fi
    
    SERVICE="gretap-${ID}"
    WD_SERVICE="gretap-keepalive-${ID}"
    
    log "Stopping Services..."
    systemctl stop "$WD_SERVICE" "$SERVICE" 2>/dev/null
    systemctl disable "$WD_SERVICE" "$SERVICE" 2>/dev/null
    
    log "Removing Files..."
    rm -f "/etc/systemd/system/$SERVICE.service"
    rm -f "/etc/systemd/system/$WD_SERVICE.service"
    rm -f "/usr/local/bin/gretap-up-${ID}.sh"
    rm -f "/usr/local/bin/gretap-keepalive-${ID}.sh"
    
    log "Reloading Systemd..."
    systemctl daemon-reload
    
    # Cleanup interface just in case
    ip link del "gt4_${ID}" 2>/dev/null
    
    success "Tunnel ${ID} Removed."
    read -p "Press Enter to continue..." < /dev/tty
}

# ==========================================
# MAIN MENU
# ==========================================
while true; do
    clear
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN}   GREtap Tunnel Manager v2.0       ${NC}"
    echo -e "${GREEN}   (Layer 2 over Layer 3)           ${NC}"
    echo -e "${GREEN}   Inspired by ssh-network-manager  ${NC}"
    echo -e "${GREEN}====================================${NC}"
    echo "1) Install New Tunnel"
    echo "2) Repair / Fix Services (Smart Watchdog)"
    echo "3) Uninstall Tunnel"
    echo "0) Exit"
    echo ""
    read -p "Select Option: " OPTION
    
    case $OPTION in
        1) install_tunnel ;;
        2) fix_services ;;
        3) uninstall_tunnel ;;
        0) exit 0 ;;
        *) echo "Invalid Option" ; sleep 1 ;;
    esac
done

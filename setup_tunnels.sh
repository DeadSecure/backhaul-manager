#!/bin/bash

# ==========================================
# Multi-Protocol Tunnel Manager (Geneve, GRE, VxLAN)
# Features: Systemd Persistence, Watchdog, Auto-Repair
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Log Functions
log() { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Root Check
if [ "$EUID" -ne 0 ]; then
    error "Please run as root"
    exit 1
fi

# Fix for curl piping
if ! [ -t 0 ]; then
    if [ -e /dev/tty ]; then
        exec < /dev/tty
    else
        error "Cannot find /dev/tty. Run manually."
        exit 1
    fi
fi

# ==========================================
# 1. TUNNEL SETUP LOGIC
# ==========================================
install_tunnel() {
    clear
    echo -e "${CYAN}--- Install New Tunnel ---${NC}"
    echo "Select Protocol:"
    echo "1) Geneve (UDP 6081)"
    echo "2) GRE (IP Proto 47)"
    echo "3) VxLAN (UDP 4789)"
    read -p "Choice [1-3]: " PROTO_CHOICE

    case $PROTO_CHOICE in
        1) TYPE="geneve"; PROTO_NAME="Geneve";;
        2) TYPE="gre"; PROTO_NAME="GRE";;
        3) TYPE="vxlan"; PROTO_NAME="VxLAN";;
        *) error "Invalid choice"; return;;
    esac

    # Gather Info
    read -p "Tunnel ID (unique number, e.g. 10): " ID
    ID=${ID:-10}
    
    # Auto-detect IP
    MY_IP=$(hostname -I | awk '{print $1}')
    read -p "Local IP [$MY_IP]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$MY_IP}
    
    read -p "Remote Server IP: " REMOTE_IP
    if [ -z "$REMOTE_IP" ]; then error "Remote IP is required"; return; fi

    echo -e "\n${YELLOW}Addressing Plan:${NC}"
    echo "1) Server side (10.10.${ID}.1/30)"
    echo "2) Client side (10.10.${ID}.2/30)"
    echo "3) Custom CIDR"
    read -p "Select Mode: " MODE

    case $MODE in
        1) TUN_IP="10.10.${ID}.1/30"; REMOTE_TUN_IP="10.10.${ID}.2";;
        2) TUN_IP="10.10.${ID}.2/30"; REMOTE_TUN_IP="10.10.${ID}.1";;
        *) 
            read -p "Tunnel IP CIDR (e.g. 10.10.10.1/30): " TUN_IP
            read -p "Remote Tunnel IP (for ping check): " REMOTE_TUN_IP
            ;;
    esac

    IF_NAME="${TYPE}${ID}"
    SERVICE_NAME="tunnel-${TYPE}-${ID}"
    WD_SERVICE_NAME="tunnel-keepalive-${TYPE}-${ID}"

    # VNI for Geneve/VxLAN
    VNI=""
    if [[ "$TYPE" == "geneve" || "$TYPE" == "vxlan" ]]; then
        read -p "${PROTO_NAME} VNI ID (default 100): " VNI
        VNI=${VNI:-100}
    fi

    # Create Up Script
    UP_SCRIPT="/usr/local/bin/tunnel-up-${TYPE}-${ID}.sh"
    log "Creating Script: $UP_SCRIPT"

    cat <<EOF > "$UP_SCRIPT"
#!/bin/bash
# Tunnel Setup for $PROTO_NAME ID $ID

# Cleanup old interface
ip link set $IF_NAME down 2>/dev/null
ip link del $IF_NAME 2>/dev/null || true

echo "Setting up $IF_NAME ($PROTO_NAME)..."

# Create Interface
case "$TYPE" in
    geneve)
        ip link add dev $IF_NAME type geneve id $VNI remote $REMOTE_IP dstport 6081
        ;;
    gre)
        ip link add dev $IF_NAME type gre local $LOCAL_IP remote $REMOTE_IP ttl 255
        ;;
    vxlan)
        ip link add dev $IF_NAME type vxlan id $VNI local $LOCAL_IP remote $REMOTE_IP dstport 4789
        ;;
esac

# Configure IP
ip link set $IF_NAME mtu 1400
ip link set $IF_NAME up
ip addr add $TUN_IP dev $IF_NAME

echo "$IF_NAME is UP."
EOF
    chmod +x "$UP_SCRIPT"

    # Create Systemd Service
    SVC_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
    log "Creating Service: $SVC_PATH"

    cat <<EOF > "$SVC_PATH"
[Unit]
Description=$PROTO_NAME Tunnel $ID ($IF_NAME)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$UP_SCRIPT
ExecStop=/sbin/ip link set $IF_NAME down ; /sbin/ip link del $IF_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Create Watchdog Script
    WD_SCRIPT="/usr/local/bin/tunnel-keepalive-${TYPE}-${ID}.sh"
    log "Creating Watchdog: $WD_SCRIPT"

    cat <<EOF > "$WD_SCRIPT"
#!/bin/bash
TARGET="$REMOTE_TUN_IP"
IFACE="$IF_NAME"
SERVICE="$SERVICE_NAME"

while true; do
    if ! ip link show "\$IFACE" > /dev/null 2>&1; then
        echo "Interface missing. Restarting service..."
        systemctl restart "\$SERVICE"
    elif ! ping -c 3 -W 2 "\$TARGET" > /dev/null 2>&1; then
        echo "Ping failed. Restarting service..."
        systemctl restart "\$SERVICE"
    fi
    sleep 20
done
EOF
    chmod +x "$WD_SCRIPT"

    # Create Watchdog Service
    WD_SVC_PATH="/etc/systemd/system/${WD_SERVICE_NAME}.service"
    cat <<EOF > "$WD_SVC_PATH"
[Unit]
Description=Keepalive for $PROTO_NAME Tunnel $ID
After=$SERVICE_NAME.service

[Service]
ExecStart=$WD_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Enable & Start
    log "Reloading Systemd..."
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" "${WD_SERVICE_NAME}"
    
    log "Starting Tunnel..."
    systemctl start "${SERVICE_NAME}"
    systemctl start "${WD_SERVICE_NAME}"

    success "$PROTO_NAME Tunnel $ID Installed!"
    echo "Check status with: systemctl status $SERVICE_NAME"
    read -p "Press Enter..."
}

# ==========================================
# 2. UNINSTALL LOGIC
# ==========================================
uninstall_tunnel() {
    echo -e "\n${RED}--- Uninstall Tunnel ---${NC}"
    echo "Select Protocol to Remove:"
    echo "1) Geneve"
    echo "2) GRE"
    echo "3) VxLAN"
    read -p "Choice: " P_Choice

    case $P_Choice in
        1) TYPE="geneve";;
        2) TYPE="gre";;
        3) TYPE="vxlan";;
        *) return;;
    esac

    read -p "Enter Tunnel ID to remove: " ID
    if [ -z "$ID" ]; then return; fi
    
    SERVICE_NAME="tunnel-${TYPE}-${ID}"
    WD_SERVICE_NAME="tunnel-keepalive-${TYPE}-${ID}"
    
    log "Stopping services..."
    systemctl stop "$WD_SERVICE_NAME" "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$WD_SERVICE_NAME" "$SERVICE_NAME" 2>/dev/null
    
    log "Removing files..."
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/${WD_SERVICE_NAME}.service"
    rm -f "/usr/local/bin/tunnel-up-${TYPE}-${ID}.sh"
    rm -f "/usr/local/bin/tunnel-keepalive-${TYPE}-${ID}.sh"
    
    systemctl daemon-reload
    ip link del "${TYPE}${ID}" 2>/dev/null
    
    success "Tunnel Removed."
    read -p "Press Enter..."
}

# ==========================================
# MAIN MENU
# ==========================================
while true; do
    clear
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN}   Advanced Tunnel Manager v1.0     ${NC}"
    echo -e "${GREEN}   (Geneve / GRE / VxLAN)           ${NC}"
    echo -e "${GREEN}====================================${NC}"
    echo "1) Install New Tunnel"
    echo "2) Uninstall Tunnel"
    echo "0) Exit"
    read -p "Select: " OPT
    
    case $OPT in
        1) install_tunnel ;;
        2) uninstall_tunnel ;;
        0) exit 0 ;;
        *) echo "Invalid"; sleep 1 ;;
    esac
done

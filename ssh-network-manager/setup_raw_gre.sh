#!/bin/bash

# ==============================================================================
# RAW GRE Tunnel Setup Script
# Version: 1.0.0
# Description: Automated setup for RAW GRE Tunnel (L3 over IPv4)
# ==============================================================================

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Function to write log messages
log() {
    echo -e "[\e[32m+\e[0m] $1"
}

error() {
    echo -e "[\e[31m!\e[0m] $1"
}

# --- Module Checks ---
log "Loading required Kernel Modules (ip_gre, gre)..."
if ! modprobe ip_gre && modprobe gre; then
    error "Modprobe failed! Attempting to install kernel-modules-extra..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y linux-modules-extra-$(uname -r) || echo "Failed to install linux-modules-extra. Tunnel might not work."
    elif [ -f /etc/redhat-release ]; then
        yum install -y kernel-modules-extra || echo "Failed to install kernel-modules-extra. Tunnel might not work."
    fi
    modprobe ip_gre && modprobe gre || error "Kernel modules still not loading. Proceeding anyway, but anticipate errors."
fi

# --- Collect Inputs ---
echo "=========================================="
echo "    RAW GRE Tunnel Configuration"
echo "=========================================="

read -p "Enter Tunnel ID (e.g., 6): " TUNNEL_ID
if [[ ! "$TUNNEL_ID" =~ ^[0-9]+$ ]]; then
    error "Tunnel ID must be a number."
    exit 1
fi

read -p "Are you configuring the IRAN server or KHAREJ (Outside) server? (Enter 'iran' or 'kharej'): " SERVER_ROLE
SERVER_ROLE=$(echo "$SERVER_ROLE" | tr '[:upper:]' '[:lower:]')

if [[ "$SERVER_ROLE" != "iran" && "$SERVER_ROLE" != "kharej" ]]; then
    error "Invalid role. Must be 'iran' or 'kharej'."
    exit 1
fi

read -p "Enter YOUR Local IP Address (This Server): " LOCAL_IP
read -p "Enter Target REMOTE IP Address (The Other Server): " REMOTE_IP

read -p "Enter Internal IP Prefix (Default: 10.10, press Enter to keep default): " IP_PREFIX
IP_PREFIX=${IP_PREFIX:-10.10}

# --- Determine Internal IPs ---
if [ "$SERVER_ROLE" == "iran" ]; then
    INNER_LOCAL="${IP_PREFIX}.${TUNNEL_ID}.1"
    INNER_REMOTE="${IP_PREFIX}.${TUNNEL_ID}.2"
else
    INNER_LOCAL="${IP_PREFIX}.${TUNNEL_ID}.2"
    INNER_REMOTE="${IP_PREFIX}.${TUNNEL_ID}.1"
fi

IF_NAME="greraw_${TUNNEL_ID}"
UP_SCRIPT="/usr/local/bin/gre-raw-up-${TUNNEL_ID}.sh"
SERVICE_NAME="tunnel-gre-raw-${TUNNEL_ID}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log "Configuring: Interface=$IF_NAME, Local=$INNER_LOCAL/30, RemoteTarget=$INNER_REMOTE"

# --- 1. Create Up Script ---
log "Creating Tunnel UP script at $UP_SCRIPT..."
cat <<EOF > "$UP_SCRIPT"
#!/bin/bash
exec > /var/log/gre-raw-up-${TUNNEL_ID}.log 2>&1
set -x
ip link set ${IF_NAME} down 2>/dev/null
ip link del ${IF_NAME} 2>/dev/null || true
ip tunnel add ${IF_NAME} mode gre local ${LOCAL_IP} remote ${REMOTE_IP} ttl 255
ip link set ${IF_NAME} mtu 1400
ip link set ${IF_NAME} up
ip addr add ${INNER_LOCAL}/30 dev ${IF_NAME}
EOF
chmod +x "$UP_SCRIPT"

# --- 2. Create SystemD Service ---
log "Creating SystemD Service: $SERVICE_FILE..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=RAW GRE Tunnel ${TUNNEL_ID}
After=network.target

[Service]
Type=oneshot
ExecStart=${UP_SCRIPT}
RemainAfterExit=yes
ExecStop=/sbin/ip link set ${IF_NAME} down ; /sbin/ip tunnel del ${IF_NAME}

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd and enabling service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# --- 3. Optional Watchdog (Ping Keepalive) ---
read -p "Do you want to install a Keepalive Watchdog to auto-reconnect if ping fails? (y/n, default: y): " INSTALL_WATCHDOG
INSTALL_WATCHDOG=${INSTALL_WATCHDOG:-y}

if [[ "$INSTALL_WATCHDOG" =~ ^[Yy]$ ]]; then
    KEEPALIVE_SCRIPT="/usr/local/bin/keepalive-gre-raw-${TUNNEL_ID}.sh"
    KEEPALIVE_SVC="keepalive-gre-raw-${TUNNEL_ID}"
    
    log "Creating Keepalive Script at $KEEPALIVE_SCRIPT..."
    cat <<EOF > "$KEEPALIVE_SCRIPT"
#!/bin/bash
TARGET="$INNER_REMOTE"

while true; do
    if ! ping -c 3 -W 1 "\$TARGET" >/dev/null 2>&1; then
        echo "[\$(date)] Ping to \$TARGET failed. Restarting $SERVICE_NAME..."
        systemctl restart "$SERVICE_NAME"
        sleep 5
    fi
    sleep 10
done
EOF
    chmod +x "$KEEPALIVE_SCRIPT"

    cat <<EOF > "/etc/systemd/system/${KEEPALIVE_SVC}.service"
[Unit]
Description=Keepalive Watchdog for RAW GRE Tunnel ${TUNNEL_ID}
After=${SERVICE_NAME}.service network.target

[Service]
ExecStart=${KEEPALIVE_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${KEEPALIVE_SVC}"
    systemctl restart "${KEEPALIVE_SVC}"
    log "Watchdog Installed and Running."
fi

log "================================================="
log "Setup Complete!"
log "Service: systemctl status $SERVICE_NAME"
log "Logs: cat /var/log/gre-raw-up-${TUNNEL_ID}.log"
log "To check interface: ip a show $IF_NAME"
log "To ping remote: ping $INNER_REMOTE"
log "================================================="

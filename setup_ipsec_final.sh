#!/bin/bash

# ==========================================
# SSH Network Manager - IPsec+GRE Setup Script
# Includes Auto-Fix, Duplicate SA Prevention, and Smart Watchdogs
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Check Root
if [ "$EUID" -ne 0 ]; then 
  error "Please run as root"
  exit 1
fi

# ==========================================
# 1. FIX & REPAIR FUNCTION
# ==========================================
fix_services() {
    log "--- Starting Service Repair (Fix Mode) ---"
    
    # 1. Hard Cleanup
    log "Stopping services and killing zombies..."
    systemctl stop strongswan strongswan-starter strongswan-swanctl 2>/dev/null
    pkill -9 charon 2>/dev/null
    pkill -9 starter 2>/dev/null
    
    # 2. Dependencies
    log "Checking dependencies..."
    if ! command -v swanctl &> /dev/null; then
        log "Installing StrongSwan..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strongswan strongswan-pki libstrongswan-extra-plugins strongswan-swanctl charon-systemd coreutils
    fi

    # 3. Ensure Service Exists
    log "Ensuring systemd service..."
    CHARON_PATH=$(command -v charon-systemd || echo "/usr/lib/ipsec/charon-systemd")
    cat <<EOF > /etc/systemd/system/strongswan-swanctl.service
[Unit]
Description=strongSwan IPsec IKEv1/IKEv2 daemon using swanctl
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CHARON_PATH}
ExecStartPost=/bin/sleep 2
ExecStartPost=-/usr/sbin/swanctl --load-all
ExecReload=/usr/sbin/swanctl --reload
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable strongswan-swanctl
    
    # 4. Start Service
    log "Starting StrongSwan..."
    systemctl restart strongswan-swanctl
    sleep 2
    
    # 5. Fix Configs (Crucial Step)
    log "Patching configurations..."
    # Remove deprecated dpd_delay
    sed -i '/dpd_delay/d' /etc/swanctl/conf.d/*.conf 2>/dev/null
    # Ensure start_action = start
    sed -i 's/start_action = trap/start_action = start/g' /etc/swanctl/conf.d/*.conf 2>/dev/null
    # Inject unique = replace (Prevents Duplicate SAs)
    if grep -q 'version = 2' /etc/swanctl/conf.d/*.conf 2>/dev/null; then
        if ! grep -q 'unique = replace' /etc/swanctl/conf.d/*.conf; then
            log "Injecting 'unique = replace' to prevent Duplicate SAs..."
            sed -i '/version = 2/a \ \ \ \ unique = replace' /etc/swanctl/conf.d/*.conf
        fi
    fi

    # 6. Reload Configs
    log "Reloading configs..."
    if ! timeout 5 swanctl --load-all; then
        log "Warning: swanctl load timed out, but service is running."
    fi

    # 7. Upgrade Watchdogs (Add Timeout)
    log "Upgrading Watchdogs to Smart Mode (Timeout Protection)..."
    for script in /usr/local/bin/ipsec-keepalive-*.sh /usr/local/bin/keepalive-ipsec-*.sh /usr/local/bin/keepalive-gre-*.sh; do
        [ -f "$script" ] || continue
        
        # Extract Info
        ID=$(echo "$script" | grep -oE '[0-9]+' | head -1)
        TARGET=$(grep -oP '(?<=ping -c [0-9] -W [0-9] )[0-9.]+' "$script" 2>/dev/null | head -1)
        [ -z "$TARGET" ] && TARGET=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$script" | head -1)
        SVC_NAME=$(basename "$script" .sh)
        
        if [ -n "$ID" ] && [ -n "$TARGET" ]; then
             log "Upgrading $SVC_NAME..."
             cat <<EOF > "$script"
#!/bin/bash
TARGET="$TARGET"
while true; do
  FAIL=0
  
  # 1. Check Ping
  if ! ping -c 6 -W 2 \$TARGET > /dev/null; then
    FAIL=1
  fi
  
  # 2. Check IPsec SA (Prevent Split Brain)
  if [ \$FAIL -eq 0 ]; then
      if ! timeout 5 /usr/sbin/swanctl --list-sas --child tun$ID | grep -q "ESTABLISHED"; then
          echo "\$(date): Ping OK but NO IPsec SA found for tun$ID! Force Recovery..."
          FAIL=1
      fi
  fi

  if [ \$FAIL -eq 1 ]; then
    echo "\$(date): Connection lost. Initiating recovery..."
    
    # 1. Soft retry
    timeout 5 swanctl --initiate --child tun$ID 2>/dev/null
    sleep 3
    
    # 2. Hard retry
    if ! ping -c 2 -W 1 \$TARGET > /dev/null; then
        echo "\$(date): Still down. Terminating stale connections..."
        timeout 5 swanctl --terminate --ike tun$ID 2>/dev/null
        sleep 2
        timeout 5 swanctl --initiate --child tun$ID 2>/dev/null
        
        # 3. restart service
        sleep 5
        if ! ping -c 2 -W 1 \$TARGET > /dev/null; then
             echo "\$(date): Restarting Service..."
             systemctl restart ipsec-gre-$ID 2>/dev/null
        fi
    fi
    sleep 5
  fi
  sleep 10
done
EOF
             chmod +x "$script"
             systemctl restart "$SVC_NAME.service" 2>/dev/null
        fi
    done

    # 8. Install Global Health Monitor
    log "Installing Global Health Monitor..."
    cat <<EOF > /usr/local/bin/ipsec-health-monitor.sh
#!/bin/bash
LOG_FILE="/var/log/ipsec-health-monitor.log"
while true; do
    if ! timeout 5 swanctl --stats > /dev/null 2>&1; then
        echo "\$(date): VICI Socket Unresponsive! Force Restarting..." >> "\$LOG_FILE"
        rm -f /var/run/charon.vici /var/run/charon.pid
        pkill -9 charon
        systemctl kill -s SIGKILL strongswan-swanctl 2>/dev/null
        sleep 1
        systemctl restart strongswan-swanctl
        sleep 10
    fi
    sleep 30
done
EOF
    chmod +x /usr/local/bin/ipsec-health-monitor.sh
    
    cat <<EOF > /etc/systemd/system/ipsec-health-monitor.service
[Unit]
Description=IPSec Health Monitor
After=strongswan-swanctl.service

[Service]
ExecStart=/usr/local/bin/ipsec-health-monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now ipsec-health-monitor

    success "Repair Complete! System should be stable now."
}

# ==========================================
# 2. INSTALL TUNNEL FUNCTION
# ==========================================
install_tunnel() {
    echo -e "\n--- Install New Tunnel ---"
    read -p "Role (IRAN/KHAREJ): " ROLE
    read -p "Tunnel ID (e.g. 1): " ID
    read -p "Local IP: " LOCAL_IP
    read -p "Remote IP: " REMOTE_IP
    read -p "Pre-Shared Key (PSK): " PSK
    read -p "IP Prefix (default 172.20): " PREFIX
    PREFIX=${PREFIX:-172.20}

    # Normalize Role
    ROLE=$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')
    
    # Calculate IPs
    if [ "$ROLE" == "IRAN" ]; then
        GRE_LOCAL="${PREFIX}.${ID}.1"
        GRE_REMOTE="${PREFIX}.${ID}.2"
    else
        GRE_LOCAL="${PREFIX}.${ID}.2"
        GRE_REMOTE="${PREFIX}.${ID}.1"
    fi

    log "Installing Dependencies..."
    if ! command -v swanctl &> /dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strongswan strongswan-pki libstrongswan-extra-plugins strongswan-swanctl charon-systemd coreutils
    fi

    # Config
    log "Generating Config..."
    mkdir -p /etc/swanctl/conf.d
    cat <<EOF > /etc/swanctl/conf.d/tun${ID}.conf
connections {
    tun${ID} {
        local_addrs = ${LOCAL_IP}
        remote_addrs = ${REMOTE_IP}
        version = 2
        unique = replace
        proposals = aes256-sha256-modp2048,aes128-sha1-modp1024
        local {
            auth = psk
            id = ${LOCAL_IP}
        }
        remote {
            auth = psk
            id = ${REMOTE_IP}
        }
        children {
            tun${ID} {
                mode = transport
                esp_proposals = aes256-sha256,aes128-sha1
                start_action = start
                dpd_action = restart
            }
        }
    }
}
secrets {
    ike-tun${ID} {
        id = ${REMOTE_IP}
        secret = "${PSK}"
    }
}
EOF
    
    # GRE Script
    log "Creating GRE Service..."
    cat <<EOF > /usr/local/bin/ipsec-gre-up-${ID}.sh
#!/bin/bash
ip tunnel del gre${ID} 2>/dev/null || true
ip tunnel add gre${ID} mode gre remote ${REMOTE_IP} local ${LOCAL_IP} ttl 255
ip link set gre${ID} up
ip addr add ${GRE_LOCAL}/30 dev gre${ID}
ip link set gre${ID} mtu 1400
EOF
    chmod +x /usr/local/bin/ipsec-gre-up-${ID}.sh

    cat <<EOF > /etc/systemd/system/ipsec-gre-${ID}.service
[Unit]
Description=GRE over IPsec Tunnel ${ID}
After=network.target strongswan-swanctl.service
Wants=strongswan-swanctl.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipsec-gre-up-${ID}.sh
ExecStartPost=-/usr/sbin/swanctl --initiate --child tun${ID}
RemainAfterExit=yes
ExecStop=/sbin/ip tunnel del gre${ID}

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload & Start
    systemctl daemon-reload
    systemctl enable --now ipsec-gre-${ID}
    
    # Apply IPsec
    fix_services # Utilize the fix function to ensure service is healthy and config loaded

    # Setup Keepalive (Using the Fix logic again logic essentially)
    log "Setting up Keepalive..."
    cat <<EOF > /usr/local/bin/ipsec-keepalive-${ID}.sh
#!/bin/bash
TARGET="${GRE_REMOTE}"
while true; do
  FAIL=0
  
  # 1. Check Ping
  if ! ping -c 6 -W 2 \$TARGET > /dev/null; then
    FAIL=1
  fi
  
  # 2. Check IPsec SA (Prevent Traffic Leak)
  if [ \$FAIL -eq 0 ]; then
      if ! timeout 5 /usr/sbin/swanctl --list-sas --child tun${ID} | grep -q "ESTABLISHED"; then
          echo "\$(date): Ping OK but NO IPsec SA found! Security risk!"
          FAIL=1
      fi
  fi

  if [ \$FAIL -eq 1 ]; then
    echo "\$(date): Connection lost (Ping or SA missing). Initiating recovery..."
    
    # 1. Soft retry
    timeout 5 swanctl --initiate --child tun${ID} 2>/dev/null
    sleep 3
    
    # 2. Hard retry (Terminate stale SA)
    if ! ping -c 2 -W 1 \$TARGET > /dev/null; then
        echo "\$(date): Still down. Terminating stale connections..."
        timeout 5 swanctl --terminate --ike tun${ID} 2>/dev/null
        sleep 2
        timeout 5 swanctl --initiate --child tun${ID} 2>/dev/null
        
        # 3. Last resort: Restart service
        sleep 5
        if ! ping -c 2 -W 1 \$TARGET > /dev/null; then
             echo "\$(date): Restarting Service..."
             systemctl restart ipsec-gre-${ID}
        fi
    fi
    sleep 5
  fi
  sleep 10
done
EOF
    chmod +x /usr/local/bin/ipsec-keepalive-${ID}.sh
    
    cat <<EOF > /etc/systemd/system/ipsec-keepalive-${ID}.service
[Unit]
Description=Keepalive for Tunnel ${ID}
After=ipsec-gre-${ID}.service

[Service]
ExecStart=/usr/local/bin/ipsec-keepalive-${ID}.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now ipsec-keepalive-${ID}

    success "Tunnel ${ID} Installed! IP: ${GRE_LOCAL}"
}

# ==========================================
# MAIN MENU
# ==========================================
echo "1) Install New IPsec+GRE Tunnel"
echo "2) Repair/Fix All Services (Duplicate SAs & Hangs)"
echo "3) Uninstall a Tunnel"
read -p "Select option: " OPTION

case $OPTION in
    1) install_tunnel ;;
    2) fix_services ;;
    3) 
       read -p "Tunnel ID to remove: " ID
       systemctl disable --now ipsec-gre-${ID} ipsec-keepalive-${ID}
       rm -f /etc/systemd/system/ipsec-gre-${ID}.service /etc/systemd/system/ipsec-keepalive-${ID}.service
       rm -f /usr/local/bin/ipsec-gre-up-${ID}.sh /usr/local/bin/ipsec-keepalive-${ID}.sh
       rm -f /etc/swanctl/conf.d/tun${ID}.conf
       swanctl --load-all
       ip tunnel del gre${ID}
       success "Removed Tunnel ${ID}"
       ;;
    *) echo "Invalid option" ;;
esac

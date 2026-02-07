#!/bin/bash
# ----------------------------------------------------
#  Full IPSec Repair & Health Monitor Installer
#  By: Ahmad | Date: 2026-02-07
# ----------------------------------------------------

echo "--> [1/7] Stopping Legacy Services..."
systemctl stop strongswan strongswan-starter strongswan-swanctl 2>/dev/null || true
pkill charon || true
pkill starter || true

echo "--> [2/7] Checking Dependencies..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strongswan strongswan-pki libstrongswan-extra-plugins strongswan-swanctl charon-systemd coreutils

echo "--> [3/7] Ensuring Service Integrity..."
# Ensure charon-systemd service exists
if [ ! -f /lib/systemd/system/strongswan-swanctl.service ] && [ ! -f /etc/systemd/system/strongswan-swanctl.service ]; then
    echo "Service file missing! Creating..."
    CHARON_PATH=$(command -v charon-systemd || dpkg -L charon-systemd | grep bin/charon | head -1)
    if [ -z "$CHARON_PATH" ]; then CHARON_PATH="/usr/sbin/charon-systemd"; fi
    
    cat > /etc/systemd/system/strongswan-swanctl.service <<EOF
[Unit]
Description=strongSwan IPsec IKEv2 daemon (charon-systemd)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CHARON_PATH
ExecStartPost=/bin/sleep 2
ExecStartPost=-/usr/sbin/swanctl --load-all
ExecReload=/usr/sbin/swanctl --reload
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi

systemctl enable strongswan-swanctl || true
systemctl restart strongswan-swanctl || true
sleep 2

echo "--> [4/7] Fixing Configurations..."
sed -i '/dpd_delay/d' /etc/swanctl/conf.d/*.conf 2>/dev/null || true
sed -i 's/start_action = trap/start_action = start/g' /etc/swanctl/conf.d/*.conf 2>/dev/null || true

echo "--> [5/7] Reloading Configs..."
swanctl --load-all || true

echo "--> [6/7] Upgrading Existing Watchdogs..."
for script in /usr/local/bin/ipsec-keepalive-*.sh; do
    [ -f "$script" ] || continue
    ID=$(echo "$script" | grep -oE '[0-9]+' | head -1)
    TARGET=$(grep -oP '(?<=ping -c [0-9] -W [0-9] )[0-9.]+' "$script" 2>/dev/null | head -1)
    [ -z "$TARGET" ] && TARGET=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$script" | head -1)
    
    if [ -n "$ID" ] && [ -n "$TARGET" ]; then
        echo "Upgrading watchdog for Tunnel $ID..."
        cat <<EOF > "$script"
#!/bin/bash
TARGET="$TARGET"
while true; do
  FAIL=0
  if ! ping -c 6 -W 2 \$TARGET > /dev/null; then FAIL=1; fi
  if [ \$FAIL -eq 0 ]; then
      if ! /usr/sbin/swanctl --list-sas --child tun$ID | grep -q "ESTABLISHED"; then
          echo "\$(date): Ping OK but NO IPsec SA for tun$ID! Recovery..."
          FAIL=1
      fi
  fi
  if [ \$FAIL -eq 1 ]; then
    echo "\$(date): Connection lost. Recovery..."
    swanctl --initiate --child tun$ID 2>/dev/null
    sleep 3
    if ! ping -c 2 -W 1 \$TARGET > /dev/null; then
        swanctl --terminate --ike tun$ID 2>/dev/null
        sleep 2
        swanctl --initiate --child tun$ID 2>/dev/null
        sleep 5
        if ! ping -c 2 -W 1 \$TARGET > /dev/null; then
             systemctl restart ipsec-gre-$ID 2>/dev/null
        fi
    fi
    sleep 5
  fi
  sleep 10
done
EOF
        chmod +x "$script"
        SYSTEMD_SVC=$(basename "$script" .sh)
        systemctl restart "$SYSTEMD_SVC" 2>/dev/null
    fi
done

echo "--> [7/7] Installing Global Health Monitor..."
cat > /usr/local/bin/ipsec-health-monitor.sh <<'EOF'
#!/bin/bash
LOG_FILE="/var/log/ipsec-health.log"
echo "$(date): Monitor started." >> "$LOG_FILE"
while true; do
    if ! timeout 5 swanctl --stats > /dev/null 2>&1; then
        echo "$(date): VICI Socket Unresponsive! Force Restarting..." >> "$LOG_FILE"
        rm -f /var/run/charon.vici /var/run/charon.pid
        pkill -9 charon
        systemctl kill -s SIGKILL strongswan-swanctl 2>/dev/null
        sleep 2
        systemctl restart strongswan-swanctl
        sleep 10
    fi
    sleep 30
done
EOF
chmod +x /usr/local/bin/ipsec-health-monitor.sh

cat > /etc/systemd/system/ipsec-health-monitor.service <<'EOF'
[Unit]
Description=IPSec Health Monitor (VICI Socket Watchdog)
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
systemctl restart ipsec-health-monitor

echo -e "\n✅ ALL REPAIRS COMPLETED SUCCESSFULLY!"
systemctl status ipsec-health-monitor --no-pager

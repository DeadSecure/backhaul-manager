#!/bin/bash
# ----------------------------------------------------
#  IPSec Fixer & Health Monitor Installer
#  By: Ahmad | Date: 2026-02-07
# ----------------------------------------------------

echo "--> Fixing IPSec Dependencies..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strongswan strongswan-pki libstrongswan-extra-plugins strongswan-swanctl charon-systemd coreutils

echo "--> Setting up IPSec Health Monitor..."

# 1. Create Script
cat > /usr/local/bin/ipsec-health-monitor.sh <<'EOF'
#!/bin/bash
LOG_FILE="/var/log/ipsec-health.log"
echo "$(date): Monitor check starting..." >> "$LOG_FILE"

while true; do
    # Check if swanctl responds within 5 seconds
    if ! timeout 5 swanctl --stats > /dev/null 2>&1; then
        echo "$(date): VICI Socket Unresponsive! Force Restarting..." >> "$LOG_FILE"
        
        # Kill logic
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

# 2. Create Service
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

# 3. Enable & Start
systemctl daemon-reload
systemctl enable --now ipsec-health-monitor
systemctl restart ipsec-health-monitor

echo "--> IPSec Fix & Monitor Installation Completed! ✅"
systemctl status ipsec-health-monitor --no-pager

#!/bin/bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Check root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

install_singbox() {
    echo -e "${YELLOW}Installing sing-box...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) SINGBOX_ARCH="amd64" ;;
        aarch64) SINGBOX_ARCH="arm64" ;;
        *) echo -e "${RED}Unsupported arch: $ARCH${NC}"; exit 1 ;;
    esac

    VERSION="1.8.0"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SINGBOX_ARCH}.tar.gz"

    echo -e "${YELLOW}Downloading sing-box v${VERSION}...${NC}"
    if ! wget -O sing-box.tar.gz "$URL"; then
        echo -e "${RED}Download failed!${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Extracting...${NC}"
    tar -xzf sing-box.tar.gz
    mv sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-*
    echo -e "${GREEN}sing-box installed!${NC}"
}

configure_foreign() {
    echo -e "${GREEN}--- Configuring Foreign Server (Exit Node) ---${NC}"
    read -p "Enter Hysteria 2 Listen Port [443]: " PORT
    PORT=${PORT:-443}
    
    read -p "Enter Password [random]: " PASSWORD
    [ -z "$PASSWORD" ] && PASSWORD=$(openssl rand -hex 16)
    echo -e "Password: ${YELLOW}$PASSWORD${NC}"

    CERT="/root/cert.crt"
    KEY="/root/private.key"
    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
        echo -e "${YELLOW}Certificates missing at $CERT, $KEY${NC}"
        read -p "Generate self-signed now? (y/n): " GEN
        if [[ "$GEN" =~ ^[Yy]$ ]]; then
            openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -sha256 -days 3650 -nodes -subj "/CN=www.google.com"
        else
            echo -e "${RED}Error: Certificates required!${NC}"; exit 1
        fi
    fi

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $PORT,
      "users": [{"password": "$PASSWORD"}],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF
    echo -e "${GREEN}Config saved!${NC}"
}

configure_iran() {
    echo -e "${GREEN}--- Configuring Iran Server (Bridge) ---${NC}"
    read -p "Foreign Server IP: " SERVER_IP
    read -p "Foreign Server Port [443]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-443}
    read -p "Password: " PASSWORD
    read -p "Target IP to Route (e.g. 85.133.224.132): " TARGET_IP
    
    if [ -z "$TARGET_IP" ]; then
        echo -e "${RED}Target IP required!${NC}"; exit 1
    fi

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": false,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "server": "$SERVER_IP",
      "server_port": $SERVER_PORT,
      "password": "$PASSWORD",
      "tls": {
        "enabled": true,
        "insecure": true,
        "alpn": ["h3"]
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_cidr": ["$TARGET_IP/32"],
        "outbound": "hysteria2"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
    echo -e "${GREEN}Config saved!${NC}"
}

create_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    echo -e "${GREEN}Service started!${NC}"
}

echo "1) Foreign Server (Exit)"
echo "2) Iran Server (Bridge)"
read -p "Select: " OPT
case $OPT in
    1) install_singbox; configure_foreign; create_service ;;
    2) install_singbox; configure_iran; create_service ;;
    *) echo "Invalid"; exit 1 ;;
esac

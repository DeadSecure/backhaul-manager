#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════
#  ____             _    _                 _   __  __                                   
# |  _ \           | |  | |               | | |  \/  |                                  
# | |_) | __ _  ___| | _| |__   __ _ _   _| | | \  / | __ _ _ __   __ _  __ _  ___ _ __ 
# |  _ < / _` |/ __| |/ / '_ \ / _` | | | | | | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
# | |_) | (_| | (__|   <| | | | (_| | |_| | | | |  | | (_| | | | | (_| | (_| |  __/ |   
# |____/ \__,_|\___|_|\_\_| |_|\__,_|\__,_|_| |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|   
#                                                                        __/ |          
#                                                                       |___/           
#  Backhaul Tunnel Manager v1.0
#  Author: Ahmad
# ═══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────────
# رنگ‌ها و استایل‌ها
# ─────────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# گرادیانت رنگی
GRADIENT1='\033[38;5;51m'
GRADIENT2='\033[38;5;45m'
GRADIENT3='\033[38;5;39m'
GRADIENT4='\033[38;5;33m'

# ─────────────────────────────────────────────────────────────────────────────────
# متغیرهای پیش‌فرض
# ─────────────────────────────────────────────────────────────────────────────────
DEFAULT_TOKEN="ahmad"
BACKHAUL_BIN="/root/backhaul"
CONFIG_DIR="/root"
SERVICE_DIR="/etc/systemd/system"
BACKHAUL_VERSION="v0.6.5"

# ─────────────────────────────────────────────────────────────────────────────────
# توابع کمکی
# ─────────────────────────────────────────────────────────────────────────────────

clear_screen() {
    clear
}

print_header() {
    clear_screen
    
    # گرفتن IP ها
    local ips=$(get_server_ips)
    local ipv4=$(echo "$ips" | cut -d'|' -f1)
    local ipv6=$(echo "$ips" | cut -d'|' -f2)
    
    echo -e "${GRADIENT1}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo -e "${GRADIENT2}║${NC}  ${BOLD}${WHITE}____             _    _                 _${NC}                        ${GRADIENT2}║${NC}"
    echo -e "${GRADIENT2}║${NC}  ${BOLD}${WHITE}|  _ \\           | |  | |               | |${NC}                       ${GRADIENT2}║${NC}"
    echo -e "${GRADIENT2}║${NC}  ${BOLD}${CYAN}| |_) | __ _  ___| | _| |__   __ _ _   _| |${NC}                       ${GRADIENT2}║${NC}"
    echo -e "${GRADIENT2}║${NC}  ${BOLD}${CYAN}|  _ < / _\` |/ __| |/ / '_ \\ / _\` | | | | |${NC}                       ${GRADIENT2}║${NC}"
    echo -e "${GRADIENT2}║${NC}  ${BOLD}${BLUE}| |_) | (_| | (__|   <| | | | (_| | |_| | |${NC}                       ${GRADIENT2}║${NC}"
    echo -e "${GRADIENT2}║${NC}  ${BOLD}${BLUE}|____/ \\__,_|\\___|_|\\_\\_| |_|\\__,_|\\__,_|_|${NC}                       ${GRADIENT2}║${NC}"
    echo -e "${GRADIENT3}║                                                                   ║${NC}"
    echo -e "${GRADIENT3}║${NC}            ${YELLOW}✦ Tunnel Manager v1.0 ✦${NC}                              ${GRADIENT3}║${NC}"
    echo -e "${GRADIENT4}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # نمایش IP ها
    if [[ -n "$ipv4" ]]; then
        echo -e "   ${WHITE}IPv4:${NC} ${GREEN}${ipv4}${NC}"
    fi
    if [[ -n "$ipv6" ]]; then
        echo -e "   ${WHITE}IPv6:${NC} ${CYAN}${ipv6}${NC}"
    fi
    echo ""
}

print_separator() {
    echo -e "${DIM}───────────────────────────────────────────────────────────────────${NC}"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[i]${NC} $1"
}

# ─────────────────────────────────────────────────────────────────────────────────
# گرفتن IP سرور
# ─────────────────────────────────────────────────────────────────────────────────
get_server_ips() {
    # گرفتن IPv4 عمومی (غیر از localhost)
    local ipv4=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    
    # گرفتن IPv6 عمومی
    local ipv6=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+(?=/)' | head -1)
    
    echo "$ipv4|$ipv6"
}

# ─────────────────────────────────────────────────────────────────────────────────
# تشخیص معماری سیستم
# ─────────────────────────────────────────────────────────────────────────────────
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────────
# بررسی و دانلود باینری Backhaul
# ─────────────────────────────────────────────────────────────────────────────────
check_and_download_backhaul() {
    if [[ -f "$BACKHAUL_BIN" ]]; then
        print_success "Backhaul binary found at $BACKHAUL_BIN"
        return 0
    fi

    print_warning "Backhaul binary not found. Downloading..."
    
    local arch=$(detect_arch)
    if [[ "$arch" == "unknown" ]]; then
        print_error "Unsupported architecture: $(uname -m)"
        return 1
    fi

    local filename="backhaul_linux_${arch}.tar.gz"
    local tar_file="/tmp/${filename}"
    local github_url="https://github.com/Musixal/Backhaul/releases/download/${BACKHAUL_VERSION}/${filename}"
    
    # لیست میررها برای سرورهای ایران
    local mirrors=(
        "https://gh-proxy.com/${github_url}"
        "https://ghproxy.net/${github_url}"
        "https://mirror.ghproxy.com/${github_url}"
        "${github_url}"
    )
    
    local download_success=false
    
    for mirror in "${mirrors[@]}"; do
        echo -e "${CYAN}   Trying: ${mirror}${NC}"
        
        if wget -q --show-progress --timeout=30 -O "$tar_file" "$mirror" 2>/dev/null; then
            # بررسی اینکه فایل واقعا دانلود شده
            if [[ -f "$tar_file" ]] && [[ $(stat -c%s "$tar_file" 2>/dev/null || stat -f%z "$tar_file" 2>/dev/null) -gt 1000 ]]; then
                download_success=true
                print_success "Download complete from mirror!"
                break
            fi
        fi
        
        print_warning "Mirror failed, trying next..."
        rm -f "$tar_file" 2>/dev/null
    done
    
    if [[ "$download_success" == false ]]; then
        print_error "All download mirrors failed!"
        echo ""
        echo -e "${YELLOW}   Manual download instructions:${NC}"
        echo -e "   1. Download from: ${github_url}"
        echo -e "   2. Upload to server: scp ${filename} root@SERVER:/tmp/"
        echo -e "   3. Extract: cd /root && tar -xzf /tmp/${filename}"
        return 1
    fi
    
    echo -e "${CYAN}   Extracting...${NC}"
    cd /root
    if tar -xzf "$tar_file"; then
        chmod +x "$BACKHAUL_BIN"
        rm -f "$tar_file"
        print_success "Backhaul installed successfully at $BACKHAUL_BIN"
        return 0
    else
        print_error "Failed to extract tar file"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────────
# پیدا کردن شماره بعدی برای تونل جدید
# ─────────────────────────────────────────────────────────────────────────────────
get_next_tunnel_number() {
    local max_num=0
    
    # بررسی فایل‌های سرویس موجود
    for service_file in ${SERVICE_DIR}/back*.service; do
        if [[ -f "$service_file" ]]; then
            local filename=$(basename "$service_file" .service)
            local num="${filename#back}"
            
            # اگر فقط "back" بود، یعنی شماره 1
            if [[ -z "$num" ]]; then
                num=1
            fi
            
            if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -gt $max_num ]]; then
                max_num=$num
            fi
        fi
    done
    
    echo $((max_num + 1))
}

# ─────────────────────────────────────────────────────────────────────────────────
# لیست تونل‌های موجود
# ─────────────────────────────────────────────────────────────────────────────────
list_tunnels() {
    print_header
    echo -e "${BOLD}${PURPLE}   ╭─────────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${PURPLE}   │         📋 Tunnel List                      │${NC}"
    echo -e "${BOLD}${PURPLE}   ╰─────────────────────────────────────────────╯${NC}"
    echo ""

    local found=false
    
    for service_file in ${SERVICE_DIR}/back*.service; do
        if [[ -f "$service_file" ]]; then
            found=true
            local service_name=$(basename "$service_file" .service)
            local config_path=$(grep "ExecStart" "$service_file" | sed 's/.*-c //' | tr -d ' ')
            
            # وضعیت سرویس
            local status=$(systemctl is-active "$service_name" 2>/dev/null)
            local status_color=""
            local status_icon=""
            
            case $status in
                active)
                    status_color="${GREEN}"
                    status_icon="●"
                    ;;
                inactive)
                    status_color="${RED}"
                    status_icon="○"
                    ;;
                *)
                    status_color="${YELLOW}"
                    status_icon="◐"
                    ;;
            esac
            
            echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
            echo -e "${CYAN}│${NC} ${BOLD}${WHITE}Service:${NC} ${YELLOW}${service_name}${NC}  ${status_color}${status_icon} ${status}${NC}"
            echo -e "${CYAN}│${NC} ${DIM}Config:${NC} ${config_path}"
            
            # خواندن اطلاعات از فایل کانفیگ
            if [[ -f "$config_path" ]]; then
                local tunnel_type=""
                local bind_addr=""
                local remote_addr=""
                local transport=""
                local token=""
                local ports=""
                
                if grep -q "^\[server\]" "$config_path"; then
                    tunnel_type="SERVER"
                    bind_addr=$(grep "bind_addr" "$config_path" | head -1 | cut -d'"' -f2)
                    echo -e "${CYAN}│${NC} ${BOLD}Type:${NC} ${GREEN}$tunnel_type${NC}"
                    echo -e "${CYAN}│${NC} ${BOLD}Bind Address:${NC} $bind_addr"
                elif grep -q "^\[client\]" "$config_path"; then
                    tunnel_type="CLIENT"
                    remote_addr=$(grep "remote_addr" "$config_path" | head -1 | cut -d'"' -f2)
                    echo -e "${CYAN}│${NC} ${BOLD}Type:${NC} ${BLUE}$tunnel_type${NC}"
                    echo -e "${CYAN}│${NC} ${BOLD}Remote Address:${NC} $remote_addr"
                fi
                
                transport=$(grep "transport" "$config_path" | head -1 | cut -d'"' -f2)
                token=$(grep "token" "$config_path" | head -1 | cut -d'"' -f2)
                
                echo -e "${CYAN}│${NC} ${BOLD}Transport:${NC} $transport"
                echo -e "${CYAN}│${NC} ${BOLD}Token:${NC} ${DIM}$token${NC}"
                
                # نمایش پورت‌ها فقط برای سرور
                if [[ "$tunnel_type" == "SERVER" ]]; then
                    ports=$(grep -A 100 "ports = \[" "$config_path" | grep -E '"[0-9]+=[0-9]+"' | tr -d '", ' | head -5)
                    if [[ -n "$ports" ]]; then
                        echo -e "${CYAN}│${NC} ${BOLD}Forwarded Ports:${NC} ${PURPLE}$ports${NC}"
                    fi
                fi
            fi
            
            echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
            echo ""
        fi
    done
    
    if [[ "$found" == false ]]; then
        echo -e "${YELLOW}   No tunnels found. Create one from the main menu!${NC}"
    fi
    
    echo ""
    read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")" 
}

# ─────────────────────────────────────────────────────────────────────────────────
# ایجاد تونل جدید - سرور
# ─────────────────────────────────────────────────────────────────────────────────
create_server_tunnel() {
    print_header
    echo -e "${BOLD}${GREEN}   ╭─────────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${GREEN}   │         🖥️  Create Server Tunnel             │${NC}"
    echo -e "${BOLD}${GREEN}   ╰─────────────────────────────────────────────╯${NC}"
    echo ""

    # بررسی و دانلود باینری
    check_and_download_backhaul
    if [[ $? -ne 0 ]]; then
        read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
        return 1
    fi

    local tunnel_num=$(get_next_tunnel_number)
    local service_name="back${tunnel_num}"
    local config_file="${CONFIG_DIR}/c${tunnel_num}.toml"
    
    echo -e "${CYAN}   New tunnel will be: ${YELLOW}${service_name}${NC}"
    echo ""
    print_separator

    # دریافت اطلاعات از کاربر
    echo ""
    read -p "$(echo -e "${WHITE}   Tunnel Bind Port ${DIM}(default: 3080)${NC}: ")" bind_port
    bind_port=${bind_port:-3080}
    
    read -p "$(echo -e "${WHITE}   User Data Port ${DIM}(forwarded port, e.g., 2001)${NC}: ")" data_port
    data_port=${data_port:-2001}

    read -p "$(echo -e "${WHITE}   Token ${DIM}(default: ${DEFAULT_TOKEN})${NC}: ")" token
    token=${token:-$DEFAULT_TOKEN}

    read -p "$(echo -e "${WHITE}   Web Dashboard Port ${DIM}(default: 2060, 0 to disable)${NC}: ")" web_port
    web_port=${web_port:-2060}

    echo ""
    print_separator
    echo ""

    # ایجاد فایل کانفیگ
    cat > "$config_file" << EOF
[server]
bind_addr = "0.0.0.0:${bind_port}"
transport = "tcp"
accept_udp = false 
token = "${token}"
keepalive_period = 75  
nodelay = true 
heartbeat = 20 
channel_size = 2048
sniffer = false 
web_port = ${web_port}
sniffer_log = "/root/backhaul.json"
log_level = "info"
ports = [
"${data_port}=${data_port}",
]
EOF

    print_success "Config file created: $config_file"

    # ایجاد فایل سرویس
    cat > "${SERVICE_DIR}/${service_name}.service" << EOF
[Unit]
Description=Backhaul Reverse Tunnel Service - ${service_name}
After=network.target

[Service]
Type=simple
ExecStart=${BACKHAUL_BIN} -c ${config_file}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    print_success "Service file created: ${SERVICE_DIR}/${service_name}.service"

    # ریلود و فعال‌سازی سرویس
    systemctl daemon-reload
    systemctl enable "${service_name}" 2>/dev/null
    systemctl start "${service_name}"

    local status=$(systemctl is-active "${service_name}")
    if [[ "$status" == "active" ]]; then
        print_success "Service ${service_name} is now ${GREEN}RUNNING${NC}"
    else
        print_error "Service failed to start. Check logs with: journalctl -u ${service_name} -f"
    fi

    echo ""
    echo -e "${CYAN}   ┌─────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}   │${NC} ${BOLD}Summary:${NC}"
    echo -e "${CYAN}   │${NC}   Service: ${YELLOW}${service_name}${NC}"
    echo -e "${CYAN}   │${NC}   Bind:    ${WHITE}0.0.0.0:${bind_port}${NC}"
    echo -e "${CYAN}   │${NC}   Data Port: ${WHITE}${data_port}${NC}"
    echo -e "${CYAN}   │${NC}   Token:   ${DIM}${token}${NC}"
    echo -e "${CYAN}   └─────────────────────────────────────────┘${NC}"
    echo ""

    read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
}

# ─────────────────────────────────────────────────────────────────────────────────
# ایجاد تونل جدید - کلاینت
# ─────────────────────────────────────────────────────────────────────────────────
create_client_tunnel() {
    print_header
    echo -e "${BOLD}${BLUE}   ╭─────────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${BLUE}   │         🌐 Create Client Tunnel              │${NC}"
    echo -e "${BOLD}${BLUE}   ╰─────────────────────────────────────────────╯${NC}"
    echo ""

    # بررسی و دانلود باینری
    check_and_download_backhaul
    if [[ $? -ne 0 ]]; then
        read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
        return 1
    fi

    local tunnel_num=$(get_next_tunnel_number)
    local service_name="back${tunnel_num}"
    local config_file="${CONFIG_DIR}/c${tunnel_num}.toml"
    
    echo -e "${CYAN}   New tunnel will be: ${YELLOW}${service_name}${NC}"
    echo ""
    print_separator

    # دریافت اطلاعات از کاربر
    echo ""
    read -p "$(echo -e "${WHITE}   Iran Server IP ${DIM}(required)${NC}: ")" server_ip
    if [[ -z "$server_ip" ]]; then
        print_error "Server IP is required!"
        read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
        return 1
    fi

    read -p "$(echo -e "${WHITE}   Iran Server Port ${DIM}(default: 3080)${NC}: ")" server_port
    server_port=${server_port:-3080}

    read -p "$(echo -e "${WHITE}   Token ${DIM}(default: ${DEFAULT_TOKEN})${NC}: ")" token
    token=${token:-$DEFAULT_TOKEN}

    read -p "$(echo -e "${WHITE}   Connection Pool Size ${DIM}(default: 256)${NC}: ")" pool_size
    pool_size=${pool_size:-256}

    read -p "$(echo -e "${WHITE}   Web Dashboard Port ${DIM}(default: 2060, 0 to disable)${NC}: ")" web_port
    web_port=${web_port:-2060}

    echo ""
    print_separator
    echo ""

    # ایجاد فایل کانفیگ
    cat > "$config_file" << EOF
[client]
remote_addr = "${server_ip}:${server_port}"
transport = "tcp"
token = "${token}" 
connection_pool = ${pool_size}
aggressive_pool = true
keepalive_period = 75
dial_timeout = 10
nodelay = true 
retry_interval = 3
sniffer = false
web_port = ${web_port} 
sniffer_log = "/root/backhaul.json"
log_level = "info"
EOF

    print_success "Config file created: $config_file"

    # ایجاد فایل سرویس
    cat > "${SERVICE_DIR}/${service_name}.service" << EOF
[Unit]
Description=Backhaul Reverse Tunnel Service - ${service_name}
After=network.target

[Service]
Type=simple
ExecStart=${BACKHAUL_BIN} -c ${config_file}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    print_success "Service file created: ${SERVICE_DIR}/${service_name}.service"

    # ریلود و فعال‌سازی سرویس
    systemctl daemon-reload
    systemctl enable "${service_name}" 2>/dev/null
    systemctl start "${service_name}"

    local status=$(systemctl is-active "${service_name}")
    if [[ "$status" == "active" ]]; then
        print_success "Service ${service_name} is now ${GREEN}RUNNING${NC}"
    else
        print_error "Service failed to start. Check logs with: journalctl -u ${service_name} -f"
    fi

    echo ""
    echo -e "${CYAN}   ┌─────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}   │${NC} ${BOLD}Summary:${NC}"
    echo -e "${CYAN}   │${NC}   Service:  ${YELLOW}${service_name}${NC}"
    echo -e "${CYAN}   │${NC}   Remote:   ${WHITE}${server_ip}:${server_port}${NC}"
    echo -e "${CYAN}   │${NC}   Token:    ${DIM}${token}${NC}"
    echo -e "${CYAN}   │${NC}   Pool:     ${WHITE}${pool_size}${NC}"
    echo -e "${CYAN}   └─────────────────────────────────────────┘${NC}"
    echo ""

    read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
}

# ─────────────────────────────────────────────────────────────────────────────────
# مدیریت تونل‌ها
# ─────────────────────────────────────────────────────────────────────────────────
manage_tunnels() {
    while true; do
        print_header
        echo -e "${BOLD}${YELLOW}   ╭─────────────────────────────────────────────╮${NC}"
        echo -e "${BOLD}${YELLOW}   │         ⚙️  Tunnel Management                │${NC}"
        echo -e "${BOLD}${YELLOW}   ╰─────────────────────────────────────────────╯${NC}"
        echo ""

        # لیست تونل‌ها
        local tunnels=()
        local i=1
        
        for service_file in ${SERVICE_DIR}/back*.service; do
            if [[ -f "$service_file" ]]; then
                local service_name=$(basename "$service_file" .service)
                local status=$(systemctl is-active "$service_name" 2>/dev/null)
                local status_color=""
                
                case $status in
                    active)
                        status_color="${GREEN}●${NC}"
                        ;;
                    inactive)
                        status_color="${RED}○${NC}"
                        ;;
                    *)
                        status_color="${YELLOW}◐${NC}"
                        ;;
                esac
                
                tunnels+=("$service_name")
                echo -e "   ${CYAN}[$i]${NC} $status_color ${WHITE}${service_name}${NC} ${DIM}($status)${NC}"
                ((i++))
            fi
        done
        
        if [[ ${#tunnels[@]} -eq 0 ]]; then
            echo -e "${YELLOW}   No tunnels found.${NC}"
            echo ""
            read -p "$(echo -e "${DIM}Press Enter to go back...${NC}")"
            return
        fi
        
        echo ""
        echo -e "   ${DIM}[0]${NC} ${WHITE}Back to Main Menu${NC}"
        echo ""
        print_separator
        echo ""
        
        read -p "$(echo -e "${WHITE}   Select tunnel number: ${NC}")" tunnel_num
        
        # برگشت به منو
        if [[ "$tunnel_num" == "0" ]] || [[ "${tunnel_num,,}" == "b" ]] || [[ -z "$tunnel_num" ]]; then
            return
        fi
        
        # بررسی معتبر بودن شماره
        if ! [[ "$tunnel_num" =~ ^[0-9]+$ ]] || [[ $tunnel_num -lt 1 ]] || [[ $tunnel_num -gt ${#tunnels[@]} ]]; then
            print_error "Invalid tunnel number"
            sleep 1
            continue
        fi
        
        local selected_tunnel="${tunnels[$((tunnel_num-1))]}"
        
        # نمایش منوی اکشن برای تونل انتخاب شده
        while true; do
            print_header
            echo -e "${BOLD}${CYAN}   ╭─────────────────────────────────────────────╮${NC}"
            echo -e "${BOLD}${CYAN}   │   Managing: ${WHITE}${selected_tunnel}${NC}"
            echo -e "${BOLD}${CYAN}   ╰─────────────────────────────────────────────╯${NC}"
            echo ""
            
            # نمایش وضعیت فعلی
            local current_status=$(systemctl is-active "$selected_tunnel" 2>/dev/null)
            case $current_status in
                active)
                    echo -e "   Status: ${GREEN}● Running${NC}"
                    ;;
                inactive)
                    echo -e "   Status: ${RED}○ Stopped${NC}"
                    ;;
                *)
                    echo -e "   Status: ${YELLOW}◐ $current_status${NC}"
                    ;;
            esac
            
            echo ""
            print_separator
            echo ""
            echo -e "   ${GREEN}[1]${NC} Start"
            echo -e "   ${RED}[2]${NC} Stop"
            echo -e "   ${YELLOW}[3]${NC} Restart"
            echo -e "   ${CYAN}[4]${NC} View Logs"
            echo -e "   ${PURPLE}[5]${NC} Delete Tunnel"
            echo ""
            echo -e "   ${DIM}[0]${NC} Back"
            echo ""
            
            read -p "$(echo -e "${WHITE}   Select action: ${NC}")" action
            
            case $action in
                1|s|S|start)
                    systemctl start "$selected_tunnel"
                    print_success "Started $selected_tunnel"
                    sleep 1
                    ;;
                2|t|T|stop)
                    systemctl stop "$selected_tunnel"
                    print_success "Stopped $selected_tunnel"
                    sleep 1
                    ;;
                3|r|R|restart)
                    systemctl restart "$selected_tunnel"
                    print_success "Restarted $selected_tunnel"
                    sleep 1
                    ;;
                4|l|L|logs)
                    echo ""
                    echo -e "${CYAN}   Last 30 lines of logs:${NC}"
                    echo ""
                    journalctl -u "$selected_tunnel" -n 30 --no-pager
                    echo ""
                    read -p "$(echo -e "${WHITE}   Show live logs? [y/N]: ${NC}")" show_live
                    if [[ "${show_live,,}" == "y" ]]; then
                        echo -e "${YELLOW}   Press Ctrl+C to exit live logs${NC}"
                        sleep 1
                        journalctl -u "$selected_tunnel" -f
                    fi
                    ;;
                5|d|D|delete)
                    echo ""
                    read -p "$(echo -e "${RED}   Are you sure you want to delete ${selected_tunnel}? [y/N]: ${NC}")" confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        systemctl stop "$selected_tunnel" 2>/dev/null
                        systemctl disable "$selected_tunnel" 2>/dev/null
                        
                        # پیدا کردن و حذف فایل کانفیگ
                        local config_path=$(grep "ExecStart" "${SERVICE_DIR}/${selected_tunnel}.service" | sed 's/.*-c //' | tr -d ' ')
                        
                        rm -f "${SERVICE_DIR}/${selected_tunnel}.service"
                        rm -f "$config_path"
                        
                        systemctl daemon-reload
                        
                        print_success "Deleted $selected_tunnel"
                        sleep 1
                        break  # برگشت به لیست تونل‌ها
                    fi
                    ;;
                0|b|B|back|"")
                    break
                    ;;
                *)
                    print_error "Invalid option"
                    sleep 1
                    ;;
            esac
        done
    done
}

# ─────────────────────────────────────────────────────────────────────────────────
# حذف کامل Backhaul
# ─────────────────────────────────────────────────────────────────────────────────
uninstall_backhaul() {
    print_header
    echo -e "${BOLD}${RED}   ╭─────────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${RED}   │         🗑️  Uninstall Backhaul               │${NC}"
    echo -e "${BOLD}${RED}   ╰─────────────────────────────────────────────╯${NC}"
    echo ""
    
    echo -e "${YELLOW}   This will:${NC}"
    echo -e "   ${RED}•${NC} Stop all Backhaul services"
    echo -e "   ${RED}•${NC} Remove all service files"
    echo -e "   ${RED}•${NC} Remove all config files"
    echo -e "   ${RED}•${NC} Remove Backhaul binary"
    echo ""
    
    read -p "$(echo -e "${RED}   Are you absolutely sure? Type 'YES' to confirm: ${NC}")" confirm
    
    if [[ "$confirm" == "YES" ]]; then
        echo ""
        # توقف و حذف تمام سرویس‌ها
        for service_file in ${SERVICE_DIR}/back*.service; do
            if [[ -f "$service_file" ]]; then
                local service_name=$(basename "$service_file" .service)
                print_info "Stopping $service_name..."
                systemctl stop "$service_name" 2>/dev/null
                systemctl disable "$service_name" 2>/dev/null
                rm -f "$service_file"
                print_success "Removed $service_name"
            fi
        done
        
        # حذف فایل‌های کانفیگ
        rm -f ${CONFIG_DIR}/c*.toml
        print_success "Removed config files"
        
        # حذف باینری
        rm -f "$BACKHAUL_BIN"
        print_success "Removed Backhaul binary"
        
        # حذف لاگ
        rm -f /root/backhaul.json
        
        systemctl daemon-reload
        
        echo ""
        print_success "Backhaul completely uninstalled!"
    else
        print_warning "Uninstall cancelled"
    fi
    
    echo ""
    read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
}

# ─────────────────────────────────────────────────────────────────────────────────
# نمایش وضعیت کلی
# ─────────────────────────────────────────────────────────────────────────────────
show_status() {
    print_header
    echo -e "${BOLD}${CYAN}   ╭─────────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${CYAN}   │         📊 System Status                    │${NC}"
    echo -e "${BOLD}${CYAN}   ╰─────────────────────────────────────────────╯${NC}"
    echo ""

    # اطلاعات سیستم
    local arch=$(detect_arch)
    local backhaul_status="${RED}Not Installed${NC}"
    
    if [[ -f "$BACKHAUL_BIN" ]]; then
        backhaul_status="${GREEN}Installed${NC}"
    fi
    
    echo -e "   ${BOLD}System Info:${NC}"
    echo -e "   ├── Architecture: ${CYAN}$arch${NC}"
    echo -e "   ├── Backhaul:     $backhaul_status"
    echo -e "   └── Version:      ${CYAN}$BACKHAUL_VERSION${NC}"
    echo ""
    
    # تعداد تونل‌ها
    local total=0
    local active=0
    
    for service_file in ${SERVICE_DIR}/back*.service; do
        if [[ -f "$service_file" ]]; then
            ((total++))
            local service_name=$(basename "$service_file" .service)
            if [[ "$(systemctl is-active "$service_name" 2>/dev/null)" == "active" ]]; then
                ((active++))
            fi
        fi
    done
    
    echo -e "   ${BOLD}Tunnels:${NC}"
    echo -e "   ├── Total:  ${WHITE}$total${NC}"
    echo -e "   └── Active: ${GREEN}$active${NC}"
    echo ""
    
    read -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
}

# ─────────────────────────────────────────────────────────────────────────────────
# منوی اصلی
# ─────────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        print_header
        
        echo -e "   ${WHITE}Select an option:${NC}"
        echo ""
        echo -e "   ${GRADIENT1}[1]${NC} ${WHITE}Create Server Tunnel${NC}     ${DIM}(Iran Server)${NC}"
        echo -e "   ${GRADIENT2}[2]${NC} ${WHITE}Create Client Tunnel${NC}     ${DIM}(Kharej Server)${NC}"
        echo -e "   ${GRADIENT3}[3]${NC} ${WHITE}Tunnel Management${NC}        ${DIM}(List/Start/Stop/Delete)${NC}"
        echo -e "   ${GRADIENT4}[4]${NC} ${WHITE}View All Tunnels${NC}         ${DIM}(Detailed Info)${NC}"
        echo ""
        print_separator
        echo ""
        echo -e "   ${CYAN}[5]${NC} ${WHITE}System Status${NC}"
        echo -e "   ${RED}[6]${NC} ${WHITE}Uninstall Backhaul${NC}"
        echo -e "   ${DIM}[0]${NC} ${WHITE}Exit${NC}"
        echo ""
        
        read -p "$(echo -e "${BOLD}${WHITE}   Enter your choice: ${NC}")" choice
        
        case $choice in
            1)
                create_server_tunnel
                ;;
            2)
                create_client_tunnel
                ;;
            3)
                manage_tunnels
                ;;
            4)
                list_tunnels
                ;;
            5)
                show_status
                ;;
            6)
                uninstall_backhaul
                ;;
            0)
                clear_screen
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────────
# بررسی دسترسی root
# ─────────────────────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────────
# اجرای اصلی
# ─────────────────────────────────────────────────────────────────────────────────
check_root
main_menu

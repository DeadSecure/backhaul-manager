#!/bin/bash

# Cloudflare IP Checker Wrapper
# Installs Python dependencies and runs the checker script

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}--- Preparing CF IP Checker ---${NC}"

# 1. Update & Install System Dependencies
if ! command -v python3 &> /dev/null || ! command -v pip3 &> /dev/null; then
    echo -e "${GREEN}Installing Python3 & Pip...${NC}"
    apt-get update -qq
    apt-get install -y python3 python3-pip unzip wget
fi

# 2. Extract cf_checker.py (Embedded)
echo -e "${GREEN}Extracting script...${NC}"
cat <<EOF > cf_checker.py
import json
import subprocess
import time
import os
import sys
import requests
import random
import string
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- Configuration ---
XRAY_URL = "https://github.com/XTLS/Xray-core/releases/download/v1.8.4/Xray-linux-64.zip"
XRAY_BIN = "./xray"
RESULT_FILE = "valid_ips.txt"
TIMEOUT = 5  # Seconds
THREADS = 5  # Number of concurrent checks

# Colors
RED = '\033[91m'
GREEN = '\033[92m'
YELLOW = '\033[93m'
CYAN = '\033[96m'
RESET = '\033[0m'

def install_xray():
    if not os.path.exists(XRAY_BIN):
        print(f"{YELLOW}--- Downloading Xray Core ---{RESET}")
        try:
            subprocess.run(["wget", "-q", "-O", "xray.zip", XRAY_URL], check=True)
            subprocess.run(["unzip", "-q", "-o", "xray.zip"], check=True)
            subprocess.run(["chmod", "+x", "xray"], check=True)
            print(f"{GREEN}Xray installed successfully.{RESET}")
            if os.path.exists("xray.zip"): os.remove("xray.zip")
        except Exception as e:
            print(f"{RED}Error downloading Xray: {e}{RESET}")
            sys.exit(1)

def get_random_port():
    return random.randint(10000, 50000)

def generate_config(ip, port):
    config = {
        "log": {"loglevel": "none"},
        "inbounds": [{
            "port": port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
        }],
        "outbounds": [{
            "tag": "proxy",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": ip,
                    "port": 443,
                    "users": [{"id": "5b639bcc-36ae-4800-b763-720e489aa049", "flow": "", "encryption": "none"}]
                }]
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "tls",
                "tlsSettings": {"serverName": "a1.cloudworkpass.com", "alpn": ["h2", "http/1.1"], "fingerprint": "chrome", "allowInsecure": False},
                "xhttpSettings": {"path": "/", "host": "", "mode": "auto", "noGRPCHeader": False, "scMinPostsIntervalMs": "30", "xmux": {"maxConcurrency": "16-32", "maxConnections": 0, "cMaxReuseTimes": 0, "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000", "hKeepAlivePeriod": 0}}
            }
        }, {"protocol": "freedom", "tag": "direct"}]
    }
    return config

def check_ip(ip):
    local_port = get_random_port()
    config_filename = f"config_{ip}_{local_port}.json"
    
    # Write Config
    config = generate_config(ip, local_port)
    with open(config_filename, 'w') as f:
        json.dump(config, f)
    
    # Start Xray Process
    try:
        process = subprocess.Popen([XRAY_BIN, "-c", config_filename], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1) # bind
        
        proxies = {'http': f'socks5://127.0.0.1:{local_port}', 'https': f'socks5://127.0.0.1:{local_port}'}
        
        start_time = time.time()
        response = requests.get("https://cp.cloudflare.com", proxies=proxies, timeout=TIMEOUT)
        latency = int((time.time() - start_time) * 1000)
        
        if response.status_code == 204 or response.status_code == 200:
            print(f"{GREEN}[SUCCESS] {ip} \tLatency: {latency}ms{RESET}")
            return (ip, latency)
        else:
            print(f"{RED}[FAIL]    {ip} \tStatus: {response.status_code}{RESET}")
            return None

    except Exception:
        # print(f"{RED}[FAIL]    {ip}{RESET}") # Minimal error logging
        return None
    finally:
        if process: process.terminate(); process.wait()
        if os.path.exists(config_filename): os.remove(config_filename)

def main():
    print(f"{CYAN}=== Cloudflare Clean IP Checker (VLESS/xHTTP) ==={RESET}")
    install_xray()
    
    ips = []
    
    # Check if run with file arg
    if len(sys.argv) > 1:
        if os.path.isfile(sys.argv[1]):
            with open(sys.argv[1], 'r') as f: ips = [l.strip() for l in f if l.strip()]
        else:
            ips = [sys.argv[1]]
    else:
        # Interactive Mode
        print(f"\n{YELLOW}Choose Input Method:{RESET}")
        if os.path.exists("ip.txt"):
            use_file = input(f"File 'ip.txt' found. Use it? [Y/n]: ").strip().lower()
            if use_file in ['', 'y', 'yes']:
                with open("ip.txt", 'r') as f: ips = [l.strip() for l in f if l.strip()]
        
        if not ips:
            print(f"Enter IPs manually (one per line). Type 'run' or press Enter on empty line to start:")
            while True:
                try:
                    line = input("> ").strip()
                    if not line or line.lower() == 'run': break
                    ips.append(line)
                except EOFError: break

    if not ips:
        print(f"{RED}No IPs provided. Exiting.{RESET}")
        return

    print(f"\n{CYAN}Checking {len(ips)} IPs with {THREADS} threads...{RESET}")
    valid_results = []
    with ThreadPoolExecutor(max_workers=THREADS) as executor:
        future_to_ip = {executor.submit(check_ip, ip): ip for ip in ips}
        for future in as_completed(future_to_ip):
            res = future.result()
            if res: valid_results.append(res)

    if valid_results:
        print(f"\n{GREEN}Found {len(valid_results)} valid IPs!{RESET}")
        valid_results.sort(key=lambda x: x[1])
        with open(RESULT_FILE, 'w') as f:
            for ip, lat in valid_results: f.write(f"{ip},{lat}\n")
        print(f"Saved to {RESULT_FILE}")
    else:
        print(f"\n{RED}No valid IPs found.{RESET}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
EOF

# 3. Install Python Dependencies
echo -e "${GREEN}Installing Python libraries (requests, pysocks)...${NC}"
# Use --break-system-packages on newer Ubuntu/Debian versions if needed
pip3 install requests PySocks --quiet --break-system-packages 2>/dev/null || pip3 install requests PySocks --quiet || pip install requests PySocks --quiet

# 4. Run Checker
echo -e "${GREEN}Starting Checker...${NC}"

# Check for TTY
if [ -t 0 ]; then
    python3 cf_checker.py
else
    # If piped via curl, force TTY for input
    python3 cf_checker.py < /dev/tty
fi

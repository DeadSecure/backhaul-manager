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
RESET = '\033[0m'

def install_xray():
    if not os.path.exists(XRAY_BIN):
        print(f"{YELLOW}--- Downloading Xray Core ---{RESET}")
        try:
            subprocess.run(["wget", "-q", "-O", "xray.zip", XRAY_URL], check=True)
            subprocess.run(["unzip", "-q", "-o", "xray.zip"], check=True)
            subprocess.run(["chmod", "+x", "xray"], check=True)
            print(f"{GREEN}Xray installed successfully.{RESET}")
            # Cleanup
            if os.path.exists("xray.zip"): os.remove("xray.zip")
        except Exception as e:
            print(f"{RED}Error downloading Xray: {e}{RESET}")
            sys.exit(1)

def get_random_port():
    return random.randint(10000, 50000)

def generate_config(ip, port):
    """
    Generates a full Xray config based on the user's VLESS snippet.
    The 'address' field in vnext is replaced with the IP to test.
    """
    config = {
        "log": {
            "loglevel": "none"
        },
        "inbounds": [
            {
                "port": port,
                "protocol": "socks",
                "settings": {
                    "auth": "noauth",
                    "udp": True
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"]
                }
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": ip,  # The IP we are testing
                            "port": 443,
                            "users": [
                                {
                                    "id": "5b639bcc-36ae-4800-b763-720e489aa049",
                                    "flow": "",
                                    "encryption": "none"
                                }
                            ]
                        }
                    ]
                },
                "streamSettings": {
                    "network": "xhttp",
                    "security": "tls",
                    "tlsSettings": {
                        "serverName": "a1.cloudworkpass.com",
                        "alpn": ["h2", "http/1.1"],
                        "fingerprint": "chrome",
                        "allowInsecure": False
                    },
                    "xhttpSettings": {
                        "path": "/",
                        "host": "",
                        "mode": "auto",
                        "noGRPCHeader": False,
                        "scMinPostsIntervalMs": "30",
                        "xmux": {
                            "maxConcurrency": "16-32",
                            "maxConnections": 0,
                            "cMaxReuseTimes": 0,
                            "hMaxRequestTimes": "600-900",
                            "hMaxReusableSecs": "1800-3000",
                            "hKeepAlivePeriod": 0
                        }
                    }
                }
            },
            {
                "protocol": "freedom",
                "tag": "direct"
            }
        ]
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
        process = subprocess.Popen(
            [XRAY_BIN, "-c", config_filename],
            stdout=subprocess.DEVNULL, 
            stderr=subprocess.DEVNULL
        )
        time.sleep(1) # Give it a moment to bind
        
        # Test Connection using requests with SOCKS proxy
        proxies = {
            'http': f'socks5://127.0.0.1:{local_port}',
            'https': f'socks5://127.0.0.1:{local_port}'
        }
        
        start_time = time.time()
        # We test connecting to Cloudflare trace or Google
        response = requests.get("https://cp.cloudflare.com", proxies=proxies, timeout=TIMEOUT)
        latency = int((time.time() - start_time) * 1000)
        
        if response.status_code == 204 or response.status_code == 200:
            print(f"{GREEN}[SUCCESS] {ip} \tLatency: {latency}ms{RESET}")
            return (ip, latency)
        else:
            print(f"{RED}[FAIL]    {ip} \tStatus: {response.status_code}{RESET}")
            return None

    except requests.exceptions.Timeout:
        print(f"{RED}[TIMEOUT] {ip}{RESET}")
        return None
    except requests.exceptions.RequestException as e:
        print(f"{RED}[ERROR]   {ip} \t{e}{RESET}")
        return None
    except Exception as e:
        print(f"{RED}[ERR]     {ip} \t{e}{RESET}")
        return None
    finally:
        # Cleanup
        if process:
            process.terminate()
            process.wait()
        if os.path.exists(config_filename):
            os.remove(config_filename)

def main():
    print(f"{CYAN}=== Cloudflare Clean IP Checker (VLESS/xHTTP) ==={RESET}")
    install_xray()
    
    ips = []
    
    # Input handling
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if os.path.isfile(arg):
            with open(arg, 'r') as f:
                ips = [line.strip() for line in f if line.strip()]
        else:
            ips = [arg]
    else:
        print(f"{YELLOW}Usage: python3 cf_checker.py <ip_list.txt> OR <single_ip>{RESET}")
        # Default test IPs if no arg provided
        print("Testing with sample IPs...")
        ips = ["173.245.49.82", "162.159.135.42", "1.1.1.1"]

    print(f"Checking {len(ips)} IPs with {THREADS} threads...")
    
    valid_results = []
    
    with ThreadPoolExecutor(max_workers=THREADS) as executor:
        future_to_ip = {executor.submit(check_ip, ip): ip for ip in ips}
        for future in as_completed(future_to_ip):
            result = future.result()
            if result:
                valid_results.append(result)

    # Save Results
    if valid_results:
        print(f"\n{GREEN}Found {len(valid_results)} valid IPs!{RESET}")
        # Sort by latency
        valid_results.sort(key=lambda x: x[1])
        with open(RESULT_FILE, 'w') as f:
            for ip, lat in valid_results:
                f.write(f"{ip},{lat}\n")
        print(f"Saved to {RESULT_FILE}")
    else:
        print(f"\n{RED}No valid IPs found.{RESET}")

if __name__ == "__main__":
    main()

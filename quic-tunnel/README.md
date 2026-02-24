# PQT QUIC Tunnel Manager

Bash script for installing and managing **PQT QUIC tunnels** with multi-tunnel support.

## Features
- QUIC transport with Brutal CC
- XOR Obfuscation over Fake-TCP
- FakeTLS with Reality support
- DPI Evasion (decoy packets, length morphing, OS mimicry)
- Anti-throttle (aggressive CC, padding, FEC)
- **Multiple simultaneous tunnels**
- Systemd service management
- Auto-reconnect Watchdog
- Port forwarding management

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Alireza2030/quic-tunnel/main/setup_pqt.sh)
```

## Usage
```bash
# Download and run
curl -fsSL https://raw.githubusercontent.com/Alireza2030/quic-tunnel/main/setup_pqt.sh -o setup_pqt.sh
chmod +x setup_pqt.sh
sudo ./setup_pqt.sh
```

## Menu Options
| # | Option | Description |
|---|--------|-------------|
| 1 | Install PQT | Download and install PQT binary |
| 2 | Setup Server | Configure server side (Kharej) |
| 3 | Setup Client | Configure client side (Iran) with port forwarding |
| 4 | Add Ports | Add ports to existing tunnel |
| 5 | List Tunnels | Show all tunnels and status |
| 6 | Check Connection | Test tunnel connectivity |
| 7 | View Logs | Show service logs |
| 8 | View Config | Display config files |
| 9 | Restart Service | Restart tunnel services |
| 10 | Watchdog | Enable auto-reconnect |
| 11 | Uninstall Service | Remove specific service |
| 12 | Full Uninstall | Remove everything |

## License
MIT

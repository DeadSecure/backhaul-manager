# 🚀 Backhaul Tunnel Manager

<div align="center">

![Bash](https://img.shields.io/badge/Bash-5.0+-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)

**A beautiful, interactive Bash script for managing Backhaul reverse tunnels on Linux servers**

[Installation](#-quick-install) • [Features](#-features) • [Usage](#-usage) • [Screenshots](#-screenshots)

</div>

---

## ⚡ Quick Install

### One-liner (Recommended)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/install.sh)
```

### Manual Download
```bash
wget -O backhaul-manager.sh https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/backhaul-manager.sh
chmod +x backhaul-manager.sh
./backhaul-manager.sh
```

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🎨 **Beautiful UI** | Colorful interactive menu with ASCII art |
| 📥 **Auto Download** | Automatically downloads Backhaul binary (amd64/arm64) |
| 🖥️ **Server Mode** | Create server tunnels (Iran) with port forwarding |
| 🌐 **Client Mode** | Create client tunnels (Kharej) with connection pooling |
| ⚙️ **Management** | Start, Stop, Restart, View Logs, Delete tunnels |
| 📋 **Status View** | Detailed view of all tunnels with their configuration |
| 🗑️ **Uninstall** | Complete removal of Backhaul and all configurations |

---

## 🔧 Usage

### Main Menu
```
╔═══════════════════════════════════════════════════════════════════╗
║  ____             _    _                 _                        ║
║ | __ )  __ _  ___| | _| |__   __ _ _   _| |                       ║
║ |  _ \ / _` |/ __| |/ / '_ \ / _` | | | | |                       ║
║ | |_) | (_| | (__|   <| | | | (_| | |_| | |                       ║
║ |____/ \__,_|\___|_|\_\_| |_|\__,_|\__,_|_|                       ║
║                                                                   ║
║            ✦ Tunnel Manager v1.0 ✦                                ║
╚═══════════════════════════════════════════════════════════════════╝

   [1] Create Server Tunnel     (Iran Server)
   [2] Create Client Tunnel     (Kharej Server)
   [3] Tunnel Management        (List/Start/Stop/Delete)
   [4] View All Tunnels         (Detailed Info)
   [5] System Status
   [6] Uninstall Backhaul
   [0] Exit
```

### Creating a Server Tunnel (Iran)
1. Select option `[1]`
2. Enter the tunnel bind port (default: 3080)
3. Enter the data forwarding port (e.g., 2001)
4. Enter token (default: ahmad)
5. Enter web dashboard port (default: 2060)

### Creating a Client Tunnel (Kharej)
1. Select option `[2]`
2. Enter Iran server IP
3. Enter Iran server port (default: 3080)
4. Enter token (must match server)
5. Enter connection pool size (default: 256)

---

## 📁 File Structure

| Type | Path |
|------|------|
| Binary | `/root/backhaul` |
| Configs | `/root/c1.toml`, `/root/c2.toml`, ... |
| Services | `/etc/systemd/system/back1.service`, ... |

---

## 🛠️ Requirements

- Linux (Debian/Ubuntu/CentOS/etc.)
- Root access
- `wget` or `curl`
- `systemd`

---

## 📝 License

MIT License - Feel free to use and modify!

---

## 🙏 Credits

- [Musixal/Backhaul](https://github.com/Musixal/Backhaul) - The amazing tunneling tool
- Created with ❤️ by Ahmad

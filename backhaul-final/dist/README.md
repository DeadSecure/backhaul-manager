# 📦 Backhaul - Ready to Deploy

## محتویات این پوشه:

### باینری‌ها:
- **backhaul** (14MB) - برای سرورهای AMD64/x86_64
- **backhaul-arm64** (13MB) - برای سرورهای ARM64 (Oracle Cloud)

### اسکریپت:
- **backhaul-manager.sh** - نصب و مدیریت خودکار

### مستندات:
- **QUICK-START.md** - راهنمای سریع نصب

---

## 🚀 نصب سریع (2 دقیقه)

### سرور AMD64 (Intel/AMD):
```bash
chmod +x backhaul backhaul-manager.sh
sudo ./backhaul-manager.sh
```

### سرور ARM64:
```bash
mv backhaul-arm64 backhaul
chmod +x backhaul backhaul-manager.sh
sudo ./backhaul-manager.sh
```

---

## ⚙️ تنظیمات مهم 3x-ui

**بعد از نصب، این تنظیم را در پنل 3x-ui اضافه کنید:**

```json
"streamSettings": {
  "network": "tcp",
  "tcpSettings": {
    "acceptProxyProtocol": true
  }
}
```

سپس 3x-ui را restart کنید:
```bash
systemctl restart x-ui
```

---

## ✅ تست

لاگ 3x-ui را بررسی کنید:
```bash
tail -f /var/log/3x-ui/access.log
```

باید IP واقعی کاربران را ببینید، **نه 127.0.0.1**

---

## 📋 ویژگی‌ها

✅ TCP Tunnel با Heartbeat  
✅ Proxy Protocol v2 (ارسال IP واقعی)  
✅ IP Limit (محدودیت IP همزمان)  
✅ Connection Pool خودکار  
✅ اسکریپت مدیریت کامل  

---

**نسخه:** Backhaul 7.2  
**تاریخ:** 2026-01-07

# 🚀 راهنمای سریع Backhaul

## نصب و راه‌اندازی (2 دقیقه)

### سرور ایران:
```bash
# 1. آپلود فایل‌ها
scp backhaul backhaul-manager.sh root@IRAN_IP:/root/

# 2. اجرای اسکریپت
ssh root@IRAN_IP
chmod +x backhaul-manager.sh
./backhaul-manager.sh

# 3. انتخاب گزینه 1 (Iran Server)
# 4. وارد کردن پورت‌ها و token
```

### سرور خارج:
```bash
# 1. آپلود فایل‌ها
scp backhaul backhaul-manager.sh root@FOREIGN_IP:/root/

# 2. اجرای اسکریپت
ssh root@FOREIGN_IP
chmod +x backhaul-manager.sh
./backhaul-manager.sh

# 3. انتخاب گزینه 2 (Foreign Client)
# 4. وارد کردن IP سرور ایران و token
# 5. فعال کردن IP Limit (y)
```

### تنظیم 3x-ui (مهم!)

در پنل 3x-ui، inbound خود را ویرایش کنید:

```json
{
  "port": 3031,
  "protocol": "vless",
  "settings": { ... },
  "streamSettings": {
    "network": "tcp",
    "tcpSettings": {
      "acceptProxyProtocol": true    // ← این خط را اضافه کنید
    }
  }
}
```

## تست

```bash
# بررسی وضعیت
systemctl status backhaul

# لاگ زنده
journalctl -u backhaul -f

# لاگ 3x-ui
tail -f /var/log/3x-ui/access.log
```

اگر همه چیز درست کار کند، باید IP واقعی کاربر را در لاگ ببینید! 🎉

## مدیریت

اسکریپت را دوباره اجرا کنید برای:
- نمایش وضعیت
- ری‌استارت سرویس
- مشاهده لاگ
- تغییر کانفیگ

```bash
./backhaul-manager.sh
```

## عیب‌یابی

**IP واقعی نمایش داده نمی‌شود؟**
1. بررسی کنید `acceptProxyProtocol: true` در 3x-ui تنظیم شده باشد
2. بررسی کنید `ip_limit = true` در `foreign-client.toml` باشد
3. سرویس 3x-ui را restart کنید

**اتصال برقرار نمی‌شود؟**
1. فایروال: `ufw allow 2096/tcp`
2. بررسی token یکسان باشد
3. لاگ را چک کنید: `journalctl -u backhaul -n 50`

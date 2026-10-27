# leak-guard

سخت‌کردن کلاینت فیلترشکن روی لینوکس با sing-box: بستن نشت DNS، نشت WebRTC و نشت IPv6، کلید قطع واقعی، و روتینگ مستقیم سایت‌های ایرانی.
English version: [below](#english)

آموزش ویدیویی (فارسی): کانال یوتیوب [@V7lthronyx](https://www.youtube.com/@V7lthronyx)، اینترنت آزاد فصل ۲: [قسمت ۵ — فیلترشکنت روشنه ولی هنوز لو میری](https://youtu.be/GYdDWCBaBqY).

## چرا تونل سالم کافی نیست

پراکسی فقط بسته‌هایی رو جابه‌جا می‌کنه که بهش داده میشن. وقتی فیلترشکن روشنه و آی‌پی خروجیت خارجیه، هنوز این‌ها می‌تونن از کنار تونل برن:

| نشت | چی میشه |
|---|---|
| DNS | جست‌وجوی اسم سایت‌ها مستقیم میره سمت DNS اپراتور. اپراتور می‌بینه چه سایت‌هایی باز می‌کنی و برای سایت‌های فیلترشده جواب مسموم (`10.10.34.x`، صفحه‌ی مسدودی) برمی‌گردونه |
| WebRTC | وقتی فقط پراکسی مرورگر روشنه، بسته‌ی STUN مرورگر (UDP) از کنار تونل میره و آی‌پی واقعیت رو لو میده |
| IPv6 | اگه شبکه‌ات IPv6 داره و تونل فقط IPv4 رو می‌بره، ترافیک v6 مستقیم میره |
| قطع شدن تونل | اگه کلاینت کرش کنه یا بسته بشه، برنامه‌ها بی‌صدا از خط مستقیم ادامه میدن |

## چی کار می‌کنه

سه اسکریپت جدا، هر کدوم یه کار:

- `harden.sh` از لینک سرورت یه کانفیگ sing-box می‌سازه:
  - کارت شبکه‌ی مجازی (TUN) با `auto_route` و `strict_route` و `auto_redirect`: همه‌ی بسته‌ها، حتی UDP و STUN مرورگر، وارد تونل میشن.
  - همه‌ی جست‌وجوهای DNS گرفته میشن (`hijack-dns`) و از داخل تونل با DoH جواب داده میشن، پس اپراتور نه می‌بینه و نه می‌تونه مسمومشون کنه.
  - IPv6 به‌طور پیش‌فرض بسته‌ست (`ipv4_only` + رد کردن بسته‌های v6).
  - سایت‌های ایرانی (لیست `geoip-ir` و `geosite-ir` از [Chocolate4U/Iran-sing-box-rules](https://github.com/Chocolate4U/Iran-sing-box-rules)) و شبکه‌ی محلی مستقیم میرن، پس بانک و سایت‌هایی که آی‌پی خارجی رو می‌بندن بدون خاموش کردن فیلترشکن کار می‌کنن. لیست‌ها بار اول از داخل تونل دانلود میشن، هر هفته به‌روز میشن و کنار کانفیگ کش میشن.
  - کانفیگ رو با `sing-box check` چک می‌کنه. خودش چیزی رو اجرا نمی‌کنه و چیزی از سیستم رو عوض نمی‌کنه.
- `killswitch.sh` یه جدول nftables اضافه می‌کنه که از این دستگاه فقط اجازه‌ی خروج به تونل، خود sing-box، DHCP و شبکه‌ی محلی رو میده (DNS به شبکه‌ی محلی هم بسته‌ست). اگه sing-box کرش کنه، هیچ بسته‌ای بیرون نمیره.
- `leaktest.sh` کلاینتِ در حال اجرا رو چک می‌کنه و برای هر مورد `PASS` یا `FAIL` میده: آی‌پی خروجی، مسموم نبودن DNS، نبودِ خروجی IPv6.

چرا کلید قطع جداست: `strict_route` و `auto_redirect` بعد از کرش sing-box فقط جلوی TCP رو می‌گیرن. توی تست لابراتوار، بعد از `kill -9` بسته‌های UDP (مثل STUN و QUIC) و ICMP هنوز از کارت شبکه بیرون می‌رفتن. با `killswitch.sh` هیچ بسته‌ای بیرون نرفت.

## پیش‌نیاز

- لینوکس با systemd (تست‌شده روی Ubuntu 24.04 و Debian 12)
- [sing-box](https://sing-box.sagernet.org/installation/package-manager/) نسخه‌ی 1.12 یا جدیدتر (تست‌شده با 1.14.3)، و `jq` و `curl`
- برای کلید قطع: `nftables` (اگه دستور `nft` رو نداری: `sudo apt install nftables`)
- برای تست DNS: `dig` (بسته‌ی `bind9-dnsutils`) یا خود سیستم (`getent`)
- یه سرور کارکرده از قسمت‌های قبل (یا هر سرور VLESS یا Hysteria2)

sing-box باید با root اجرا بشه (`sudo`): TUN و مسیرها و شناسایی پروسه‌ها بدون root کار نمی‌کنن.

## دانلود

```bash
mkdir leak-guard && cd leak-guard
for f in harden.sh killswitch.sh leaktest.sh SHA256SUMS; do
  curl -fsSLO "https://github.com/v74all/leak-guard/releases/latest/download/$f"
done
sha256sum -c SHA256SUMS
```

اسکریپت رو با `curl | bash` اجرا نکن. دانلود کن، هشش رو چک کن، یه نگاه بهش بنداز، بعد اجرا کن.

## استفاده

```bash
bash harden.sh --link 'vless://...'           # یا hysteria2://...
sudo bash killswitch.sh on                     # پیشنهادی
sudo sing-box run -c sb-hardened.json
```

خروجی `harden.sh`:

```
harden.sh: wrote ./sb-hardened.json
harden.sh: sing-box check OK
```

بعد توی یه ترمینال دیگه تست کن (آی‌پی سرورت رو بذار):

```bash
EXPECT_IP=1.2.3.4 bash leaktest.sh
```

```
== Exit IP (who the internet thinks you are) ==
  [ PASS ] exit IP = 1.2.3.4 (matches server)

== DNS not poisoned (lookups travel inside the tunnel) ==
  [ PASS ] youtube.com -> 142.250.x.x (not the block page)

== IPv6 egress (v6 reaching sites outside the tunnel) ==
  [ PASS ] no IPv6 egress (v6 is carried in-tunnel or disabled)

== Result: 3 passed, 0 failed ==
```

تست DNS به‌طور پیش‌فرض `youtube.com` رو جست‌وجو می‌کنه. اگه جواب یه آدرس خصوصی باشه (مثل `10.10.34.36`، صفحه‌ی مسدودی)، یعنی جست‌وجو به DNS اپراتور رسیده. با `CANARY` و `POISON` می‌تونی اسم و آدرس دیگه‌ای بدی (`bash leaktest.sh --help`).

تست کلید قطع دستیه: وقتی همه‌چی کار می‌کنه، `sudo pkill -9 sing-box` بزن و یه سایت رو باز کن. باید باز نشه. بعد sing-box رو دوباره اجرا کن.

برای WebRTC، با sing-box روشن یه صفحه‌ی تست نشت WebRTC رو توی مرورگر باز کن: فقط آی‌پی سرورت باید دیده بشه.

## کدوم سرور، کدوم دستور

| سرور | دستور |
|---|---|
| قسمت ۱ (`xhttp-reality`) با ترنسپورت `vision` | `bash harden.sh --link 'vless://...'` |
| قسمت ۱ و ۲ با XHTTP (پیش‌فرض، و حالت CDN) | sing-box ترنسپورت XHTTP نداره. کلاینت Xray خودت رو با پورت SOCKS روی `127.0.0.1:10808` اجرا کن و بعد: `bash harden.sh --socks 127.0.0.1:10808 --server دامنه‌ی-سرورت` |
| قسمت ۳ (`hysteria2-hop`) | `bash harden.sh --link 'hysteria2://...'` (پورت‌هاپینگ `mport` و `obfs=salamander` پشتیبانی میشن) |
| قسمت ۴ (`amneziawg-hop`) | خودش تونل کل دستگاهه و به این اسکریپت نیاز نداره؛ با `leaktest.sh` چکش کن |
| هر چیز دیگه | خروجی sing-box رو توی یه فایل JSON بذار: `bash harden.sh --outbound outbound.json` |

حالت `--socks`: ترافیک خود Xray (پیش‌فرض اسم پروسه `xray`؛ با `--process` عوضش کن) از کنار تونل میره تا به سرور برسه و بقیه‌ی ترافیک از Xray رد میشه. اگه آدرس سرور توی کانفیگ Xray یه دامنه‌ست، اون رو با `--server` بده تا اسمش بیرون از تونل جست‌وجو بشه. خود Xray نباید حالت TUN داشته باشه.

لینک Hysteria2 با `pinSHA256`: این گزینه مخصوص کلاینت خود Hysteria‌ـه و sing-box نمی‌تونه ازش استفاده کنه، پس گواهی سرور پین نمیشه و اسکریپت هشدار میده. اگه روی سرور گواهی واقعی بذاری (`--cert` توی `hysteria2-hop`) این مشکل نیست.

## گزینه‌ها

| گزینه | کار |
|---|---|
| `-o FILE` | مسیر کانفیگ خروجی (پیش‌فرض `./sb-hardened.json`) |
| `--doh URL` | سرور DoH که از داخل تونل استفاده میشه (پیش‌فرض `https://1.1.1.1/dns-query`) |
| `--direct-dns X` | DNS سایت‌های ایرانی و اسم سرورت: `auto`، `local`، `dhcp` یا یه آی‌پی. `auto` پشت `systemd-resolved` از `dhcp` استفاده می‌کنه، وگرنه `local` |
| `--ipv6 on` | IPv6 رو هم از تونل ببره (سرورت باید IPv6 داشته باشه) |
| `--no-ir-direct` | سایت‌های ایرانی هم از تونل برن |
| `--rules DIR` | فایل‌های `geoip-ir.srs` و `geosite-ir.srs` رو از این پوشه بخونه، به‌جای دانلود |
| `--no-auto-redirect` | بدون `auto_redirect` (اون‌وقت کرش sing-box همه‌چی رو نشت میده؛ از `killswitch.sh` استفاده کن) |
| `--no-check` | `sing-box check` رو اجرا نکنه |

`killswitch.sh`:

```bash
sudo bash killswitch.sh on        # فقط تونل، sing-box، DHCP و شبکه‌ی محلی
sudo bash killswitch.sh on --no-lan
sudo bash killswitch.sh status
sudo bash killswitch.sh off       # اینترنت معمولی
```

تا وقتی کلید قطع روشنه و sing-box خاموشه، این دستگاه اینترنت نداره. کار کلید قطع همینه. بعد از ریستارت سیستم خاموش میشه (فقط تا ریبوت می‌مونه).

## چه چیزهایی عوض میشه

- `harden.sh` فقط فایل کانفیگ رو می‌نویسه.
- `sing-box run` موقع اجرا مسیرها، `ip rule`ها و جدول nftables `inet sing-box` رو می‌سازه و موقع بستن پاکشون می‌کنه. لیست‌های ایران توی `leak-guard-cache.db` کنار کانفیگ ذخیره میشن.
- `killswitch.sh on` جدول nftables `inet leak_guard` رو اضافه می‌کنه و `off` پاکش می‌کنه.

## مشکلات رایج

- **`lookup ...: context deadline exceeded`**: اسم سرورت جواب نگرفت. اگه از `systemd-resolved` استفاده می‌کنی و `--direct-dns` رو دستی `local` گذاشتی، `auto` یا `dhcp` بذار؛ اگه شبکه‌ات DHCP نداره، آی‌پی روتر رو بده: `--direct-dns 192.168.1.1`.
- **`initialize rule-set` موقع اجرای اول**: لیست‌های ایران از داخل تونل دانلود نشدن، یعنی خود سرور وصل نشده. لینک رو چک کن. توی حالت `--socks` اگه کلید قطع از قبل روشن باشه، اجرای اول نمی‌تونه لیست‌ها رو بگیره: یه بار بدون کلید قطع اجرا کن (بعد از اون از کش خونده میشن) یا فایل‌ها رو با `--rules` بده.
- **بعد از روشن کردن کلید قطع هیچ‌چی باز نمیشه**: sing-box باید با `sudo` اجرا شده باشه و کانفیگ از `harden.sh` اومده باشه (اسم تونل `tun0` و علامت `0x2024`).
- **کانتینرهای Docker و ماشین‌های مجازی**: این کانفیگ و کلید قطع ترافیک خود این دستگاه رو پوشش میدن، نه ترافیکی که از کانتینرها رد میشه.

## مجوز

MIT. فایل [LICENSE](LICENSE).

---

## English

Harden a Linux proxy client with sing-box so a working tunnel stops leaking: DNS, WebRTC and IPv6 leaks closed, a real kill switch, and Iranian sites routed direct.

Video (Persian): [@V7lthronyx](https://www.youtube.com/@V7lthronyx), Free Internet season 2, [episode 5](https://youtu.be/GYdDWCBaBqY).

- `harden.sh` builds a sing-box config around your server: TUN with `auto_route` + `strict_route` + `auto_redirect`, all DNS hijacked and answered over DoH through the proxy, IPv6 dropped by default, Iranian sites ([Chocolate4U rule-sets](https://github.com/Chocolate4U/Iran-sing-box-rules), downloaded through the tunnel and cached) and private ranges direct. It writes and checks the config; it never starts anything.
- `killswitch.sh` adds an nftables table (`inet leak_guard`) that lets this machine send only into the tunnel, sing-box's own connections (mark `0x2024`), DHCP and the LAN, with no DNS around the tunnel. In a lab test, after `kill -9 sing-box` UDP (STUN, QUIC) and ICMP still left the machine with `strict_route` + `auto_redirect` alone; with the kill switch nothing did.
- `leaktest.sh` checks a running client: exit IP, DNS poisoning (a filtered name must not come back as a private block-page address such as Iran's `10.10.34.x`), IPv6 egress.

Requirements: Linux (tested Ubuntu 24.04 and Debian 12), sing-box 1.12+ (tested 1.14.3) run as root, `jq`, `curl`, `nftables` for the kill switch.

```bash
for f in harden.sh killswitch.sh leaktest.sh SHA256SUMS; do
  curl -fsSLO "https://github.com/v74all/leak-guard/releases/latest/download/$f"
done
sha256sum -c SHA256SUMS

bash harden.sh --link 'vless://...'        # or hysteria2://...
sudo bash killswitch.sh on
sudo sing-box run -c sb-hardened.json
EXPECT_IP=<your server IP> bash leaktest.sh
```

Inputs: `--link` takes VLESS (tcp, ws, grpc, httpupgrade, http; reality or tls) and Hysteria2 (salamander obfs, `mport` port hopping) share links. sing-box has no XHTTP transport: run your Xray client with a SOCKS port and use `--socks 127.0.0.1:10808 --server <your server's domain>`; Xray's own traffic (process `xray`, change with `--process`) goes around the tunnel. Anything else: `--outbound outbound.json`. Hysteria's `pinSHA256` cannot be used by sing-box, so the certificate is not pinned (a warning is printed).

`--direct-dns auto` (default) uses `dhcp` behind a local stub resolver such as systemd-resolved (otherwise the stub's own query is pulled back into the tunnel and a server given by name never resolves) and `local` elsewhere.

While the kill switch is on and sing-box is stopped, the machine has no internet; `sudo bash killswitch.sh off` restores it. The table does not survive a reboot. Traffic forwarded from containers or VMs is not covered.

License: MIT.

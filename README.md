# 🛡️ wp-isolate - aaPanel OpenLiteSpeed Website Isolation

[![CI Tests](https://github.com/ruanshan4896/wp-isolate/actions/workflows/test.yml/badge.svg)](https://github.com/ruanshan4896/wp-isolate/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![aaPanel](https://img.shields.io/badge/Platform-aaPanel-2C97F1.svg)](https://www.aapanel.com/)

Hệ thống cô lập website độc lập và tự động dành riêng cho máy chủ chạy **aaPanel + OpenLiteSpeed** trên nền tảng **Ubuntu 22.04/24.04 LTS** hoặc **Debian 11/12**.

Dự án được xây dựng nhằm giải quyết triệt để 2 vấn đề lớn nhất khi quản trị nhiều website trên cùng một VPS/Server:
1. **Lây nhiễm mã độc chéo (Cross-Site Contamination)**: Khi một website bị hack hoặc dính web-shell, kẻ tấn công **hoàn toàn bị cô lập**, không thể đọc file cấu hình (`wp-config.php`), database hay lây sang các website khác trên máy chủ.
2. **Quá tải & Tấn công DDoS (Resource Exhaustion)**: Khi một website bị spam, brute-force hay tấn công DDoS tầng L7, website đó bị giới hạn cứng trong hạn mức của riêng nó, **tuyệt đối không làm nghẽn CPU, cạn RAM hay làm sập toàn bộ cơ sở dữ liệu MySQL**.

> [!IMPORTANT]
> **Cam kết không xung đột (Zero-Conflict với aaPanel)**: Bạn vẫn tạo website, cài đặt SSL Let's Encrypt, quản lý file và đổi phiên bản PHP bình thường qua giao diện aaPanel. Công cụ sử dụng cơ chế hook `include` và tự động bảo toàn cấu hình.

---

## 4 Lớp Bảo Vệ & Cô Lập

```
                                      [ Khách truy cập / Botnet DDoS ]
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ OpenLiteSpeed Web Server                                                               │
│                                                                                        │
│  [ Lớp 1: Anti-DDoS & L7 Throttling ]                                                  │
│   ├── perClientConnLimit: 25 conns/IP                                                  │
│   ├── dynReqPerSec: 10 req/s (Tự động chặn flood dynamic PHP)                          │
│   └── Chống brute-force /wp-login.php & /xmlrpc.php                                    │
│                                                                                        │
│  [ Lớp 2: LSAPI suEXEC Process Isolation ]                                             │
│   ├── extUser & extGroup: iso_<domain> (Tiến trình PHP chạy danh tính riêng)            │
│   ├── Socket riêng: uds://tmp/lshttpd/lsphp_<domain>.sock                              │
│   ├── maxConns: 15 workers (Một site bị flood không thể chiếm hết worker của server)   │
│   └── memSoftLimit (400M) / memHardLimit (512M) (Chống cạn RAM / OOM Crash)            │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Linux OS & Filesystem                                                                  │
│                                                                                        │
│  [ Lớp 3: Phân quyền Linux & POSIX ACL ]                                               │
│   ├── User riêng: iso_<domain> (Shell: /usr/sbin/nologin)                              │
│   ├── Thư mục mã nguồn: /www/wwwroot/<domain> (Quyền: 750)                             │
│   ├── POSIX ACL: Cấp quyền đọc file tĩnh cho 'www', chặn mọi site khác                 │
│   ├── Bảo vệ wp-config.php & .env: Quyền 640 (Chỉ duy nhất site đó được đọc mật khẩu) │
│   └── PHP open_basedir: Khóa chặt đường dẫn trong docroot và /tmp                      │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ MySQL / MariaDB Database                                                               │
│                                                                                        │
│  [ Lớp 4: Concurrency Limit ]                                                          │
│   └── ALTER USER 'db_user'@'localhost' WITH MAX_USER_CONNECTIONS 25                    │
│       (Site bị tấn công không thể chiếm hết connection pool của MySQL)                 │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Redis Object Cache Isolation (Layer 5)                                                 │
│                                                                                        │
│  [ Lớp 5: Database ID & Cache Key Salt Isolation ]                                     │
│   ├── Auto-Scaling: Tự động nâng số databases từ 16 lên 64 trong redis.conf            │
│   ├── Auto-Allocation & Re-use: Cấp phát Database ID (1..63) và bảo lưu nguyên vẹn ID  │
│   │   khi chạy lại / cô lập hàng loạt (tránh mất cache đang hoạt động)                 │
│   ├── wp-config.php: Tự động tiêm WP_REDIS_DATABASE & WP_CACHE_KEY_SALT                │
│   ├── LiteSpeed Cache Sync: Tự động đồng bộ Database ID & Key Prefix vào thẳng plugin  │
│   │   LiteSpeed Cache (LSCWP), bật Object Cache Redis tự động mà không cần chỉnh tay   │
│   ├── Chống đè cache tuyệt đối (Zero Cache Collision) nhờ tiền tố Salt theo từng domain │
│   └── Auto Cleanup: Tự động dọn sạch cache cũ (FLUSHDB) nếu đổi Database ID            │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Cài Đặt (Installation)

Chạy các lệnh sau dưới quyền `root` trên server của bạn:

```bash
git clone https://github.com/ruanshan4896/wp-isolate.git /opt/wp-isolate
cd /opt/wp-isolate
bash install.sh
```

Lệnh `wp-isolate` sẽ được kích hoạt toàn hệ thống tại `/usr/local/bin/wp-isolate`.

---

## Hướng Dẫn Sử Dụng (CLI Guide)

### 1. Xem danh sách website và trạng thái
Liệt kê các website hiện có trên aaPanel và kiểm tra xem site nào đã được cô lập:
```bash
wp-isolate list
```

### 2. Cô lập một website cụ thể
Sau khi tạo site mới trên aaPanel (ví dụ `mywebsite.com`), chỉ cần chạy:
```bash
wp-isolate isolate mywebsite.com
```

Tùy chỉnh hạn mức tài nguyên nâng cao:
```bash
wp-isolate isolate mywebsite.com \
  --max-conns 20 \
  --mem-limit 512M \
  --db-limit 30 \
  --req-limit 15
```
- `--max-conns`: Số worker PHP tối đa đồng thời cho site (Mặc định: 15).
- `--mem-limit`: Giới hạn RAM tối đa cho tiến trình (Mặc định: 512M).
- `--db-limit`: Số kết nối MySQL tối đa cho user database của site (Mặc định: 25).
- `--req-limit`: Số request động/giây tối đa trên mỗi IP truy cập (Mặc định: 10 req/s).
- `--redis-db`: Chỉ định Redis Database ID thủ công (Mặc định: tự động cấp phát 1..63).
- `--no-redis`: Bỏ qua cấu hình Redis Cache cho website.

### 3. Cô lập hàng loạt tất cả các site
Tự động quét và cô lập mọi website đang chạy chung user mặc định `www` hoặc chưa có cấu hình Redis Cache:
```bash
wp-isolate isolate-all
```
- **Tự động bảo lưu (Reuse) Redis DB ID**: Các website đã được cô lập trước đó sẽ được giữ nguyên hoàn toàn (bao gồm Database ID trong `wp-config.php`), chỉ cấp ID mới cho các site vừa thêm vào.
- **Không bao giờ lộn cache**: Nhờ `WP_CACHE_KEY_SALT` tiền tố duy nhất theo domain, mọi site đều được bảo vệ độc lập, không lo cache cũ bị đè hay đọc nhầm.
- **Tùy chọn `--force`**: Thêm cờ `--force` (`wp-isolate isolate-all --force`) nếu bạn muốn áp đặt lại toàn bộ cấu hình suEXEC/OLS cho tất cả các site mà vẫn bảo lưu nguyên vẹn Database ID Redis hiện tại của từng site.

### 4. Khôi phục về mặc định (Rollback / Restore)
Nếu muốn hoàn tác trạng thái cô lập và trả website về quyền `www:www` mặc định của aaPanel:
```bash
wp-isolate restore mywebsite.com
```

### 5. Kiểm tra trạng thái chi tiết của 1 website
```bash
wp-isolate status mywebsite.com
```
Hiển thị đầy đủ thông tin: User Linux, số tiến trình PHP đang chạy thực tế, socket, mức RAM giới hạn, số kết nối MySQL, Redis Database ID / Key Salt, và trạng thái đồng bộ LiteSpeed Cache.

### 6. Kiểm tra & Tự động sửa chữa (Audit & Repair)
Nếu bạn vừa chỉnh sửa cấu hình domain trên giao diện aaPanel và nghi ngờ aaPanel đã ghi đè cấu hình:
```bash
# Kiểm tra xem có website nào bị mất liên kết cô lập không:
wp-isolate verify

# Tự động gắn lại liên kết include và sửa quyền file:
wp-isolate repair mywebsite.com
# Hoặc sửa lại tất cả các site:
wp-isolate repair
```

---

## Cơ Chế An Toàn (Fail-Safe & Auto-Rollback)

- **Tự động Backup**: Mỗi khi thực hiện `isolate`, cấu hình ban đầu được sao lưu tại `/opt/wp-isolate/backups/<domain>/<timestamp>/`.
- **Pre-flight Syntax Test**: Kiểm tra cú pháp OpenLiteSpeed bằng `/usr/local/lsws/bin/openlitespeed -t`.
- **Atomic Rollback**: Nếu có bất kỳ lỗi nào trong quá trình kiểm tra cú pháp hoặc nạp dịch vụ, hệ thống **ngay lập tức đảo ngược thay đổi** về trạng thái backup ban đầu chỉ trong 1 giây, cam kết không gây gián đoạn website (Zero Downtime).

---

## Cấu Trúc Dự Án

```
/opt/wp-isolate/
├── bin/
│   └── wp-isolate               # CLI thực thi chính
├── lib/
│   ├── common.sh                # Helper dùng chung, kiểm tra môi trường
│   ├── os_user.sh               # Quản lý Linux user & POSIX ACL
│   ├── ols_vhost.sh             # Điều khiển cấu hình OpenLiteSpeed & suEXEC
│   ├── mysql_limit.sh           # Quản lý giới hạn kết nối MySQL
│   └── redis_isolate.sh         # Quản lý cô lập Redis Object Cache
├── templates/
│   └── ols_isolate.conf.tpl     # Mẫu cấu hình OLS độc lập per-vhost
├── vhosts/                      # Cấu hình đã cô lập của từng domain
├── backups/                     # Thư mục lưu trữ backup tự động
├── data/
│   └── sites.json               # Cơ sở dữ liệu trạng thái hệ thống
└── tests/                       # Bộ kiểm thử tự động (7 test suites)
```

## Chạy Bộ Kiểm Thử (Run Tests)

```bash
bash tests/run_all_tests.sh
```

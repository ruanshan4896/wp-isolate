# 🛡️ wp-isolate - aaPanel OpenLiteSpeed Website Isolation

*Read this in other languages: [English](README.md), [Tiếng Việt](README-vi.md)*


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

## Các Lớp Bảo Vệ & Tự Động Phục Hồi

```
                                      [ Khách truy cập / Botnet DDoS ]
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ OpenLiteSpeed Web Server                                                               │
│                                                                                        │
│  [ Lớp 1: Anti-DDoS & Native Anti-Malware Uploads Shield ]                              │
│   ├── perClientConnLimit: 25 conns/IP                                                  │
│   ├── dynReqPerSec: 10 req/s (Tự động chặn flood dynamic PHP)                          │
│   ├── Chặn tuyệt đối thực thi *.php trong /wp-content/uploads/ (Chặn webshell 403)     │
│   └── Chống brute-force /wp-login.php & /xmlrpc.php                                    │
│                                                                                        │
│  [ Lớp 2: LSAPI suEXEC Process Isolation ]                                             │
│   ├── extUser & extGroup: iso_<domain> (Tiến trình PHP chạy danh tính riêng)            │
│   ├── maxConns: 15 workers (Một site bị flood không thể chiếm hết worker của server)   │
│   └── memSoftLimit / memHardLimit: 2047M (đủ bộ nhớ ảo cho PHP 64-bit)                │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Linux OS & Filesystem                                                                  │
│                                                                                        │
│  [ Lớp 3: Phân quyền Linux & Granular POSIX ACL ]                                      │
│   ├── User riêng: iso_<domain> (Shell: /usr/sbin/nologin)                              │
│   ├── Thư mục mã nguồn: /www/wwwroot/<domain> (Quyền: 750, www chỉ đọc rx)             │
│   ├── Thư mục wp-content/uploads: Cấp quyền rwx cho www (aaPanel WP Toolkit mượt mà)   │
│   ├── Khóa chặt wp-config.php & .env: Quyền 640, www:0 (Cấm tuyệt đối đọc lén mật khẩu)│
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
│ Zero-Touch Sentinel & Global Performance                                               │
│                                                                                        │
│  [ Sentinel Daemon (45s Debounce & Handshake Verification) ]                           │
│   ├── Tự động phát hiện site mới trên aaPanel, chờ 45s lắng dịu rồi tự động cô lập     │
│   ├── Bắt tay xác minh (Handshake Check) triệt tiêu 100% xung đột lúc tạo site         │
│   ├── Tự động phát hiện 503 Service Unavailable, dọn dẹp socket kẹt và phục hồi site   │
│   └── Tự động rà soát & cách ly file PHP độc hại trong uploads định kỳ                 │
│                                                                                        │
│  [ Global PHP Tuning (PHP 8+) ]                                                        │
│   ├── Bật OPcache, TẮT JIT (JIT của PHP 8.4 gây lỗi cấp phát 4GB ảo)                   │
│   └── memory_limit = 512M, upload/post_max_size = 256M, execution_time = 60           │
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
  --mem-limit 2047M \
  --db-limit 30 \
  --req-limit 15
```
- `--max-conns`: Số worker PHP tối đa đồng thời cho site (Mặc định: 15).
- `--mem-limit`: Giới hạn bộ nhớ ảo OpenLiteSpeed cho mỗi site (Mặc định: 2047M). RAM thực tế của WordPress do `WP_MEMORY_LIMIT` (256M) quản lý.
- `--db-limit`: Số kết nối MySQL tối đa cho user database của site (Mặc định: 25).
- `--req-limit`: Số request động/giây tối đa trên mỗi IP truy cập (Mặc định: 10 req/s).

### 3. Cô lập hàng loạt tất cả các site
Tự động quét và cô lập mọi website đang chạy chung user mặc định `www`:
```bash
wp-isolate isolate-all
```
- **Tùy chọn `--force`**: Thêm cờ `--force` (`wp-isolate isolate-all --force`) nếu bạn muốn áp đặt lại toàn bộ cấu hình suEXEC/OLS cho tất cả các site.

### 4. Khôi phục về mặc định (Rollback / Restore)
Nếu muốn hoàn tác trạng thái cô lập và trả website về quyền `www:www` mặc định của aaPanel:
```bash
wp-isolate restore mywebsite.com
```

### 5. Kiểm tra trạng thái chi tiết của 1 website
```bash
wp-isolate status mywebsite.com
```
Hiển thị đầy đủ thông tin: User Linux, số tiến trình PHP đang chạy thực tế, socket, mức RAM giới hạn, số kết nối MySQL, và trạng thái cấu hình OpenLiteSpeed.

### 6. Khắc phục sự cố 503 & Dọn dẹp sau Restore (Clean)
Khi vừa restore website từ bản sao lưu hoặc di chuyển dữ liệu gặp lỗi 503 Service Unavailable:
```bash
# Xoá drop-in object-cache cũ, socket kẹt, file PHP lạ trong uploads và phân quyền lại cho 1 site:
wp-isolate clean mywebsite.com

# Hoặc dọn dẹp và sửa lỗi toàn bộ website trên server:
wp-isolate clean all
```
`clean` không đụng vào `advanced-cache.php` / `WP_CACHE` của LiteSpeed Cache hay `.user.ini` của aaPanel, và với 1 site thì chỉ khởi động lại PHP của riêng site đó.

> [!NOTE]
> **Mô hình Pure 4-Layer Isolation (không Redis)**: `isolate`, `repair` và `clean` xoá các block Redis cũ trong `wp-config.php` và các drop-in `object-cache.php` / `.litespeed_conf.dat`. Website dùng page cache LSCache gốc của OpenLiteSpeed.

### 7. Vệ Binh Tự Động Hóa Toàn Diện (Zero-Touch Sentinel Daemon)
Daemon chạy ngầm thống nhất đảm nhiệm 3 nhiệm vụ tự động:
1. **Tự động cô lập website mới (Zero-Touch)**: Bắt sự kiện tạo site từ aaPanel, đợi 45 giây (Debounce) và kiểm tra bắt tay (Handshake check) để tránh xung đột lúc tạo site.
2. **Auto-Healer 503**: Bắt lỗi 503 Service Unavailable thời gian thực trong error.log và tự phục hồi.
3. **Uploads Sanitizer**: Định kỳ rà soát và cách ly các file `.php` độc hại xuất hiện trái phép trong uploads.

```bash
# Kiểm tra trạng thái Sentinel daemon:
wp-isolate sentinel status

# Bật / Khởi động daemon:
wp-isolate sentinel enable

# Tắt daemon:
wp-isolate sentinel disable

# Khởi động lại daemon:
wp-isolate sentinel restart
```

### 8. Rà soát & Tẩy độc Mã nguồn (Scan & Clean)
Quét toàn diện thư mục uploads, kiểm tra chỉ thị mã độc trong `.user.ini`, `.htaccess`:
```bash
# Quét và dọn sạch file .php độc hại trong uploads của 1 site:
wp-isolate scan mywebsite.com

# Hoặc quét toàn bộ tất cả website trên server:
wp-isolate scan all
```

### 9. Kiểm tra & Tự động sửa chữa (Audit & Repair)
Nếu bạn vừa chỉnh sửa cấu hình domain trên giao diện aaPanel và nghi ngờ aaPanel đã ghi đè cấu hình:
```bash
# Kiểm tra xem có website nào bị mất liên kết cô lập không:
wp-isolate verify

# Tự động gắn lại liên kết suEXEC và sửa quyền file:
wp-isolate repair mywebsite.com
# Hoặc sửa lại tất cả các site:
wp-isolate repair
```

### 10. Nâng cấp server từng chạy bản cũ (có Redis)
Chỉ cần chạy một lần trên server từng dùng bản cũ có Redis:
```bash
cd /opt/wp-isolate && git pull origin master
systemctl restart wp-isolate-sentinel
wp-isolate isolate-all      # áp lại cấu hình PHP: tắt JIT, memory_limit 512M
python3 lib/fix_all.py      # dọn Redis cũ, sửa quyền wp-config, xoá transient, kiểm tra từng site
```
Dòng cuối của `fix_all.py` phải là `N/N verified healthy`; mọi dòng `[ALERT]` là lỗi thật của site đó.

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
│   ├── wp-isolate               # CLI thực thi chính
│   └── wp-isolate-sentinel      # Daemon Sentinel tự động cô lập, sửa lỗi 503 & bảo vệ uploads
├── lib/
│   ├── common.sh                # Helper dùng chung, tối ưu PHP toàn cục, dọn dẹp cache cũ
│   ├── os_user.sh               # Quản lý Linux user & POSIX ACL
│   ├── ols_vhost.sh             # Điều khiển cấu hình OpenLiteSpeed & suEXEC
│   └── mysql_limit.sh           # Quản lý giới hạn kết nối MySQL
├── backups/                     # Thư mục lưu trữ backup tự động
├── data/
│   └── sites.json               # Cơ sở dữ liệu registry trạng thái hệ thống
└── tests/                       # Bộ kiểm thử tự động (7 test suites)
```

## Chạy Bộ Kiểm Thử (Run Tests)

```bash
bash tests/run_all_tests.sh
```

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
│   └── memSoftLimit (400M) / memHardLimit (512M) (Chống cạn RAM / OOM Crash)            │
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
│  [ Global PHP Tuning & OPcache JIT (PHP 8+) ]                                          │
│   ├── Tự động kích hoạt OPcache JIT compiler (tracing, 64M) cho PHP 8.0+               │
│   └── Tối ưu upload_max_filesize = 256M, post_max_size = 256M, execution_time = 60    │
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
# Sửa lỗi 503, gỡ chattr -i .user.ini, dọn socket, thanh lọc drop-in lỗi và phân quyền lại cho 1 site:
wp-isolate clean mywebsite.com

# Hoặc dọn dẹp và sửa lỗi toàn bộ website trên server:
wp-isolate clean all
```

> [!NOTE]
> **Mô hình Pure 4-Layer Isolation (Tách rời hoàn toàn Redis Object Cache)**: Khi chạy `isolate`, `repair` hoặc `clean`, `wp-isolate` sẽ tự động dọn sạch các block cấu hình Redis cũ trong `wp-config.php` và các drop-in (`object-cache.php`, `.litespeed_conf.dat`) từng gây lỗi treo deadlock fatal error khi chạy 50+ websites. Các website vận hành ổn định 100% nhờ bộ nhớ đệm trang Full-Page Cache gốc cực nhanh của OpenLiteSpeed mà không cần can thiệp tầng Object Cache của WordPress.

### 7. Vệ Binh Tự Động Hóa Toàn Diện (Zero-Touch Sentinel Daemon)
Daemon chạy ngầm thống nhất đảm nhiệm 3 nhiệm vụ tự động:
1. **Tự động cô lập website mới (Zero-Touch)**: Bắt sự kiện tạo site từ aaPanel, đệm lắng dịu 15 giây (Debounce) và kiểm tra bắt tay (Handshake check) để triệt tiêu 100% xung đột lúc tạo site.
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

### 7. Tự động khắc phục lỗi 503 sau khi Restore (Auto-Healer)
Khi bạn giải nén mã nguồn hoặc dùng plugin khôi phục dữ liệu (như UpdraftPlus), mã nguồn thường bị sai quyền sở hữu hoặc mang theo các cấu hình cache cũ gây xung đột dẫn đến sập **lỗi 503 Service Unavailable**.

**Khắc phục thủ công:**
```bash
wp-isolate clean mywebsite.com
```
Lệnh này sẽ dọn sạch cache rác (`object-cache.php`), bẻ khóa `.user.ini`, phân quyền lại và ép website hoạt động trở lại.

**Tự động hóa hoàn toàn (Auto-Healer Daemon):**
Kích hoạt Daemon chạy ngầm giám sát log của máy chủ. Khi phát hiện lỗi 503, nó sẽ tự động chạy lệnh `clean` trong 0.1 giây để ép website sống lại mà không cần bạn phải can thiệp:
```bash
wp-isolate healer enable
```
*(Lưu ý: Daemon này được tự động kích hoạt khi bạn chạy script cài đặt `install.sh`)*

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
│   ├── common.sh                # Helper dùng chung, JIT & tối ưu PHP toàn cục, dọn dẹp cache cũ
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

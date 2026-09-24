# aaPanel OpenLiteSpeed Website Isolation (`wp-isolate`)

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
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Cài Đặt (Installation)

Chạy các lệnh sau dưới quyền `root` trên server của bạn:

```bash
git clone https://github.com/ruanshan4896/wp-isolate.git /opt/wp-isolate-src
cd /opt/wp-isolate-src
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

### 4. Khôi phục về mặc định (Rollback / Restore)
Nếu muốn hoàn tác trạng thái cô lập và trả website về quyền `www:www` mặc định của aaPanel:
```bash
wp-isolate restore mywebsite.com
```

### 5. Kiểm tra trạng thái chi tiết của 1 website
```bash
wp-isolate status mywebsite.com
```
Hiển thị đầy đủ thông tin: User Linux, số tiến trình PHP đang chạy thực tế, socket, mức RAM giới hạn và số kết nối MySQL.

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
- **Pre-flight Syntax Test**: Kiểm tra cú pháp OpenLiteSpeed bằng `/usr/local/lsws/bin/lswsctrl test`.
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
│   └── mysql_limit.sh           # Quản lý giới hạn kết nối MySQL
├── templates/
│   └── ols_isolate.conf.tpl     # Mẫu cấu hình OLS độc lập per-vhost
├── vhosts/                      # Cấu hình đã cô lập của từng domain
├── backups/                     # Thư mục lưu trữ backup tự động
├── data/
│   └── sites.json               # Cơ sở dữ liệu trạng thái hệ thống
└── tests/                       # Bộ kiểm thử tự động (6 test suites)
```

## Chạy Bộ Kiểm Thử (Run Tests)

```bash
bash tests/run_all_tests.sh
```

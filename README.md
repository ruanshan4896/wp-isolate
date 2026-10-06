# 🛡️ wp-isolate - aaPanel OpenLiteSpeed Website Isolation

*Read this in other languages: [English](README.md), [Tiếng Việt](README-vi.md)*

[![CI Tests](https://github.com/ruanshan4896/wp-isolate/actions/workflows/test.yml/badge.svg)](https://github.com/ruanshan4896/wp-isolate/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![aaPanel](https://img.shields.io/badge/Platform-aaPanel-2C97F1.svg)](https://www.aapanel.com/)

An independent and fully automated website isolation system designed exclusively for servers running **aaPanel + OpenLiteSpeed** on **Ubuntu 22.04/24.04 LTS** or **Debian 11/12**.

This project was built to completely resolve the two biggest problems when managing multiple websites on the same VPS/Server:
1. **Cross-Site Contamination**: When a website is hacked or infected with a web-shell, the attacker is **completely isolated**. They cannot read configuration files (`wp-config.php`), databases, or spread to other websites on the server.
2. **Resource Exhaustion & DDoS Attacks**: When a website is spammed, brute-forced, or targeted by an L7 DDoS attack, it is strictly rate-limited within its own quota. It will **never choke the CPU, deplete RAM, or crash the entire MySQL database pool**.

> [!IMPORTANT]
> **Zero-Conflict with aaPanel**: You can continue to create websites, install Let's Encrypt SSL, manage files, and change PHP versions normally through the aaPanel GUI. This tool uses `include` hooks and preserves existing configurations automatically.

---

## Layers of Protection & Auto-Healing

```
                                      [ Visitors / Botnet DDoS ]
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ OpenLiteSpeed Web Server                                                               │
│                                                                                        │
│  [ Layer 1: Anti-DDoS & Native Anti-Malware Uploads Shield ]                          │
│   ├── perClientConnLimit: 25 conns/IP                                                  │
│   ├── dynReqPerSec: 10 req/s (Auto blocks dynamic PHP floods)                          │
│   ├── Blocks *.php execution in /wp-content/uploads/ (Immediate 403 Webshell Blocker)  │
│   └── Anti brute-force for /wp-login.php & /xmlrpc.php                                 │
│                                                                                        │
│  [ Layer 2: LSAPI suEXEC Process Isolation ]                                           │
│   ├── extUser & extGroup: iso_<domain> (PHP processes run under isolated identities)   │
│   ├── maxConns: 15 workers (A flooded site cannot exhaust the server's workers)        │
│   └── memSoftLimit (400M) / memHardLimit (512M) (Prevents RAM exhaustion / OOM Crashes)│
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Linux OS & Filesystem                                                                  │
│                                                                                        │
│  [ Layer 3: Linux Permissions & Granular POSIX ACL ]                                   │
│   ├── Dedicated User: iso_<domain> (Shell: /usr/sbin/nologin)                          │
│   ├── Source code directory: /www/wwwroot/<domain> (Perms: 750, www has rx only)       │
│   ├── Uploads directory: /wp-content/uploads (Perms: 775, www has rwx for WP Toolkit) │
│   ├── Protected wp-config.php & .env: Perms 640, www:0 (No cross-site DB credential leak│
│   └── PHP open_basedir: Strictly locks paths within docroot and /tmp                   │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ MySQL / MariaDB Database                                                               │
│                                                                                        │
│  [ Layer 4: Concurrency Limit ]                                                        │
│   └── ALTER USER 'db_user'@'localhost' WITH MAX_USER_CONNECTIONS 25                    │
│       (An attacked site cannot exhaust the MySQL connection pool)                      │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Zero-Touch Sentinel & Global Performance                                               │
│                                                                                        │
│  [ Sentinel Daemon (45s Debounce & Handshake Verification) ]                           │
│   ├── Auto-detects new aaPanel websites, settles for 45s, then isolates automatically  │
│   ├── Handshake checks eliminate race conditions during aaPanel site creation          │
│   ├── Real-time 503 Auto-Healer clears stale sockets and restores services             │
│   └── Rogue PHP Uploads Sanitizer quarantines unauthorized PHP files                   │
│                                                                                        │
│  [ Global PHP Tuning & OPcache JIT (PHP 8+) ]                                          │
│   ├── Auto-activates OPcache JIT compiler (tracing, 64M) for PHP 8.0+                  │
│   └── Optimizes upload_max_filesize = 256M, post_max_size = 256M, execution_time = 60 │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Installation

Run the following commands as `root` on your server:

```bash
git clone https://github.com/ruanshan4896/wp-isolate.git /opt/wp-isolate
cd /opt/wp-isolate
bash install.sh
```

The `wp-isolate` command will be activated system-wide at `/usr/local/bin/wp-isolate`.

---

## CLI Guide

### 1. View website list and status
List existing websites on aaPanel and check which ones are isolated:
```bash
wp-isolate list
```

### 2. Isolate a specific website
After creating a new site on aaPanel (e.g. `mywebsite.com`), simply run:
```bash
wp-isolate isolate mywebsite.com
```

Advanced resource limits configuration:
```bash
wp-isolate isolate mywebsite.com \
  --max-conns 20 \
  --mem-limit 512M \
  --db-limit 30 \
  --req-limit 15
```

### 3. Mass isolate all sites
Automatically scan and isolate all websites currently running under the default `www` user:
```bash
wp-isolate isolate-all
```
- **Force Re-apply**: Add the `--force` flag (`wp-isolate isolate-all --force`) to force re-apply the suEXEC/OLS configuration for all sites.

### 4. Rollback / Restore
If you want to revert the isolation state and restore the website to the default aaPanel `www:www` permissions:
```bash
wp-isolate restore mywebsite.com
```

### 5. Check detailed status of a website
```bash
wp-isolate status mywebsite.com
```

### 6. Clean stale cache & repair 503s (Clean)
When a site is restored from an aaPanel backup or encounters 503 Service Unavailable:
```bash
# Clean stale cache, remove .user.ini immutable lock, purge broken sockets, drop-ins and fix perms:
wp-isolate clean mywebsite.com

# Or clean and repair all websites on the server:
wp-isolate clean all
```

> [!NOTE]
> **Pure 4-Layer Isolation (Decoupled from Redis Object Cache)**: When running `isolate`, `repair` or `clean`, `wp-isolate` automatically purges legacy Redis configuration blocks from `wp-config.php` and removes drop-in files (`object-cache.php`, `.litespeed_conf.dat`) that could trigger lock deadlocks or fatal errors when running 50+ websites. WordPress sites run with 100% stability relying on OpenLiteSpeed's ultra-fast native HTML Full-Page Cache (LSCache Page Cache) with zero Redis dependencies.

### 7. Unified Zero-Touch Sentinel Daemon
A background daemon continuously performs 3 automated tasks:
1. **Zero-Touch Auto-Isolation**: Detects new sites on aaPanel, waits for a 15s debounce settling window and verifies handshake to prevent race conditions during site creation.
2. **Real-Time 503 Auto-Healer**: Automatically intercepts 503 errors and restores services.
3. **Rogue PHP Uploads Sanitizer**: Regularly quarantines unauthorized PHP files inside uploads.

```bash
# Check sentinel daemon status:
wp-isolate sentinel status

# Enable and start daemon:
wp-isolate sentinel enable

# Disable daemon:
wp-isolate sentinel disable

# Restart daemon:
wp-isolate sentinel restart
```

### 8. Malware Scan & Uploads Sanitization
Scan docroot and uploads for rogue PHP files and suspicious `.user.ini` prepend directives:
```bash
# Scan a single domain:
wp-isolate scan mywebsite.com

# Scan all domains on the server:
wp-isolate scan all
```

### 9. Audit & Repair
If you recently edited a domain's configuration via the aaPanel UI and suspect aaPanel might have overwritten the vhost config:
```bash
# Check if any website has lost its isolation configuration:
wp-isolate verify

# Automatically re-apply suEXEC and fix file permissions:
wp-isolate repair mywebsite.com
# Or repair all sites:
wp-isolate repair
```

---

## Fail-Safe & Auto-Rollback

- **Auto Backup**: Every time `isolate` is executed, the original configuration is backed up to `/opt/wp-isolate/backups/<domain>/<timestamp>/`.
- **Pre-flight Syntax Test**: Validates OpenLiteSpeed syntax using `/usr/local/lsws/bin/openlitespeed -t`.
- **Atomic Rollback**: If any errors occur during syntax testing or service reload, the system **instantly reverts changes** to the original backup within 1 second, guaranteeing Zero Downtime.

---

## Project Structure

```
/opt/wp-isolate/
├── bin/
│   ├── wp-isolate               # Main CLI executable
│   ├── wp-isolate-sentinel      # Unified Sentinel daemon (auto-isolate, 503 heal & uploads shield)
│   └── wp-isolate-healer        # Backward-compatibility alias for sentinel
├── lib/
│   ├── common.sh                # Shared helpers, PHP JIT & global tuning, legacy cache cleanup
│   ├── os_user.sh               # Linux user & POSIX ACL isolation
│   ├── ols_vhost.sh             # OpenLiteSpeed vhost & suEXEC controller
│   └── mysql_limit.sh           # MySQL connection pool limit manager
├── backups/                     # Pre-flight automatic backups
├── data/
│   └── sites.json               # System state registry database
└── tests/                       # Automated test suite (7 test suites)
```

## Run Tests

```bash
bash tests/run_all_tests.sh
```

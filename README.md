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
│  [ Layer 1: Anti-DDoS & L7 Throttling ]                                                │
│   ├── perClientConnLimit: 25 conns/IP                                                  │
│   ├── dynReqPerSec: 10 req/s (Auto blocks dynamic PHP floods)                          │
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
│  [ Layer 3: Linux Permissions & POSIX ACL ]                                            │
│   ├── Dedicated User: iso_<domain> (Shell: /usr/sbin/nologin)                          │
│   ├── Source code directory: /www/wwwroot/<domain> (Perms: 750)                        │
│   ├── POSIX ACL: Grants read/write to 'www' (Full aaPanel WP Toolkit compatibility)    │
│   ├── Protected wp-config.php & .env: Perms 640 (Only this site can read its DB pass)  │
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
│ Redis Object Cache Isolation                                                           │
│                                                                                        │
│  [ Layer 5: Database ID & Cache Key Salt Isolation ]                                   │
│   ├── Auto-Scaling: Automatically increases max databases from 16 to 64 in redis.conf  │
│   ├── Auto-Allocation & Re-use: Allocates Database IDs (1..63) and preserves them      │
│   ├── LiteSpeed Cache Sync: Auto generates drop-in & .litespeed_conf.dat               │
│   └── Zero Cache Collision via unique Key Salt prefixes per domain                     │
└────────────────────────────────────────────┬───────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Auto-Healing & Global Performance                                                      │
│                                                                                        │
│  [ Layer 6: Auto-Healer Daemon (Real-Time 503 Protection) ]                            │
│   ├── Continuously monitors OpenLiteSpeed error logs in real-time                      │
│   └── Automatically intercepts 503 Service Unavailable, clears sockets & repairs site │
│                                                                                        │
│  [ Layer 7: Global PHP Tuning & OPcache JIT (PHP 8+) ]                                 │
│   ├── Auto-activates OPcache JIT compiler (tracing, 64M) for PHP 8.0+                  │
│   └── Optimizes upload_max_filesize = 256M, post_max_size = 256M, execution_time = 300│
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
- **Force Re-apply**: Add the `--force` flag (`wp-isolate isolate-all --force`) to force re-apply the suEXEC/OLS configuration for all sites while preserving their current Redis Database IDs.

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
# Clean stale cache, remove .user.ini immutable lock, purge broken sockets and fix perms:
wp-isolate clean mywebsite.com

# Or clean and repair all websites on the server:
wp-isolate clean all
```

### 7. Real-time auto-healing daemon (Healer)
A background daemon continuously monitors OpenLiteSpeed error logs and automatically repairs 503 errors instantly:
```bash
# Check healer daemon status:
wp-isolate healer status

# Enable and start daemon:
wp-isolate healer enable

# Disable daemon:
wp-isolate healer disable

# Restart daemon:
wp-isolate healer restart
```

### 8. Audit & Repair
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
│   └── wp-isolate-healer        # Real-time 503 auto-healing background daemon
├── lib/
│   ├── common.sh                # Shared helpers, PHP JIT & global tuning
│   ├── os_user.sh               # Linux user & POSIX ACL isolation
│   ├── ols_vhost.sh             # OpenLiteSpeed vhost & suEXEC controller
│   ├── mysql_limit.sh           # MySQL connection pool limit manager
│   └── redis_isolate.sh         # Redis Object Cache isolation (DB ID & Salt)
├── backups/                     # Pre-flight automatic backups
├── data/
│   └── sites.json               # System state registry database
└── tests/                       # Automated test suite (7 test suites)
```

## Run Tests

```bash
bash tests/run_all_tests.sh
```

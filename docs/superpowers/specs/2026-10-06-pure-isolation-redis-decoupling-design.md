# Design Specification: Pure 4-Layer Isolation & Redis Decoupling

- **Date**: 2026-10-06
- **Status**: Approved
- **Scope**: Architectural Refactoring of `wp-isolate`
- **Target Platform**: Ubuntu 22.04/24.04 LTS, Debian 11/12 with aaPanel + OpenLiteSpeed (OLS)

---

## 1. Problem Statement & Background

### 1.1 The Issue
`wp-isolate` was originally created to provide security isolation (dedicated Linux users, POSIX ACLs, OLS suEXEC process containment, and MySQL connection limits) on aaPanel servers.

Later, Layer 5 (Redis Object Cache Isolation) was introduced to automatically allocate Redis Database IDs (1..63) and inject object cache configurations into `wp-config.php`, `.litespeed_conf.dat`, and `object-cache.php`.

In production environments hosting **50+ websites**, running 50+ isolated WordPress sites through a single shared, single-threaded Redis daemon introduced severe architectural vulnerabilities:
1. **Mutex Lock Deadlocks**: Detached or timed-out PHP worker processes left unexpired lock keys in Redis, causing subsequent worker processes to hang indefinitely (`possible dead lock` in LSAPI).
2. **Cascading Failure (Domino Effect)**: A single site with heavy queries or infected plugins slowed down or locked the shared Redis thread, causing all other 50+ websites to fail with *"There has been a critical error on this website"*.
3. **Database ID Exhaustion**: Capping or allocating DB IDs created artificial ceilings and management friction.
4. **Violation of Separation of Concerns**: Redis Object Cache is a performance optimization layer, **not** an isolation/security boundary. WordPress on OpenLiteSpeed already benefits from **LSCache Page Cache (HTML Full-Page Caching)** directly at the web server layer, which operates at near-instant speed without invoking PHP, MySQL, or Redis.

### 1.2 The Goal
Refactor `wp-isolate` into a **Pure 4-Layer Isolation System**:
- **100% Zero-Invasive to WordPress Internals**: Never inject object cache drop-ins, never manipulate Redis databases, and never alter internal cache options.
- **Strictly Confined to OS & Web Server Boundaries**:
  - Layer 1: OpenLiteSpeed L7 Throttling & DDoS Mitigation (`perClientConnLimit`, `dynReqPerSec`, uploads PHP block).
  - Layer 2: LSAPI suEXEC Process Isolation (`setUIDMode 2`, dedicated `extUser`/`extGroup` = `iso_<domain>`, `maxConns 15`, memory limits, `max_execution_time 60`).
  - Layer 3: Linux OS & POSIX ACL Filesystem Isolation (isolated user, docroot `750`, `wp-config.php` `640`, POSIX ACL `u:www:rwx`, `open_basedir`).
  - Layer 4: MySQL Database Concurrency Limit (`MAX_USER_CONNECTIONS 25`).
- **Automated Migration & Cleanup**:
  - Cleanly purge any legacy `WP-ISOLATE REDIS` blocks from `wp-config.php`.
  - Delete orphan `wp-content/object-cache.php` and `wp-content/.litespeed_conf.dat` drop-ins across all websites on `repair` and `clean`.
  - Let aaPanel and site administrators manage application-level plugins as they see fit.

---

## 2. Architecture & Components

```
                                [ Web Traffic / DDoS ]
                                          │
                                          ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ OpenLiteSpeed Web Server                                                               │
│                                                                                        │
│  [ Layer 1: Anti-DDoS & L7 Throttling ]                                                │
│   ├── perClientConnLimit: 25 conns/IP                                                  │
│   ├── dynReqPerSec: 10 req/s (Blocks dynamic PHP flooding)                             │
│   └── Prohibits direct PHP script execution inside /wp-content/uploads/                │
│                                                                                        │
│  [ Layer 2: LSAPI suEXEC Process Isolation ]                                           │
│   ├── extUser & extGroup: iso_<domain> (PHP runs under dedicated system identity)      │
│   ├── maxConns: 15 workers (A flooded site cannot exhaust server worker pools)         │
│   ├── memSoftLimit (400M) / memHardLimit (512M) (Prevents server OOM)                  │
│   └── max_execution_time = 60s (Prevents lingering hung workers)                       │
└────────────────────────────────────────┬───────────────────────────────────────────────┘
                                         │
                                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Linux OS & Filesystem                                                                  │
│                                                                                        │
│  [ Layer 3: Linux Permissions & POSIX ACL ]                                            │
│   ├── Dedicated User: iso_<domain> (Shell: /usr/sbin/nologin)                          │
│   ├── Document Root: /www/wwwroot/<domain> (chmod 750)                                 │
│   ├── POSIX ACL: Grants 'www' access for aaPanel WP Toolkit & static asset delivery    │
│   ├── Config Protection: wp-config.php & .env (chmod 640)                              │
│   └── PHP open_basedir: Confines execution strictly to docroot and /tmp                │
└────────────────────────────────────────┬───────────────────────────────────────────────┘
                                         │
                                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ MySQL / MariaDB Database                                                               │
│                                                                                        │
│  [ Layer 4: Concurrency Limit ]                                                        │
│   └── ALTER USER 'db_user'@'localhost' WITH MAX_USER_CONNECTIONS 25                    │
│       (Prevents a compromised site from exhausting MySQL connection pools)             │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Component Changes

### 3.1 Removal / Purge of Redis Code
- `lib/redis_isolate.sh` will be converted into a cleanup migration utility (`lib/cache_cleanup.sh`) or its purge functions (`purge_legacy_redis_config`) merged into `lib/common.sh`.
- Remove all calls to:
  - `ensure_redis_databases`
  - `get_next_available_redis_db`
  - `get_existing_wp_redis_db`
  - `apply_wp_redis_config`
  - `sync_litespeed_redis_config`
- All commands (`isolate`, `isolate-all`, `repair`, `clean`) will actively ensure that:
  1. `wp-config.php` has any `/* BEGIN WP-ISOLATE REDIS */ ... /* END WP-ISOLATE REDIS */` blocks stripped out.
  2. `wp-content/object-cache.php` and `wp-content/.litespeed_conf.dat` generated by `wp-isolate` are safely unlinked if present.
  3. No custom database connections or sockets are opened to Redis.

### 3.2 CLI Refinement (`bin/wp-isolate`)
- Remove unused options:
  - `--redis-db <num>` (removed)
  - `--no-redis` (kept as a no-op flag for backwards compatibility)
- Streamline `list` output:
  - Columns: `DOMAIN | STATUS | LINUX USER | PHP VER | MAX CONNS` (drop `REDIS DB` column).
- Streamline `status` output:
  - Output displays: Status, Linux User, Docroot, VHost Config, Max PHP Conns, Memory Limits, Per-Client Limit, Dynamic Request Limit, Active PHP Workers.
- Streamline `sites.json`:
  - Store: `{ "domain": { "user": "iso_domain" } }`.

### 3.3 Repair & Clean Refinement
- `wp-isolate clean <domain|all>`:
  - Purges any stale sockets in `/tmp/lshttpd/`.
  - Removes `.user.ini` locks.
  - Clears rogue `.php` files in `/wp-content/uploads/`.
  - Removes any broken `object-cache.php` drop-ins.
  - Re-applies permissions and vhost limits.
  - Gracefully restarts/reloads OLS and kills old `lsphp` workers.
- `wp-isolate repair [domain]`:
  - Re-applies suEXEC configuration, POSIX ACLs, uploads PHP blocker, and purges any legacy Redis blocks across all sites.

---

## 4. Verification & Testing

1. Automated Tests:
   - `test_cli_help.sh`: Verify updated help output without Redis options.
   - `test_cli_workflow.sh`: Verify end-to-end `isolate`, `status`, `list`, `clean`, `repair` workflow.
   - `test_ols_vhost.sh`: Verify `setUIDMode 2`, `extUser`, `maxConns 15`, `max_execution_time 60`, uploads PHP block.
   - `test_clean_legacy_cache.sh`: Verify that old Redis blocks and drop-ins are stripped cleanly without breaking `wp-config.php`.
   - `test_common.sh`, `test_mysql_limit.sh`, `test_os_user.sh`: Verify passing cleanly.
2. Production Verification:
   - All 50+ websites on the server will run strictly isolated without Redis dependency.
   - Zero deadlock risk, zero OOM risk from Redis.

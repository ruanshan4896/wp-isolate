# Design Specification: Zero-Touch Auto-Isolation & Anti-Malware Hardening (`wp-isolate` v2.0)

- **Author**: Antigravity Assistant & System Administrator
- **Date**: 2026-10-04
- **Status**: Approved Design Spec
- **Target Environment**: Ubuntu 22.04/24.04 LTS, Debian 11/12 with aaPanel and OpenLiteSpeed (OLS)

---

## 1. Problem Statement & Background

### 1.1 The Lifecycle Gap & Race Condition
1. **Cross-Site Lateral Infection during Restore**:
   When administrators create websites on aaPanel and restore backups (e.g., via UpdraftPlus), the site initially runs as shared user `www:www`. If an old backup contains malware (commonly webshells in `wp-content/uploads/*.php`), running before isolation allows the webshell to read/write across all sites under `/www/wwwroot/`.
2. **Race Condition during Automated Site Creation**:
   Earlier attempts at auto-isolation suffered from premature execution. When aaPanel adds a website, its Python backend performs a multi-step sequence over 3-8 seconds (directory creation, `.user.ini` creation with `chattr +i`, vhost generation, DB creation, OLS reload). A naive file watcher triggering instantly upon file creation modifies files while aaPanel is still writing them, causing `Permission Denied` and aaPanel site creation failure.
3. **Permission Over-privileging**:
   Setting `u:www:rwx` globally across the entire docroot gave any process running as `www` write access into isolated sites.

### 1.2 Core Objectives
- **Zero-Touch Automation**: Users only interact with aaPanel UI and WordPress. No terminal commands needed in daily operations.
- **Debounce & Handshake Verification**: Ensure aaPanel has 100% finished site creation before isolation hooks engage (15s settling window + 4 handshake checks).
- **Granular POSIX ACLs**: Limit `www` write access strictly to media uploads (`wp-content/uploads`), forbidding writes to core code and blocking access to `wp-config.php`.
- **Native OLS Uploads Execution Blocker**: Deny HTTP execution of `*.php` files in `wp-content/uploads/` at the web server level (`403 Forbidden`).
- **Sentinel Daemon**: A single unified background daemon (`wp-isolate-sentinel`) combining real-time auto-isolation, 503 healing, and upload sanitization.

---

## 2. Technical Architecture

### 2.1 Granular Permissions Matrix

| Target | Owner:Group | Mode | POSIX ACL (`www`) | Rationale |
| :--- | :--- | :--- | :--- | :--- |
| `/www/wwwroot/<domain>` | `iso_<domain>:<iso_domain>` | `750` | `u:www:rx`, default `u:www:rx` | OLS serves static files; cannot write to root |
| `wp-config.php`, `.env` | `iso_<domain>:<iso_domain>` | `640` | `u:www:0` (Strict) / `u:www:r` | Protect DB credentials from cross-site snooping |
| `wp-content/uploads/` | `iso_<domain>:<iso_domain>` | `775` | `u:www:rwx`, default `u:www:rwx` | aaPanel File Manager / WP Toolkit can upload media |
| Core PHP (`index.php`, etc.) | `iso_<domain>:<iso_domain>` | `644` | `u:www:rx` | Read-only for `www`, writable only by `iso_<domain>` |

### 2.2 Native OpenLiteSpeed Uploads PHP Blocker
In `/www/server/panel/vhost/openlitespeed/detail/<domain>.conf`:
```apache
### BEGIN WP-ISOLATE: <domain> ###
perClientConnLimit 25
dynReqPerSec 10
outBandwidth 0
inBandwidth 0
blockBadReq 1

# Block direct execution of PHP files in uploads (Zero-Day & Webshell neutralizer)
rewrite {
  enable 1
  rules <<<END_RULES
    RewriteRule ^wp-content/uploads/.*\.php$ - [F,L]
  END_RULES
}
### END WP-ISOLATE: <domain> ###
```

### 2.3 Sentinel Daemon (`wp-isolate-sentinel`)
Combines two roles:
1. **Auto-Isolator with Debounce (15s)**:
   - Watches `/www/server/panel/vhost/openlitespeed/` for file changes.
   - When a new or modified vhost is detected, queues `<domain>` for 15 seconds.
   - Executes handshake verification:
     1. `detail/<domain>.conf` contains complete `extprocessor` block and matching closing brace.
     2. `/www/wwwroot/<domain>` exists and has settled (no active lock).
     3. `openlitespeed -t` passes.
   - Invokes `wp-isolate isolate <domain>`.
2. **Auto-Healer for 503 errors**:
   - Tails `/usr/local/lsws/logs/error.log` for `503 Service Unavailable`.
   - Cleans stale sockets and re-applies permissions.
3. **Uploads Sanitizer**:
   - Scans and deletes rogue `.php` files inside `wp-content/uploads/`.

---

## 3. Implementation Plan Overview
- Task 1: Update `lib/os_user.sh` with Granular ACLs and protected config files.
- Task 2: Update `lib/ols_vhost.sh` with native uploads PHP rewrite blocking.
- Task 3: Build `bin/wp-isolate-sentinel` daemon (Debounce + Handshake + 503 Healer + Upload cleaner).
- Task 4: Update `bin/wp-isolate` CLI to manage sentinel daemon (`wp-isolate sentinel <enable|disable|status>`).
- Task 5: Update `install.sh`, tests, documentation, commit and push to GitHub.

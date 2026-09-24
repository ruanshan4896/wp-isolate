# Design Specification: aaPanel OpenLiteSpeed Website Isolation (`wp-isolate`)

- **Author**: Antigravity Assistant & System Administrator
- **Date**: 2026-09-24
- **Status**: Approved Design Spec
- **Target Environment**: Ubuntu 22.04/24.04 LTS, Debian 11/12 with aaPanel and OpenLiteSpeed (OLS)

---

## 1. Problem Statement & Objectives

### 1.1 Context & Problem
On standard aaPanel installations (with OpenLiteSpeed or Nginx), all websites share a single Linux user (`www:www`) and a shared PHP execution pool. This architecture introduces two severe security and availability risks:
1. **Cross-Site Contamination / Lateral Movement**: If one website is compromised (e.g., via a vulnerable WordPress plugin or webshell), the attacker runs with `www` privileges. They can read configuration files of other websites located under `/www/wwwroot/` (such as `wp-config.php`), extract database credentials, and infect all other sites on the server.
2. **Resource Exhaustion & Denial of Service**: If one website suffers a DDoS attack, traffic spike, or infinite loop in PHP, its spawned workers consume all available server CPU, RAM, and MySQL database connection slots (`max_connections`), bringing down every other website hosted on the same instance.

### 1.2 Core Objectives
Build a dedicated command-line isolation system (`wp-isolate`) that:
- **Enforces Absolute User Separation**: Runs each website's PHP execution in an isolated Linux user account via OpenLiteSpeed LSAPI suEXEC mode.
- **Prevents File Snooping**: Enforces filesystem permissions (`750` / `600`) and POSIX ACLs so no website can access another's codebase or database credentials.
- **Caps Resources & Mitigates L7 Floods**: Implements per-site dynamic request throttling, per-IP connection limits, memory caps, and worker process limits natively in OpenLiteSpeed.
- **Isolates Database Concurrency**: Limits concurrent database connections per site user in MySQL/MariaDB.
- **Guarantees Zero Conflict with aaPanel**: Retains full aaPanel functionality (File Manager, SSL management, domain modifications, backup tools) and provides an instant, fail-safe rollback mechanism.

---

## 2. System Architecture & aaPanel Non-Interference

### 2.1 File System Organization
The project will be located in `/opt/wp-isolate/` with the following structure:

```
/opt/wp-isolate/
├── bin/
│   └── wp-isolate               # Main executable CLI script
├── lib/
│   ├── common.sh                # Logger, colors, validator, OS detector
│   ├── os_user.sh               # User/group management & POSIX ACL handler
│   ├── ols_vhost.sh             # OpenLiteSpeed vhost parser, suEXEC config generator
│   ├── throttle.sh              # L7 Throttling & DDoS rule generator
│   └── mysql_limit.sh           # MySQL user credential detector & limit applier
├── templates/
│   └── ols_isolate.conf.tpl     # OpenLiteSpeed per-vhost isolated include template
├── vhosts/                      # Generated isolation configs per domain
│   └── <domain>/
│       └── ols_isolate.conf
├── backups/                     # Pre-isolation backups for rollback
│   └── <domain>/
│       └── <timestamp>/
│           ├── vhost.conf
│           └── permissions.txt
└── data/
    └── sites.json               # System state registry
```

A symbolic link `/usr/local/bin/wp-isolate -> /opt/wp-isolate/bin/wp-isolate` allows running the command system-wide.

### 2.2 Integration Mechanism (Zero-Conflict Design)
aaPanel manages OpenLiteSpeed virtual hosts by reading and updating config files in `/www/server/panel/vhost/openlitespeed/`.
- When `wp-isolate isolate <domain>` is executed:
  1. The tool backs up the existing vhost configuration file.
  2. Generates an external application definition and script handler inside `/opt/wp-isolate/vhosts/<domain>/ols_isolate.conf`.
  3. Appends a distinct include directive to the bottom of aaPanel's vhost configuration:
     ```apache
     ### BEGIN WP-ISOLATE: <domain> ###
     include /opt/wp-isolate/vhosts/<domain>/ols_isolate.conf
     ### END WP-ISOLATE: <domain> ###
     ```
  4. Runs `/usr/local/lsws/bin/lswsctrl test` to verify syntax. If valid, gracefully reloads OpenLiteSpeed (`touch /tmp/lshttpd/.rtreport` or `systemctl reload lsws`).
- **aaPanel Compatibility**:
  - Because aaPanel web daemon runs as `root`, aaPanel's File Manager, SSL renewal, and backup tasks continue to operate without `Permission Denied` errors.
  - If a user changes domain settings in aaPanel and aaPanel overwrites the vhost file, the `wp-isolate verify` and `wp-isolate repair` commands can instantly restore the include block.

---

## 3. Security, Permissions & LSAPI suEXEC Design

### 3.1 Linux System User & Group
For each website `<domain>` (e.g. `example.com`):
- Clean username: `iso_<domain_sanitized>` (e.g., `iso_example_com`, sanitized to meet Linux `useradd` requirements, maximum 31 characters).
- Command: `useradd --system --no-create-home --home-dir /www/wwwroot/<domain> --shell /usr/sbin/nologin --user-group iso_<domain_sanitized>`
- Account is locked for interactive login.

### 3.2 Filesystem Permissions & POSIX ACLs
- Root directory `/www/wwwroot/<domain>`:
  - Owner: `iso_<domain_sanitized>:iso_<domain_sanitized>`
  - Base Directory Permission: `chmod 750 /www/wwwroot/<domain>`
- OpenLiteSpeed Static File Access (via POSIX ACL):
  - In aaPanel, OpenLiteSpeed's static file reader process runs under user `www` (or `nobody`).
  - To allow OLS to serve static assets (CSS, JS, images) without allowing other sites to access files:
    ```bash
    setfacl -R -m u:www:rx /www/wwwroot/<domain>
    setfacl -R -d -m u:www:rx /www/wwwroot/<domain>
    ```
- Sensitive Configuration Protection (`wp-config.php`, `.env`):
  - Configuration files containing database passwords are explicitly restricted:
    ```bash
    chmod 640 /www/wwwroot/<domain>/wp-config.php
    setfacl -m u:www:0 /www/wwwroot/<domain>/wp-config.php
    ```
  - This ensures only `root` and the dedicated site worker (`iso_<domain_sanitized>`) can read database credentials.

### 3.3 OpenLiteSpeed LSAPI suEXEC Configuration
The isolated configuration `/opt/wp-isolate/vhosts/<domain>/ols_isolate.conf` defines:

```apache
extprocessor lsphp_<domain_clean> {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp_<domain_clean>.sock
  maxConns                15
  env                     LSAPI_AVOID_FORK=1
  initTimeout             60
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      30
  respBuffer              0
  autoStart               1
  path                    /usr/local/lsws/lsphp<version>/bin/lsphp
  backlog                 50
  instances               1
  extUser                 iso_<domain_clean>
  extGroup                iso_<domain_clean>
  runOnStartUp            1
  priority                0
  memSoftLimit            400M
  memHardLimit            512M
  procSoftLimit           20
  procHardLimit           30
}

scripthandler {
  add lsapi:lsphp_<domain_clean> php
}

phpIniOverride {
  php_admin_value[open_basedir] = "/www/wwwroot/<domain>/:/tmp/:/dev/urandom"
  php_admin_value[session.save_path] = "/tmp"
  php_admin_value[upload_tmp_dir] = "/tmp"
}
```

---

## 4. L7 Throttling, Resource Limits & MySQL Protection

### 4.1 OpenLiteSpeed Per-Client Throttling (Anti-DDoS / Rate Limit)
Appended to the virtual host configuration:
- `perClientConnLimit`: 25 (Maximum concurrent connections from a single IP address).
- `dynReqPerSec`: 10 (Maximum dynamic PHP requests per second per IP).
- `outBandwidth`: 0 (Unlimited by default, configurable).
- `blockBadReq`: 1 (Automatically blocks malformed HTTP requests).
- WordPress specific endpoint protections:
  - Limits access rate to `/wp-login.php` and `/xmlrpc.php` to prevent credential stuffing and pingback amplification.

### 4.2 Resource Capping (LSAPI)
- `maxConns = 15`: At most 15 PHP processes can be spawned concurrently for this website. Even if hit by 10,000 requests/sec, the site cannot allocate more than 15 workers, preserving the remaining CPU/RAM for all other websites.
- `memSoftLimit = 400M`, `memHardLimit = 512M`: Automatically terminates worker processes that exceed the memory ceiling to avoid server-wide Out-Of-Memory (OOM) panics.
- `procSoftLimit = 20`, `procHardLimit = 30`: Limits maximum total processes owned by the user account, mitigating fork-bomb exploits.

### 4.3 MySQL Connection Concurrency Limit
- The tool extracts the database username from `/www/wwwroot/<domain>/wp-config.php` (or aaPanel database records).
- Applies query limit to MySQL/MariaDB:
  ```sql
  ALTER USER '<db_user>'@'localhost' WITH MAX_USER_CONNECTIONS 25;
  ALTER USER '<db_user>'@'127.0.0.1' WITH MAX_USER_CONNECTIONS 25;
  ```
- Prevents database connection exhaustion across the shared database server.

---

## 5. Command-Line Interface (CLI) Specification

### 5.1 Commands
- `wp-isolate list`
  - Scans `/www/server/panel/vhost/openlitespeed/` and `/www/wwwroot/`.
  - Displays formatted table: `DOMAIN | STATUS (ISOLATED/DEFAULT) | USER | PHP VERSION | MAX CONNS | MEM LIMIT`.
- `wp-isolate isolate <domain> [options]`
  - Options:
    - `--max-conns <num>` (Default: 15)
    - `--mem-limit <size>` (Default: 512M)
    - `--db-limit <num>` (Default: 25)
    - `--req-limit <num>` (Default: 10)
  - Performs backup -> creates user -> sets permissions & ACLs -> writes OLS config -> configures MySQL -> tests syntax -> reloads OLS -> updates `sites.json`.
- `wp-isolate isolate-all`
  - Batch executes `isolate` across all unisolated websites.
- `wp-isolate restore <domain>`
  - Restores original ownership (`www:www`) and file permissions.
  - Removes include directive from aaPanel vhost config.
  - Removes MySQL `MAX_USER_CONNECTIONS` limit.
  - Deletes isolated config and tests/reloads OpenLiteSpeed.
  - Cleans up system user `iso_<domain_clean>`.
- `wp-isolate status <domain>`
  - Inspects active LSAPI socket, process list, user ID of running workers, and permission status.
- `wp-isolate verify`
  - Health check: checks if aaPanel modified vhost files and dropped the include directive, or if file permissions drifted.
- `wp-isolate repair [domain]`
  - Automatically re-applies include directives and permissions without resetting user data.

### 5.2 Error Handling & Fail-Safe Mechanics
- **Syntax Pre-Check**: Before reloading OpenLiteSpeed, executes `/usr/local/lsws/bin/lswsctrl test`.
- **Automatic Rollback**: If syntax check fails or reload encounters an error, the tool immediately reverts files from the timestamped backup directory and logs the exact error details.
- **Idempotency**: All operations can be safely re-run without duplicating users or corrupting configuration files.

---

## 6. Implementation Stages & Verification Plan

1. **Phase 1: Project Scaffolding & Core Libraries**
   - Create directory structure under `/opt/wp-isolate/` (and local workspace repository).
   - Implement `common.sh` (logging, prerequisites, checks for root, aaPanel, OLS).
   - Implement `os_user.sh` (user creation, validation, POSIX ACL handling).
2. **Phase 2: OpenLiteSpeed Config & Throttling Modules**
   - Implement `ols_vhost.sh` (parser, template engine, include injection, OLS syntax verification and reload).
   - Implement `throttle.sh` (rate limiting and DDoS rules).
   - Implement `mysql_limit.sh` (wp-config parser and MySQL connection limiter).
3. **Phase 3: CLI Entry Point & State Registry**
   - Implement `wp-isolate` executable supporting `list`, `isolate`, `isolate-all`, `restore`, `status`, `verify`, and `repair`.
   - Implement automated backup and rollback routines.
4. **Phase 4: Automated Testing & Validation**
   - Mock tests for config generation and syntax validity.
   - Verification of lateral movement prevention (ensuring User A cannot read User B's `/www/wwwroot/`).
   - Verification of aaPanel web interface compatibility.

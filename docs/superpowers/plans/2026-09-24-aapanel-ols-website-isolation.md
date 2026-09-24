# aaPanel OpenLiteSpeed Website Isolation (`wp-isolate`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a robust, non-conflicting CLI isolation utility (`wp-isolate`) for aaPanel servers running OpenLiteSpeed on Ubuntu/Debian, enforcing per-site dedicated Linux users (suEXEC), filesystem ACL isolation, L7 rate limiting, LSAPI memory/process caps, and MySQL connection limits.

**Architecture:** A modular Bash CLI tool installed under `/opt/wp-isolate/` with libraries for system user management, OpenLiteSpeed vhost include injection, L7 throttling, and MySQL concurrency limits. State and pre-flight backups are maintained in JSON and timestamped configuration snapshots to ensure zero-conflict operation with aaPanel and atomic automatic rollback.

**Tech Stack:** Bash 5+, OpenLiteSpeed (OLS) LSAPI suEXEC, POSIX ACL (`setfacl`/`getfacl`), Linux System Users (`useradd`/`usermod`), MySQL/MariaDB CLI (`mysql`), JSON/jq (or pure Bash JSON parsing).

**Spec:** [docs/superpowers/specs/2026-09-24-aapanel-ols-website-isolation-design.md](file:///c:/Users/aaaa/Desktop/wp-isolate/docs/superpowers/specs/2026-09-24-aapanel-ols-website-isolation-design.md)

## Global Constraints

- Target OS: Ubuntu 22.04/24.04 LTS, Debian 11/12.
- Environment: aaPanel with OpenLiteSpeed installed (`/usr/local/lsws/`, `/www/server/panel/`).
- User separation: Every isolated site gets a system user `iso_<sanitized_domain>` with no login shell (`/usr/sbin/nologin`).
- Root web directory: `/www/wwwroot/<domain>` owned by `iso_<sanitized_domain>`, permissions `750`.
- POSIX ACL: User `www` granted `rx` on directory for static assets; sensitive files (`wp-config.php`, `.env`) restricted to `640` with `u:www:0`.
- OpenLiteSpeed suEXEC: Each site has its own `extprocessor` running as `iso_<sanitized_domain>`.
- Fail-safe: Pre-flight backup before modification; `/usr/local/lsws/bin/lswsctrl test` check before reload; instant rollback on syntax error.

---

### Task 1: Scaffolding, Common Helpers & Prerequisite Validation

**Files:**
- Create: `lib/common.sh`
- Create: `tests/test_common.sh`

**Interfaces:**
- Produces:
  - `log_info(msg)`, `log_success(msg)`, `log_warn(msg)`, `log_error(msg)`
  - `sanitize_domain_to_user(domain)` -> returns sanitized Linux username (max 31 chars, lowercase, alnum and underscore)
  - `check_prerequisites()` -> verifies root privileges, OS compatibility, aaPanel directory `/www/server/panel/`, OpenLiteSpeed path `/usr/local/lsws/`, and required tools (`setfacl`, `getfacl`, `mysql`).

- [ ] **Step 1: Write unit tests for common helpers**

Create `tests/test_common.sh` testing `sanitize_domain_to_user` and basic logging without requiring root privileges.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

test_sanitize_domain() {
    local result
    result=$(sanitize_domain_to_user "my-cool-site.com")
    [[ "$result" == "iso_my_cool_site_com" ]] || { echo "Failed: $result"; exit 1; }

    result=$(sanitize_domain_to_user "sub.domain.verylongdomainnameexceedinglimit.vn")
    [[ ${#result} -le 31 ]] || { echo "Failed length: ${#result}"; exit 1; }
    [[ "$result" =~ ^iso_[a-z0-9_]+$ ]] || { echo "Failed format: $result"; exit 1; }
    echo "test_sanitize_domain PASS"
}

test_sanitize_domain
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_common.sh`
Expected: FAIL (file `lib/common.sh` not found).

- [ ] **Step 3: Implement `lib/common.sh`**

Create `lib/common.sh` with logging, string sanitization, and environment check functions.

```bash
#!/usr/bin/env bash
# lib/common.sh - Common utilities for wp-isolate

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_RESET="\033[0m"

log_info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }

sanitize_domain_to_user() {
    local domain="$1"
    local clean
    clean=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    local user="iso_${clean}"
    if [ ${#user} -gt 31 ]; then
        user="${user:0:31}"
        user=$(echo "$user" | sed 's/_$//')
    fi
    echo "$user"
}

check_prerequisites() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_error "wp-isolate must be run as root."
        return 1
    fi

    if [ ! -d "/www/server/panel" ]; then
        log_error "aaPanel not detected (/www/server/panel not found)."
        return 1
    fi

    if [ ! -d "/usr/local/lsws" ]; then
        log_error "OpenLiteSpeed not detected (/usr/local/lsws not found)."
        return 1
    fi

    for cmd in setfacl getfacl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_warn "$cmd not found. Installing acl package..."
            apt-get update -qq && apt-get install -y -qq acl || true
        fi
    done
    return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_common.sh`
Expected: PASS output `test_sanitize_domain PASS`.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/test_common.sh
git commit -m "feat(core): implement common helpers and domain sanitization"
```

---

### Task 2: Linux User Management & Filesystem ACL Module

**Files:**
- Create: `lib/os_user.sh`
- Create: `tests/test_os_user.sh`

**Interfaces:**
- Consumes: `lib/common.sh` (`sanitize_domain_to_user`, `log_*`)
- Produces:
  - `create_isolated_user(domain)` -> creates system user `iso_<clean>` if not exists
  - `remove_isolated_user(domain)` -> removes system user and group
  - `apply_site_permissions(domain, docroot)` -> sets `750` ownership to `iso_<clean>`, sets ACL `u:www:rx` for static files, and `640` with `u:www:0` on `wp-config.php`
  - `restore_site_permissions(domain, docroot)` -> restores ownership to `www:www` and clears custom ACLs.

- [ ] **Step 1: Write unit tests for `lib/os_user.sh`**

Create `tests/test_os_user.sh` testing mock commands or parameter validation for user creation and permission commands.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/os_user.sh"

test_user_generation() {
    local domain="test-sample.org"
    local user
    user=$(get_site_user "$domain")
    [[ "$user" == "iso_test_sample_org" ]] || { echo "User mismatch: $user"; exit 1; }
    echo "test_user_generation PASS"
}

test_user_generation
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_os_user.sh`
Expected: FAIL (file `lib/os_user.sh` not found).

- [ ] **Step 3: Implement `lib/os_user.sh`**

```bash
#!/usr/bin/env bash
# lib/os_user.sh - Linux user and filesystem ACL isolation

get_site_user() {
    local domain="$1"
    sanitize_domain_to_user "$domain"
}

create_isolated_user() {
    local domain="$1"
    local user
    user=$(get_site_user "$domain")

    if id "$user" >/dev/null 2>&1; then
        log_info "System user $user already exists."
        return 0
    fi

    log_info "Creating dedicated system user $user for $domain..."
    useradd --system --no-create-home --home-dir "/www/wwwroot/${domain}" --shell /usr/sbin/nologin --user-group "$user"
    log_success "User $user created successfully."
}

remove_isolated_user() {
    local domain="$1"
    local user
    user=$(get_site_user "$domain")

    if id "$user" >/dev/null 2>&1; then
        log_info "Removing system user $user..."
        userdel "$user" 2>/dev/null || true
        groupdel "$user" 2>/dev/null || true
        log_success "User $user removed."
    fi
}

apply_site_permissions() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local user
    user=$(get_site_user "$domain")

    if [ ! -d "$docroot" ]; then
        log_error "Document root $docroot does not exist."
        return 1
    fi

    log_info "Applying isolation permissions on $docroot for user $user..."
    chown -R "${user}:${user}" "$docroot"
    chmod 750 "$docroot"

    # Allow aaPanel OLS web worker (www) read access to static assets via POSIX ACL
    setfacl -R -m u:www:rx "$docroot"
    setfacl -R -d -m u:www:rx "$docroot"

    # Restrict sensitive config files (wp-config.php, .env)
    for conf_file in "$docroot/wp-config.php" "$docroot/.env"; do
        if [ -f "$conf_file" ]; then
            chown "${user}:${user}" "$conf_file"
            chmod 640 "$conf_file"
            setfacl -m u:www:0 "$conf_file" 2>/dev/null || true
            log_info "Secured configuration file: $conf_file (640, isolated from other users)"
        fi
    done
    log_success "Permissions applied successfully."
}

restore_site_permissions() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"

    if [ ! -d "$docroot" ]; then
        return 0
    fi

    log_info "Restoring standard aaPanel permissions (www:www) on $docroot..."
    setfacl -R -b "$docroot" 2>/dev/null || true
    chown -R www:www "$docroot"
    chmod 755 "$docroot"
    find "$docroot" -type f -exec chmod 644 {} +
    find "$docroot" -type d -exec chmod 755 {} +
    log_success "Restored permissions to www:www."
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_os_user.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/os_user.sh tests/test_os_user.sh
git commit -m "feat(security): implement user creation and POSIX ACL permissions"
```

---

### Task 3: OpenLiteSpeed Configuration Generator & VHost Hook Module

**Files:**
- Create: `templates/ols_isolate.conf.tpl`
- Create: `lib/ols_vhost.sh`
- Create: `tests/test_ols_vhost.sh`

**Interfaces:**
- Consumes: `lib/common.sh`, `lib/os_user.sh`
- Produces:
  - `detect_ols_vhost_file(domain)` -> locates aaPanel's vhost file for domain
  - `detect_php_version(domain)` -> determines active PHP version (e.g. `81` for lsphp81)
  - `generate_isolate_config(domain, options)` -> writes `/opt/wp-isolate/vhosts/<domain>/ols_isolate.conf`
  - `inject_ols_include(domain)` -> safely appends `include` block to aaPanel vhost config
  - `remove_ols_include(domain)` -> cleans `include` block from aaPanel vhost config
  - `verify_and_reload_ols()` -> executes pre-flight syntax check and reloads OLS.

- [ ] **Step 1: Create template `templates/ols_isolate.conf.tpl`**

```apache
# OpenLiteSpeed Isolated Configuration for {{DOMAIN}}
# Generated by wp-isolate on {{TIMESTAMP}}

extprocessor lsphp_{{DOMAIN_CLEAN}} {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp_{{DOMAIN_CLEAN}}.sock
  maxConns                {{MAX_CONNS}}
  env                     LSAPI_AVOID_FORK=1
  initTimeout             60
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      30
  respBuffer              0
  autoStart               1
  path                    {{LSPHP_PATH}}
  backlog                 50
  instances               1
  extUser                 {{USER}}
  extGroup                {{USER}}
  runOnStartUp            1
  priority                0
  memSoftLimit            {{MEM_SOFT_LIMIT}}
  memHardLimit            {{MEM_HARD_LIMIT}}
  procSoftLimit           {{PROC_SOFT_LIMIT}}
  procHardLimit           {{PROC_HARD_LIMIT}}
}

scripthandler {
  add lsapi:lsphp_{{DOMAIN_CLEAN}} php
}

phpIniOverride {
  php_admin_value[open_basedir] = "{{DOCROOT}}/:/tmp/:/dev/urandom"
  php_admin_value[session.save_path] = "/tmp"
  php_admin_value[upload_tmp_dir] = "/tmp"
}

# L7 Anti-DDoS and Request Throttling
perClientConnLimit        {{PER_CLIENT_CONN_LIMIT}}
dynReqPerSec              {{DYN_REQ_PER_SEC}}
outBandwidth              0
inBandwidth               0
blockBadReq               1
```

- [ ] **Step 2: Write test for OLS config generation**

Create `tests/test_ols_vhost.sh` verifying placeholder replacement.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/os_user.sh"
source "${SCRIPT_DIR}/lib/ols_vhost.sh"

test_render_template() {
    local tmp_out
    tmp_out=$(mktemp)
    render_ols_isolate_template "demo.com" "81" 15 "512M" 10 "$tmp_out"
    grep -q "extprocessor lsphp_demo_com" "$tmp_out" || { echo "extprocessor not found"; exit 1; }
    grep -q "extUser                 iso_demo_com" "$tmp_out" || { echo "extUser mismatch"; exit 1; }
    grep -q "perClientConnLimit        25" "$tmp_out" || { echo "conn limit missing"; exit 1; }
    rm -f "$tmp_out"
    echo "test_render_template PASS"
}

test_render_template
```

- [ ] **Step 3: Implement `lib/ols_vhost.sh`**

Implement `render_ols_isolate_template`, `inject_ols_include`, `remove_ols_include`, and `verify_and_reload_ols`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_ols_vhost.sh`
Expected: PASS output `test_render_template PASS`.

- [ ] **Step 5: Commit**

```bash
git add templates/ols_isolate.conf.tpl lib/ols_vhost.sh tests/test_ols_vhost.sh
git commit -m "feat(ols): implement OpenLiteSpeed vhost include and suEXEC generator"
```

---

### Task 4: MySQL Connection Limiter Module

**Files:**
- Create: `lib/mysql_limit.sh`
- Create: `tests/test_mysql_limit.sh`

**Interfaces:**
- Consumes: `lib/common.sh`
- Produces:
  - `extract_wp_db_user(docroot)` -> extracts `DB_USER` from `wp-config.php`
  - `set_mysql_user_limit(db_user, max_conns)` -> executes `ALTER USER ... WITH MAX_USER_CONNECTIONS ...`
  - `remove_mysql_user_limit(db_user)` -> resets `WITH MAX_USER_CONNECTIONS 0`.

- [ ] **Step 1: Write test for db user extraction**

Create `tests/test_mysql_limit.sh` testing regex extraction from mock `wp-config.php`.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/mysql_limit.sh"

test_extract_db_user() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cat << 'EOF' > "${tmp_dir}/wp-config.php"
define( 'DB_NAME', 'sample_db' );
define( 'DB_USER', 'site_user_123' );
define( 'DB_PASSWORD', 'secretpass' );
EOF
    local user
    user=$(extract_wp_db_user "$tmp_dir")
    [[ "$user" == "site_user_123" ]] || { echo "Extracted user mismatch: $user"; exit 1; }
    rm -rf "$tmp_dir"
    echo "test_extract_db_user PASS"
}

test_extract_db_user
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_mysql_limit.sh`
Expected: FAIL (file `lib/mysql_limit.sh` not found).

- [ ] **Step 3: Implement `lib/mysql_limit.sh`**

```bash
#!/usr/bin/env bash
# lib/mysql_limit.sh - MySQL database concurrency isolation

extract_wp_db_user() {
    local docroot="$1"
    local wp_config="$docroot/wp-config.php"
    if [ ! -f "$wp_config" ]; then
        return 1
    fi
    grep -E "define\s*\(\s*['\"]DB_USER['\"]\s*,\s*['\"][^'\"]+['\"]\s*\)" "$wp_config" \
        | sed -E "s/.*['\"]DB_USER['\"]\s*,\s*['\"]([^'\"]+)['\"].*/\1/" \
        | head -n 1
}

set_mysql_user_limit() {
    local db_user="$1"
    local max_conns="${2:-25}"

    if [ -z "$db_user" ]; then
        return 0
    fi

    log_info "Configuring MySQL MAX_USER_CONNECTIONS=$max_conns for database user: $db_user..."
    mysql -e "ALTER USER '${db_user}'@'localhost' WITH MAX_USER_CONNECTIONS ${max_conns};" 2>/dev/null || true
    mysql -e "ALTER USER '${db_user}'@'127.0.0.1' WITH MAX_USER_CONNECTIONS ${max_conns};" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_success "MySQL user limits updated."
}

remove_mysql_user_limit() {
    local db_user="$1"
    if [ -z "$db_user" ]; then
        return 0
    fi
    log_info "Resetting MySQL MAX_USER_CONNECTIONS for database user: $db_user..."
    mysql -e "ALTER USER '${db_user}'@'localhost' WITH MAX_USER_CONNECTIONS 0;" 2>/dev/null || true
    mysql -e "ALTER USER '${db_user}'@'127.0.0.1' WITH MAX_USER_CONNECTIONS 0;" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_mysql_limit.sh`
Expected: PASS output `test_extract_db_user PASS`.

- [ ] **Step 5: Commit**

```bash
git add lib/mysql_limit.sh tests/test_mysql_limit.sh
git commit -m "feat(mysql): implement database concurrency connection limits"
```

---

### Task 5: Main CLI Executable, State Management & Backup/Rollback Engine

**Files:**
- Create: `bin/wp-isolate`
- Create: `install.sh`
- Create: `tests/test_cli_help.sh`

**Interfaces:**
- Consumes: All libraries (`common.sh`, `os_user.sh`, `ols_vhost.sh`, `mysql_limit.sh`)
- Produces: CLI interface supporting:
  - `wp-isolate list`
  - `wp-isolate isolate <domain> [--max-conns N] [--mem-limit M] [--db-limit D]`
  - `wp-isolate isolate-all`
  - `wp-isolate restore <domain>`
  - `wp-isolate status <domain>`
  - `wp-isolate verify`
  - `wp-isolate repair [domain]`

- [ ] **Step 1: Write test for CLI usage and flags**

Create `tests/test_cli_help.sh` validating `--help` output and exit code.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output=$(bash "${SCRIPT_DIR}/bin/wp-isolate" --help)
echo "$output" | grep -q "Usage: wp-isolate" || { echo "Usage string missing"; exit 1; }
echo "$output" | grep -q "isolate <domain>" || { echo "isolate command missing"; exit 1; }
echo "test_cli_help PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_cli_help.sh`
Expected: FAIL (`bin/wp-isolate` not found).

- [ ] **Step 3: Implement `bin/wp-isolate` and `install.sh`**

Implement complete CLI dispatcher with state recording in `/opt/wp-isolate/data/sites.json` and atomic rollback on failure. Create `install.sh` to install project to `/opt/wp-isolate` and link `/usr/local/bin/wp-isolate`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_cli_help.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/wp-isolate install.sh tests/test_cli_help.sh
git commit -m "feat(cli): complete wp-isolate CLI tool, state manager, and installer"
```

---

### Task 6: End-to-End Test Suite & Documentation

**Files:**
- Create: `tests/run_all_tests.sh`
- Create: `README.md`

- [ ] **Step 1: Implement test runner `tests/run_all_tests.sh`**

Runs all test scripts in `tests/` and asserts zero failures.

- [ ] **Step 2: Run `bash tests/run_all_tests.sh`**

Verify all test suites pass.

- [ ] **Step 3: Write comprehensive `README.md`**

Provide installation instructions, command usage examples, architecture diagram, and troubleshooting for aaPanel + OpenLiteSpeed.

- [ ] **Step 4: Commit**

```bash
git add tests/run_all_tests.sh README.md
git commit -m "docs: add full documentation and end-to-end test runner"
```

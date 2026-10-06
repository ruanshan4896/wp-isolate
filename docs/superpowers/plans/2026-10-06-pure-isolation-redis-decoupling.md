# Pure 4-Layer Isolation & Redis Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completely decouple Redis Object Cache from `wp-isolate`, returning to a pure 4-layer isolation architecture (OLS suEXEC, L7 Throttling, POSIX ACLs, MySQL limits) with automated cleanup of legacy Redis artifacts.

**Architecture:** Remove Redis database scaling and config injection. Implement a robust `purge_legacy_redis_config` utility in `lib/common.sh` that strips legacy `WP-ISOLATE REDIS` blocks from `wp-config.php` and deletes orphaned `object-cache.php` and `.litespeed_conf.dat` drop-ins. Refactor `bin/wp-isolate` to eliminate Redis dependencies while maintaining 100% compatibility with OpenLiteSpeed native Page Caching and aaPanel web management.

**Tech Stack:** Bash, OpenLiteSpeed API/CLI, POSIX ACL (`setfacl`/`getfacl`), Linux sysadmin tools.

**Spec:** [docs/superpowers/specs/2026-10-06-pure-isolation-redis-decoupling-design.md](file:///c:/Users/aaaa/Desktop/wp-isolate/docs/superpowers/specs/2026-10-06-pure-isolation-redis-decoupling-design.md)

## Global Constraints
- Must not break existing aaPanel web management (Zero-Conflict).
- Must preserve native LiteSpeed Page Cache (HTML full-page cache) functionality.
- Must cleanly strip out legacy Redis configurations on `repair`, `clean`, and `isolate` without modifying user-defined `wp-config.php` database credentials or settings.
- All test suites must pass 100% on standard Bash/Ubuntu/Debian and MSYS.

---

### Task 1: Add Legacy Redis Purge Utility in `lib/common.sh`

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/test_clean_legacy_cache.sh`

**Interfaces:**
- Produces: `purge_legacy_redis_config "$domain" "$docroot"` in `lib/common.sh`

- [ ] **Step 1: Write failing test in `tests/test_clean_legacy_cache.sh`**
```bash
#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

test_purge_legacy_redis_config() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "${tmp_dir}/wp-content/plugins/litespeed-cache"

    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
define( 'DB_NAME', 'sample_db' );
/* BEGIN WP-ISOLATE REDIS */
// LiteSpeed Cache (LSCWP) Native Object Cache Overrides
if ( ! defined( 'LITESPEED_CONF' ) ) {
    define( 'LITESPEED_CONF', true );
}
define( 'LITESPEED_CONF__OBJECT__DB_ID', 5 );
/* END WP-ISOLATE REDIS */
define( 'DB_USER', 'sample_user' );
EOF

    touch "${tmp_dir}/wp-content/object-cache.php"
    touch "${tmp_dir}/wp-content/.litespeed_conf.dat"

    purge_legacy_redis_config "purge-test.com" "$tmp_dir"

    if grep -q "WP-ISOLATE REDIS" "${tmp_dir}/wp-config.php"; then
        echo "Failed to purge WP-ISOLATE REDIS block from wp-config.php"; exit 1
    fi
    grep -q "DB_NAME" "${tmp_dir}/wp-config.php" || { echo "DB_NAME missing"; exit 1; }
    grep -q "DB_USER" "${tmp_dir}/wp-config.php" || { echo "DB_USER missing"; exit 1; }

    [ ! -f "${tmp_dir}/wp-content/object-cache.php" ] || { echo "object-cache.php was not deleted"; exit 1; }
    [ ! -f "${tmp_dir}/wp-content/.litespeed_conf.dat" ] || { echo ".litespeed_conf.dat was not deleted"; exit 1; }

    rm -rf "$tmp_dir"
    echo "test_purge_legacy_redis_config PASS"
}

test_purge_legacy_redis_config
```

- [ ] **Step 2: Run test to verify it fails**
Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_clean_legacy_cache.sh`
Expected: FAIL with `purge_legacy_redis_config: command not found`

- [ ] **Step 3: Implement `purge_legacy_redis_config` in `lib/common.sh`**
Add:
```bash
purge_legacy_redis_config() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local wp_config="$docroot/wp-config.php"

    if [ -f "$wp_config" ]; then
        if grep -q "WP-ISOLATE REDIS" "$wp_config" 2>/dev/null; then
            sed_i '/\/\* BEGIN WP-ISOLATE REDIS \*\//,/\/\* END WP-ISOLATE REDIS \*\//d' "$wp_config"
            log_info "Purged legacy Redis configuration from $wp_config."
        fi
    fi

    # Unlink any legacy object cache drop-ins created by wp-isolate
    rm -f "${docroot}/wp-content/object-cache.php" 2>/dev/null || true
    rm -f "${docroot}/wp-content/.litespeed_conf.dat" 2>/dev/null || true
}
```

- [ ] **Step 4: Run test to verify it passes**
Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_clean_legacy_cache.sh`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add lib/common.sh tests/test_clean_legacy_cache.sh
git commit -m "feat(core): add purge_legacy_redis_config utility to cleanly uncouple redis artifacts"
```

---

### Task 2: Refactor `bin/wp-isolate` to Remove Redis Dependencies

**Files:**
- Modify: `bin/wp-isolate`

- [ ] **Step 1: Remove `source .../lib/redis_isolate.sh` from `bin/wp-isolate`**
Line 23: remove `source "${SCRIPT_DIR}/lib/redis_isolate.sh"`.

- [ ] **Step 2: Update `cmd_help` in `bin/wp-isolate`**
Remove `--redis-db` and update options descriptions. Keep `--no-redis` as an accepted but ignored option for backwards compatibility.

- [ ] **Step 3: Update `cmd_isolate` in `bin/wp-isolate`**
- Remove step 6 (Redis Cache Isolation).
- Replace with:
```bash
    # Step 6: Ensure legacy Redis drop-ins and blocks are purged
    purge_legacy_redis_config "$domain" "$docroot"
```
- Update `update_site_registry` to only record `{"user": user}`.

- [ ] **Step 4: Update `cmd_list` and `cmd_status` in `bin/wp-isolate`**
- In `cmd_list`: Change headers to:
  `printf "%-25s | %-10s | %-20s | %-8s | %-10s\n" "DOMAIN" "STATUS" "LINUX USER" "PHP VER" "MAX CONNS"`
- In `cmd_status`: Remove Redis database lines, showing clean pure 4-layer isolation metrics.

- [ ] **Step 5: Update `cmd_repair` and `clean_single_domain` in `bin/wp-isolate`**
- In `cmd_repair`: ensure `purge_legacy_redis_config "$domain" "$docroot"` runs for each repaired site.
- In `clean_single_domain`: ensure `purge_legacy_redis_config "$target_domain" "$docroot"` is called.

- [ ] **Step 6: Test CLI help and workflow**
Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_cli_help.sh`
Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_cli_workflow.sh`
Expected: PASS

- [ ] **Step 7: Commit**
```bash
git add bin/wp-isolate
git commit -m "refactor(cli): decouple redis from isolate, list, status, repair and clean commands"
```

---

### Task 3: Remove `lib/redis_isolate.sh` & Update Test Suite

**Files:**
- Delete: `lib/redis_isolate.sh`
- Delete: `tests/test_redis_isolate.sh`
- Modify: `tests/run_all_tests.sh`

- [ ] **Step 1: Remove obsolete files**
```bash
git rm lib/redis_isolate.sh tests/test_redis_isolate.sh
```

- [ ] **Step 2: Run all tests**
Run: `& "C:\Program Files\Git\bin\bash.exe" tests/run_all_tests.sh`
Expected: All suites PASS.

- [ ] **Step 3: Commit**
```bash
git commit -m "refactor: remove obsolete redis_isolate module and tests"
```

---

### Task 4: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `README-vi.md`

- [ ] **Step 1: Update `README-vi.md`**
- Replace 5-layer diagram with 4-layer Pure Isolation diagram.
- Remove references to Redis DB allocation in CLI guide.
- Explain that LiteSpeed Page Cache is native and unencumbered by Redis.

- [ ] **Step 2: Update `README.md`**
- Mirror the English updates.

- [ ] **Step 3: Commit**
```bash
git add README.md README-vi.md
git commit -m "docs: update architecture diagrams and CLI guide for pure 4-layer isolation"
```

---

### Task 5: Final Verification & Git Push

- [ ] **Step 1: Run complete test suite**
Run: `& "C:\Program Files\Git\bin\bash.exe" tests/run_all_tests.sh`
Expected: 100% PASS.

- [ ] **Step 2: Push changes to GitHub**
Run: `git push origin master`

- [ ] **Step 3: Provide VPS deployment instructions to the user**
Explain the exact command to pull and run `wp-isolate repair` to clean all 50+ sites instantly.

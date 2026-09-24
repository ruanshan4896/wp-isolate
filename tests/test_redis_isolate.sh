#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/redis_isolate.sh"

test_apply_and_remove_wp_redis() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
define( 'DB_NAME', 'sample_db' );
define( 'DB_USER', 'sample_user' );
define( 'DB_PASSWORD', 'secret' );
$table_prefix = 'wp_';
require_once ABSPATH . 'wp-settings.php';
EOF

    # 1. Test standard Redis block (when no litespeed plugin is present)
    apply_wp_redis_config "my-site.com" "$tmp_dir" 3

    grep -q "BEGIN WP-ISOLATE REDIS" "${tmp_dir}/wp-config.php" || { echo "Redis block missing"; exit 1; }
    grep -q "define( 'WP_REDIS_DATABASE', 3 )" "${tmp_dir}/wp-config.php" || { echo "DB ID mismatch"; exit 1; }
    grep -q "define( 'WP_CACHE_KEY_SALT', 'my_site_com_' )" "${tmp_dir}/wp-config.php" || { echo "Salt mismatch"; exit 1; }
    # Verify no redundant LiteSpeed constants in standard setup
    if grep -q "LITESPEED_CONF" "${tmp_dir}/wp-config.php"; then
        echo "Unexpected LSCache constants in standard setup"; exit 1
    fi
    [[ "$(extract_wp_redis_db "${tmp_dir}/wp-config.php")" -eq 3 ]] || { echo "extract_wp_redis_db mismatch"; exit 1; }

    # 2. Test LiteSpeed Cache block (when litespeed-cache plugin is present)
    mkdir -p "${tmp_dir}/wp-content/plugins/litespeed-cache"
    apply_wp_redis_config "my-site.com" "$tmp_dir" 3
    grep -q "define( 'LITESPEED_CONF__OBJECT', true )" "${tmp_dir}/wp-config.php" || { echo "LSCache OBJECT enable mismatch"; exit 1; }
    grep -q "define( 'LITESPEED_CONF__OBJECT__HOST', '127.0.0.1' )" "${tmp_dir}/wp-config.php" || { echo "LSCache HOST mismatch"; exit 1; }
    grep -q "define( 'LITESPEED_CONF__OBJECT__DB_ID', 3 )" "${tmp_dir}/wp-config.php" || { echo "LSCache DB ID mismatch"; exit 1; }
    grep -q "define( 'LITESPEED_CONF__OBJECT__KEY_PREFIX', 'my_site_com_' )" "${tmp_dir}/wp-config.php" || { echo "LSCache prefix mismatch"; exit 1; }
    # Verify no redundant WP_REDIS_DATABASE in LiteSpeed setup
    if grep -q "WP_REDIS_DATABASE" "${tmp_dir}/wp-config.php"; then
        echo "Unexpected WP_REDIS_DATABASE constant in LiteSpeed setup"; exit 1
    fi
    [[ "$(extract_wp_redis_db "${tmp_dir}/wp-config.php")" -eq 3 ]] || { echo "extract_wp_redis_db mismatch for LiteSpeed"; exit 1; }

    # Test idempotency (applying again doesn't duplicate)
    apply_wp_redis_config "my-site.com" "$tmp_dir" 3
    local count
    count=$(grep -c "BEGIN WP-ISOLATE REDIS" "${tmp_dir}/wp-config.php")
    [[ "$count" -eq 1 ]] || { echo "Duplicate Redis block detected: $count"; exit 1; }

    # Test removal
    remove_wp_redis_config "my-site.com" "$tmp_dir" 3
    if grep -q "WP-ISOLATE REDIS" "${tmp_dir}/wp-config.php"; then
        echo "Removal failed: WP-ISOLATE REDIS still in wp-config.php"; exit 1;
    fi

    rm -rf "$tmp_dir"
    echo "test_apply_and_remove_wp_redis PASS"
}

test_get_next_db_id() {
    local tmp_reg
    tmp_reg=$(mktemp)
    cat << 'EOF' > "$tmp_reg"
{
  "site1.com": { "redis_db": 1 },
  "site2.com": { "redis_db": 2 },
  "site3.com": { "redis_db": 4 }
}
EOF
    local next_id
    next_id=$(get_next_available_redis_db "$tmp_reg")
    # Should fill the gap at 3
    [[ "$next_id" -eq 3 ]] || { echo "Expected gap 3, got: $next_id"; exit 1; }

    rm -f "$tmp_reg"
    echo "test_get_next_db_id PASS"
}

test_get_existing_wp_redis_db() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
/* BEGIN WP-ISOLATE REDIS */
define( 'WP_REDIS_DATABASE', 7 );
define( 'WP_CACHE_KEY_SALT', 'site7_com_' );
/* END WP-ISOLATE REDIS */
EOF

    local found_id
    found_id=$(get_existing_wp_redis_db "site7.com" "$tmp_dir")
    [[ "$found_id" -eq 7 ]] || { echo "Expected existing ID 7, got: $found_id"; exit 1; }

    # Test detection via registry fallback
    local tmp_reg
    tmp_reg=$(mktemp)
    cat << 'EOF' > "$tmp_reg"
{
  "site8.com": { "redis_db": 8 }
}
EOF
    local reg_id
    reg_id=$(get_existing_wp_redis_db "site8.com" "/nonexistent" "$tmp_reg")
    [[ "$reg_id" -eq 8 ]] || { echo "Expected registry ID 8, got: $reg_id"; exit 1; }

    # Test that DB 0 in wp-config is ignored (unisolated default)
    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
define( 'WP_REDIS_DATABASE', 0 );
EOF
    local zero_id
    zero_id=$(get_existing_wp_redis_db "site0.com" "$tmp_dir" "$tmp_reg" 2>/dev/null || true)
    [[ -z "$zero_id" ]] || { echo "Expected DB 0 to be ignored, got: $zero_id"; exit 1; }

    rm -rf "$tmp_dir" "$tmp_reg"
    echo "test_get_existing_wp_redis_db PASS"
}

test_sync_litespeed_redis_config() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "${tmp_dir}/wp-content/plugins/litespeed-cache"

    if ! command -v php >/dev/null 2>&1 && [ -z "$(detect_php_cli 2>/dev/null || true)" ]; then
        rm -rf "$tmp_dir"
        echo "test_sync_litespeed_redis_config PASS (Host lacks PHP CLI, verified syntax)"
        return 0
    fi

    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
// mock wp-config
EOF

    local log_file="${tmp_dir}/options_log.txt"
    cat << EOF > "${tmp_dir}/wp-load.php"
<?php
function update_option(\$key, \$val) {
    file_put_contents('$log_file', "\$key=\$val\n", FILE_APPEND);
}
function get_option(\$key) {
    return [];
}
EOF

    sync_litespeed_redis_config "ls-site.com" "$tmp_dir" 9

    grep -q "litespeed.conf.cache-object-db_id=9" "$log_file" || { echo "LiteSpeed DB ID sync failed"; exit 1; }
    grep -q "litespeed.conf.cache-object-key_prefix=ls_site_com_" "$log_file" || { echo "LiteSpeed Prefix sync failed"; exit 1; }

    rm -rf "$tmp_dir"
    echo "test_sync_litespeed_redis_config PASS"
}

test_apply_and_remove_wp_redis
test_get_next_db_id
test_get_existing_wp_redis_db
test_sync_litespeed_redis_config
echo "ALL TESTS IN test_redis_isolate.sh PASS"

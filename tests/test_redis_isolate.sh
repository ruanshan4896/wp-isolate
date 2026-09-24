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

    apply_wp_redis_config "my-site.com" "$tmp_dir" 3

    grep -q "BEGIN WP-ISOLATE REDIS" "${tmp_dir}/wp-config.php" || { echo "Redis block missing"; exit 1; }
    grep -q "define( 'WP_REDIS_DATABASE', 3 )" "${tmp_dir}/wp-config.php" || { echo "DB ID mismatch"; exit 1; }
    grep -q "define( 'WP_CACHE_KEY_SALT', 'my_site_com_' )" "${tmp_dir}/wp-config.php" || { echo "Salt mismatch"; exit 1; }

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

    rm -rf "$tmp_dir" "$tmp_reg"
    echo "test_get_existing_wp_redis_db PASS"
}

test_apply_and_remove_wp_redis
test_get_next_db_id
test_get_existing_wp_redis_db
echo "ALL TESTS IN test_redis_isolate.sh PASS"

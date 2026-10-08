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
    # Test 2: Test standalone / un-bracketed LSCache and Redis constants
    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
define( 'DB_NAME', 'sample_db' );
define( 'LITESPEED_CONF__OBJECT', true );
define( 'LITESPEED_CONF__OBJECT__DB_ID', 12 );
define( 'WP_REDIS_DATABASE', 12 );
define( 'DB_USER', 'sample_user' );
EOF
    chmod 440 "${tmp_dir}/wp-config.php" 2>/dev/null || true

    purge_legacy_redis_config "purge-test.com" "$tmp_dir"

    if grep -qE "LITESPEED_CONF__OBJECT|WP_REDIS_" "${tmp_dir}/wp-config.php"; then
        echo "Failed to purge standalone constants from wp-config.php"; exit 1
    fi
    grep -q "DB_NAME" "${tmp_dir}/wp-config.php" || { echo "DB_NAME missing"; exit 1; }
    grep -q "DB_USER" "${tmp_dir}/wp-config.php" || { echo "DB_USER missing"; exit 1; }

    rm -rf "$tmp_dir"
    echo "test_purge_legacy_redis_config PASS"
}

test_purge_legacy_redis_config

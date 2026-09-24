#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/mysql_limit.sh"

test_extract_db_user() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
define( 'DB_NAME', 'sample_db' );
define( 'DB_USER', 'site_user_123' );
define( 'DB_PASSWORD', 'secretpass' );
define( 'DB_HOST', 'localhost' );
EOF
    local user
    user=$(extract_wp_db_user "$tmp_dir")
    [[ "$user" == "site_user_123" ]] || { echo "Extracted user mismatch: $user"; exit 1; }

    # Test with double quotes
    cat << 'EOF' > "${tmp_dir}/wp-config.php"
<?php
define("DB_USER", "db_another_456");
EOF
    user=$(extract_wp_db_user "$tmp_dir")
    [[ "$user" == "db_another_456" ]] || { echo "Double quote mismatch: $user"; exit 1; }

    rm -rf "$tmp_dir"
    echo "test_extract_db_user PASS"
}

test_extract_db_user
echo "ALL TESTS IN test_mysql_limit.sh PASS"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_cli_commands() {
    local tmp_base
    tmp_base=$(mktemp -d)

    # Set up mock aaPanel and mock OLS environment
    mkdir -p "${tmp_base}/www/wwwroot/mytest.com"
    mkdir -p "${tmp_base}/www/server/panel/vhost/openlitespeed"
    mkdir -p "${tmp_base}/opt/wp-isolate"
    
    cat << 'EOF' > "${tmp_base}/www/server/panel/vhost/openlitespeed/mytest.com.conf"
docRoot                   /www/wwwroot/mytest.com
vhDomain                  mytest.com
enableGzip                1
EOF

    cat << 'EOF' > "${tmp_base}/www/wwwroot/mytest.com/wp-config.php"
<?php
define( 'DB_NAME', 'test_db' );
define( 'DB_USER', 'test_user' );
define( 'DB_PASSWORD', 'secret' );
EOF

    # Test list command with custom storage
    WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" list >/dev/null

    # Test status command
    local status_out
    status_out=$(WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" status mytest.com)
    echo "$status_out" | grep -q "DEFAULT" || { echo "Expected DEFAULT status before isolation"; exit 1; }

    rm -rf "$tmp_base"
    echo "test_cli_workflow PASS"
}

test_cli_commands

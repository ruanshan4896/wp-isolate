#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

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

    # Test redis injection and list display
    source "${SCRIPT_DIR}/lib/redis_isolate.sh"
    apply_wp_redis_config "mytest.com" "${tmp_base}/www/wwwroot/mytest.com" 2
    local list_out
    list_out=$(AAPANEL_OLS_VHOST_DIR="${tmp_base}/www/server/panel/vhost/openlitespeed" AAPANEL_WWWROOT_DIR="${tmp_base}/www/wwwroot" WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" list)
    echo "$list_out" | grep -q "DB 2" || { echo "Expected DB 2 in list output"; exit 1; }

    rm -rf "$tmp_base"
    echo "test_cli_workflow PASS"
}

test_cli_commands

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
    local list_out
    list_out=$(AAPANEL_OLS_VHOST_DIR="${tmp_base}/www/server/panel/vhost/openlitespeed" AAPANEL_WWWROOT_DIR="${tmp_base}/www/wwwroot" WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" list)
    echo "$list_out" | grep -q "mytest.com" || { echo "Expected mytest.com in list output"; exit 1; }
    echo "$list_out" | grep -q "DEFAULT" || { echo "Expected DEFAULT status in list output"; exit 1; }

    # Test status command
    local status_out
    status_out=$(AAPANEL_OLS_VHOST_DIR="${tmp_base}/www/server/panel/vhost/openlitespeed" AAPANEL_WWWROOT_DIR="${tmp_base}/www/wwwroot" WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" status mytest.com)
    echo "$status_out" | grep -q "DEFAULT" || { echo "Expected DEFAULT status before isolation"; exit 1; }

    # Test legacy Redis block purge via clean command
    cat << 'EOF' >> "${tmp_base}/www/wwwroot/mytest.com/wp-config.php"

/* BEGIN WP-ISOLATE REDIS */
define( 'WP_REDIS_DATABASE', 7 );
/* END WP-ISOLATE REDIS */
EOF
    mkdir -p "${tmp_base}/www/wwwroot/mytest.com/wp-content"
    touch "${tmp_base}/www/wwwroot/mytest.com/wp-content/object-cache.php"
    touch "${tmp_base}/www/wwwroot/mytest.com/wp-content/.litespeed_conf.dat"
    touch "${tmp_base}/www/wwwroot/mytest.com/.user.ini"

    AAPANEL_OLS_VHOST_DIR="${tmp_base}/www/server/panel/vhost/openlitespeed" AAPANEL_WWWROOT_DIR="${tmp_base}/www/wwwroot" WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" clean mytest.com >/dev/null
    
    [ ! -f "${tmp_base}/www/wwwroot/mytest.com/wp-content/object-cache.php" ] || { echo "Clean failed to remove object-cache.php"; exit 1; }
    [ ! -f "${tmp_base}/www/wwwroot/mytest.com/wp-content/.litespeed_conf.dat" ] || { echo "Clean failed to remove .litespeed_conf.dat"; exit 1; }
    [ ! -f "${tmp_base}/www/wwwroot/mytest.com/.user.ini" ] || { echo "Clean failed to remove .user.ini"; exit 1; }
    grep -q "WP-ISOLATE REDIS" "${tmp_base}/www/wwwroot/mytest.com/wp-config.php" && { echo "Clean failed to purge legacy Redis block"; exit 1; } || true

    rm -rf "$tmp_base"
    echo "test_cli_workflow PASS"
}

test_cli_commands

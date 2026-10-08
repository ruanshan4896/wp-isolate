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

    # Set up isolated configuration format (outer setUIDMode 2 + detail extUser & WP-ISOLATE)
    mkdir -p "${tmp_base}/www/server/panel/vhost/openlitespeed/detail"
    cat << 'EOF' > "${tmp_base}/www/server/panel/vhost/openlitespeed/mytest.com.conf"
virtualhost mytest.com {
  setUIDMode 2
}
EOF
    cat << 'EOF' > "${tmp_base}/www/server/panel/vhost/openlitespeed/detail/mytest.com.conf"
extprocessor lsphp81 {
  extUser iso_mytest_com
  extGroup iso_mytest_com
  maxConns 15
}
### BEGIN WP-ISOLATE: mytest.com ###
perClientConnLimit 25
### END WP-ISOLATE: mytest.com ###
EOF

    # Test status command on isolated site
    local status_iso_out
    status_iso_out=$(AAPANEL_OLS_VHOST_DIR="${tmp_base}/www/server/panel/vhost/openlitespeed" AAPANEL_WWWROOT_DIR="${tmp_base}/www/wwwroot" WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" status mytest.com)
    echo "$status_iso_out" | grep -q "Status:              ISOLATED" || { echo "Expected ISOLATED status in status output, got:\n$status_iso_out"; exit 1; }

    # Test verify detects configuration drift
    # Break detail conf by removing WP-ISOLATE
    cat << 'EOF' > "${tmp_base}/www/server/panel/vhost/openlitespeed/detail/mytest.com.conf"
extprocessor lsphp81 {
  extUser iso_mytest_com
}
EOF
    local verify_out
    verify_out=$(AAPANEL_OLS_VHOST_DIR="${tmp_base}/www/server/panel/vhost/openlitespeed" AAPANEL_WWWROOT_DIR="${tmp_base}/www/wwwroot" WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" verify 2>&1 || true)
    echo "$verify_out" | grep -q "Configuration drift detected" || { echo "Expected verify to detect configuration drift, got:\n$verify_out"; exit 1; }

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
    touch "${tmp_base}/www/wwwroot/mytest.com/wp-content/advanced-cache.php"

    AAPANEL_OLS_VHOST_DIR="${tmp_base}/www/server/panel/vhost/openlitespeed" AAPANEL_WWWROOT_DIR="${tmp_base}/www/wwwroot" WP_ISOLATE_DIR="${tmp_base}/opt/wp-isolate" bash "${SCRIPT_DIR}/bin/wp-isolate" clean mytest.com >/dev/null
    
    [ ! -f "${tmp_base}/www/wwwroot/mytest.com/wp-content/object-cache.php" ] || { echo "Clean failed to remove object-cache.php"; exit 1; }
    [ ! -f "${tmp_base}/www/wwwroot/mytest.com/wp-content/.litespeed_conf.dat" ] || { echo "Clean failed to remove .litespeed_conf.dat"; exit 1; }
    # Regression guard: clean must NOT destroy aaPanel's .user.ini or LiteSpeed page cache drop-in
    [ -f "${tmp_base}/www/wwwroot/mytest.com/.user.ini" ] || { echo "Clean must preserve .user.ini"; exit 1; }
    [ -f "${tmp_base}/www/wwwroot/mytest.com/wp-content/advanced-cache.php" ] || { echo "Clean must preserve advanced-cache.php"; exit 1; }
    grep -q "WP-ISOLATE REDIS" "${tmp_base}/www/wwwroot/mytest.com/wp-config.php" && { echo "Clean failed to purge legacy Redis block"; exit 1; } || true

    rm -rf "$tmp_base"
    echo "test_cli_workflow PASS"
}

test_cli_commands

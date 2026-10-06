#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/os_user.sh"
source "${SCRIPT_DIR}/lib/ols_vhost.sh"

test_isolate_and_restore_vhost() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "${tmp_dir}/detail"

    cat << 'EOF' > "${tmp_dir}/demo.com.conf"
virtualhost demo.com {
  setUIDMode 0
}
EOF

    cat << 'EOF' > "${tmp_dir}/detail/demo.com.conf"
  extUser                 www
  extGroup                www
  maxConns                10
EOF

    AAPANEL_OLS_VHOST_DIR="$tmp_dir" isolate_ols_vhost "demo.com" "iso_demo_com" 15 "512M" 10 "/www/wwwroot/demo.com"

    grep -q "setUIDMode 2" "${tmp_dir}/demo.com.conf" || { echo "setUIDMode 2 not configured"; exit 1; }
    grep -q "extUser                 iso_demo_com" "${tmp_dir}/detail/demo.com.conf" || { echo "extUser mismatch"; exit 1; }
    grep -q "maxConns                15" "${tmp_dir}/detail/demo.com.conf" || { echo "maxConns mismatch"; exit 1; }
    grep -q "dynReqPerSec 10" "${tmp_dir}/detail/demo.com.conf" || { echo "dynReqPerSec mismatch"; exit 1; }
    grep -q "wp-content/uploads/.*\.php" "${tmp_dir}/detail/demo.com.conf" || { echo "uploads PHP block rule missing"; exit 1; }
    grep -q "php_value upload_max_filesize 256M" "${tmp_dir}/detail/demo.com.conf" || { echo "upload_max_filesize mismatch"; exit 1; }
    grep -q "php_value max_execution_time 60" "${tmp_dir}/detail/demo.com.conf" || { echo "max_execution_time mismatch"; exit 1; }

    # Test restore
    AAPANEL_OLS_VHOST_DIR="$tmp_dir" restore_ols_vhost "demo.com"
    grep -q "setUIDMode 0" "${tmp_dir}/demo.com.conf" || { echo "setUIDMode 0 restore mismatch"; exit 1; }
    grep -q "extUser                 www" "${tmp_dir}/detail/demo.com.conf" || { echo "extUser restore mismatch"; exit 1; }
    if grep -q "WP-ISOLATE: demo.com" "${tmp_dir}/detail/demo.com.conf"; then
        echo "Restore failed to remove isolate block"; exit 1
    fi

    rm -rf "$tmp_dir"
    echo "test_isolate_and_restore_vhost PASS"
}

test_remove_include() {
    local tmp_vhost
    tmp_vhost=$(mktemp)

    cat << 'EOF' > "$tmp_vhost"
docRoot                   /www/wwwroot/demo.com
vhDomain                  demo.com
### BEGIN WP-ISOLATE: demo.com ###
perClientConnLimit 25
### END WP-ISOLATE: demo.com ###
enableGzip                1
EOF

    remove_ols_include "demo.com" "$tmp_vhost"
    if grep -q "WP-ISOLATE: demo.com" "$tmp_vhost"; then
        echo "Removal failed: WP-ISOLATE still found in vhost"; exit 1
    fi
    grep -q "enableGzip" "$tmp_vhost" || { echo "enableGzip missing after removal"; exit 1; }

    rm -f "$tmp_vhost"
    echo "test_remove_include PASS"
}

test_isolate_real_aapanel_format() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "${tmp_dir}/detail"

    # In aaPanel, virtualhost conf does NOT have setUIDMode 2 initially
    cat << 'EOF' > "${tmp_dir}/sky.net.conf"
virtualhost sky.net {
  docRoot /www/wwwroot/sky.net
}
EOF

    # In aaPanel, detail conf does NOT have extUser or extGroup initially
    cat << 'EOF' > "${tmp_dir}/detail/sky.net.conf"
extprocessor lsphp81 {
  type                    lsapi
  address                 uds://tmp/lshttpd/sky.net.sock
  maxConns                10
  env                     PHP_LSAPI_CHILDREN=10
  initTimeout             60
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      1
  respBuffer              0
}
EOF

    AAPANEL_OLS_VHOST_DIR="$tmp_dir" isolate_ols_vhost "sky.net" "iso_sky_net" 20 "512M" 15 "/www/wwwroot/sky.net"

    grep -q "setUIDMode 2" "${tmp_dir}/sky.net.conf" || { echo "Real aaPanel setUIDMode 2 missing"; exit 1; }
    grep -q "extUser                 iso_sky_net" "${tmp_dir}/detail/sky.net.conf" || { echo "Real aaPanel extUser missing"; exit 1; }
    grep -q "extGroup                iso_sky_net" "${tmp_dir}/detail/sky.net.conf" || { echo "Real aaPanel extGroup missing"; exit 1; }
    grep -q "maxConns                20" "${tmp_dir}/detail/sky.net.conf" || { echo "Real aaPanel maxConns missing"; exit 1; }
    grep -q "memSoftLimit            409M" "${tmp_dir}/detail/sky.net.conf" || { echo "Real aaPanel memSoftLimit missing"; exit 1; }

    # Test restore
    AAPANEL_OLS_VHOST_DIR="$tmp_dir" restore_ols_vhost "sky.net"
    grep -q "setUIDMode 0" "${tmp_dir}/sky.net.conf" || { echo "Restore setUIDMode 0 missing"; exit 1; }
    grep -q "extUser                 www" "${tmp_dir}/detail/sky.net.conf" || { echo "Restore extUser www missing"; exit 1; }
    grep -q "extGroup                www" "${tmp_dir}/detail/sky.net.conf" || { echo "Restore extGroup www missing"; exit 1; }

    rm -rf "$tmp_dir"
    echo "test_isolate_real_aapanel_format PASS"
}

test_isolate_and_restore_vhost
test_isolate_real_aapanel_format
test_remove_include
echo "ALL TESTS IN test_ols_vhost.sh PASS"

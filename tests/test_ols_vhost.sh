#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/os_user.sh"
source "${SCRIPT_DIR}/lib/ols_vhost.sh"

test_render_template() {
    local tmp_out
    tmp_out=$(mktemp)
    render_ols_isolate_template "demo.com" "81" 15 "512M" 10 "$tmp_out" "/tmp/demo.com"
    grep -q "extprocessor lsphp_demo_com" "$tmp_out" || { echo "extprocessor not found"; exit 1; }
    grep -q "extUser                 iso_demo_com" "$tmp_out" || { echo "extUser mismatch"; exit 1; }
    grep -q "perClientConnLimit        25" "$tmp_out" || { echo "conn limit missing"; exit 1; }
    grep -q "dynReqPerSec              10" "$tmp_out" || { echo "dynReqPerSec mismatch"; exit 1; }
    rm -f "$tmp_out"
    echo "test_render_template PASS"
}

test_inject_and_remove_include() {
    local tmp_vhost
    local tmp_isolate
    tmp_vhost=$(mktemp)
    tmp_isolate="/opt/wp-isolate/vhosts/demo.com/ols_isolate.conf"
    
    cat << 'EOF' > "$tmp_vhost"
docRoot                   /www/wwwroot/demo.com
vhDomain                  demo.com
enableGzip                1
EOF

    inject_ols_include "demo.com" "$tmp_vhost" "$tmp_isolate"
    grep -q "### BEGIN WP-ISOLATE: demo.com ###" "$tmp_vhost" || { echo "Include block not injected"; exit 1; }
    grep -q "include $tmp_isolate" "$tmp_vhost" || { echo "Include file path not found"; exit 1; }

    # Test idempotency (injecting twice does not duplicate)
    inject_ols_include "demo.com" "$tmp_vhost" "$tmp_isolate"
    local count
    count=$(grep -c "BEGIN WP-ISOLATE: demo.com" "$tmp_vhost")
    [[ "$count" -eq 1 ]] || { echo "Duplicate include detected: $count"; exit 1; }

    # Test removal
    remove_ols_include "demo.com" "$tmp_vhost"
    if grep -q "WP-ISOLATE: demo.com" "$tmp_vhost"; then
        echo "Removal failed: WP-ISOLATE still found in vhost"; exit 1;
    fi

    rm -f "$tmp_vhost"
    echo "test_inject_and_remove_include PASS"
}

test_render_template
test_inject_and_remove_include
echo "ALL TESTS IN test_ols_vhost.sh PASS"

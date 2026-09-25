#!/usr/bin/env bash
# lib/ols_vhost.sh - OpenLiteSpeed VirtualHost and LSAPI suEXEC configuration module

detect_ols_vhost_file() {
    local domain="$1"
    local vhost_panel_dir="${AAPANEL_OLS_VHOST_DIR:-/www/server/panel/vhost/openlitespeed}"
    local candidates=(
        "${vhost_panel_dir}/${domain}.conf"
        "${vhost_panel_dir}/detail/${domain}.conf"
        "/usr/local/lsws/conf/vhosts/${domain}/vhconf.conf"
    )
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

detect_vhost_docroot() {
    local domain="$1"
    local vhost_file="${2:-}"
    local wwwroot_dir="${AAPANEL_WWWROOT_DIR:-/www/wwwroot}"
    if [ -z "$vhost_file" ]; then
        vhost_file=$(detect_ols_vhost_file "$domain" 2>/dev/null || true)
    fi

    if [ -n "$vhost_file" ] && [ -f "$vhost_file" ]; then
        local detected
        detected=$(grep -E "^\s*docRoot\s+" "$vhost_file" | awk '{print $2}' | head -n 1 || true)
        if [ -n "$detected" ] && [ -d "$detected" ]; then
            echo "$detected"
            return 0
        fi
    fi

    if [ -d "${wwwroot_dir}/${domain}" ]; then
        echo "${wwwroot_dir}/${domain}"
        return 0
    fi
    return 1
}

detect_php_version() {
    local domain="$1"
    local candidates=(
        "/www/server/panel/vhost/openlitespeed/detail/${domain}.conf"
        "/www/server/panel/vhost/openlitespeed/${domain}.conf"
        "/usr/local/lsws/conf/vhosts/${domain}/vhconf.conf"
    )
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            local ver
            ver=$(grep -oE "lsphp[0-9]{2}" "$f" | head -n 1 | sed 's/lsphp//' || true)
            if [ -n "$ver" ]; then
                echo "$ver"
                return 0
            fi
        fi
    done

    # Fallback to checking installed lsphp binaries in /usr/local/lsws/
    for v in 84 83 82 81 80 74 73 72 71 70; do
        if [ -x "/usr/local/lsws/lsphp${v}/bin/lsphp" ]; then
            echo "$v"
            return 0
        fi
    done
    echo "81" # Default fallback
}
remove_ols_include() {
    local domain="$1"
    local vhost_file="$2"

    if [ ! -f "$vhost_file" ]; then
        return 0
    fi

    # Remove block between markers
    sed_i "/### BEGIN WP-ISOLATE: ${domain} ###/,/### END WP-ISOLATE: ${domain} ###/d" "$vhost_file"
    log_info "Removed WP-ISOLATE include block from $vhost_file."
}

isolate_ols_vhost() {
    local domain="$1"
    local user="$2"
    local max_conns="${3:-15}"
    local mem_limit="${4:-512M}"
    local req_limit="${5:-10}"
    local docroot="${6:-/www/wwwroot/${domain}}"
    local vhost_dir="${AAPANEL_OLS_VHOST_DIR:-/www/server/panel/vhost/openlitespeed}"
    local outer_file="${vhost_dir}/${domain}.conf"
    local detail_file="${vhost_dir}/detail/${domain}.conf"

    # Memory and process limits
    local mem_num="${mem_limit%M}"
    local mem_soft="$((mem_num * 80 / 100))M"
    local mem_hard="${mem_limit}"
    local proc_soft="$((max_conns + 5))"
    local proc_hard="$((max_conns * 2))"

    # 1. Update outer file to enable suEXEC (setUIDMode 2)
    if [ -f "$outer_file" ]; then
        if grep -q "setUIDMode" "$outer_file"; then
            sed_i -E "s/setUIDMode[[:space:]]+[0-9]+/setUIDMode 2/" "$outer_file"
        else
            sed_i "/virtualhost[[:space:]]\+${domain}[[:space:]]\+{/a\\
setUIDMode 2" "$outer_file" 2>/dev/null || true
        fi
        log_info "Configured suEXEC (setUIDMode 2) in $outer_file"
    fi

    # 2. Update detail file (where aaPanel defines extprocessor)
    if [ -f "$detail_file" ]; then
        sed_i -E "s/^[[:space:]]*extUser[[:space:]]+.*/  extUser                 ${user}/" "$detail_file"
        sed_i -E "s/^[[:space:]]*extGroup[[:space:]]+.*/  extGroup                ${user}/" "$detail_file"
        sed_i -E "s/^[[:space:]]*maxConns[[:space:]]+[0-9]+/  maxConns                ${max_conns}/" "$detail_file"
        sed_i -E "s/^[[:space:]]*memSoftLimit[[:space:]]+[0-9]+M?/  memSoftLimit            ${mem_soft}/" "$detail_file"
        sed_i -E "s/^[[:space:]]*memHardLimit[[:space:]]+[0-9]+M?/  memHardLimit            ${mem_hard}/" "$detail_file"
        sed_i -E "s/^[[:space:]]*procSoftLimit[[:space:]]+[0-9]+/  procSoftLimit           ${proc_soft}/" "$detail_file"
        sed_i -E "s/^[[:space:]]*procHardLimit[[:space:]]+[0-9]+/  procHardLimit           ${proc_hard}/" "$detail_file"

        # Append Throttling Block
        remove_ols_include "$domain" "$detail_file"
        cat << EOF >> "$detail_file"

### BEGIN WP-ISOLATE: ${domain} ###
perClientConnLimit 25
dynReqPerSec ${req_limit}
outBandwidth 0
inBandwidth 0
blockBadReq 1

phpIniOverride {
  php_value open_basedir "${docroot}/:/tmp/:/dev/urandom"
  php_value session.save_path "/tmp"
  php_value upload_tmp_dir "/tmp"
  php_value max_execution_time 300
  php_value upload_max_filesize 256M
  php_value post_max_size 256M
}
### END WP-ISOLATE: ${domain} ###
EOF
        log_success "Configured suEXEC user and resource limits in $detail_file."
    fi

    # 3. Clean any legacy include from outer_file
    if [ -f "$outer_file" ]; then
        remove_ols_include "$domain" "$outer_file"
    fi
}

restore_ols_vhost() {
    local domain="$1"
    local vhost_dir="${AAPANEL_OLS_VHOST_DIR:-/www/server/panel/vhost/openlitespeed}"
    local outer_file="${vhost_dir}/${domain}.conf"
    local detail_file="${vhost_dir}/detail/${domain}.conf"

    if [ -f "$outer_file" ]; then
        sed_i -E "s/setUIDMode[[:space:]]+[0-9]+/setUIDMode 0/" "$outer_file"
        remove_ols_include "$domain" "$outer_file"
    fi

    if [ -f "$detail_file" ]; then
        sed_i -E "s/^[[:space:]]*extUser[[:space:]]+.*/  extUser                 www/" "$detail_file"
        sed_i -E "s/^[[:space:]]*extGroup[[:space:]]+.*/  extGroup                www/" "$detail_file"
        remove_ols_include "$domain" "$detail_file"
    fi
}

verify_and_reload_ols() {
    log_info "Verifying OpenLiteSpeed configuration syntax..."
    local test_bin=""
    for b in "/usr/local/lsws/bin/openlitespeed" "/usr/local/lsws/bin/lshttpd"; do
        if [ -x "$b" ]; then
            test_bin="$b"
            break
        fi
    done

    if [ -n "$test_bin" ]; then
        "$test_bin" -t >/tmp/ols_test.log 2>&1 || true
        if grep -qE "\[ERROR\]|\[FATAL\]" /tmp/ols_test.log; then
            log_error "OpenLiteSpeed syntax check failed! Check details in /tmp/ols_test.log"
            cat /tmp/ols_test.log >&2
            return 1
        fi
        log_success "OpenLiteSpeed configuration syntax is OK."
    fi

    log_info "Reloading OpenLiteSpeed gracefully..."
    touch /tmp/lshttpd/.rtreport 2>/dev/null || true
    if [ -x "/usr/local/lsws/bin/lswsctrl" ]; then
        /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || /usr/local/lsws/bin/lswsctrl reload >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart lsws 2>/dev/null || systemctl reload lsws 2>/dev/null || true
    fi
    # Terminate any old www workers so new workers spawn under the isolated user
    pkill -u www -f lsphp 2>/dev/null || true
    log_success "OpenLiteSpeed reloaded."
    return 0
}

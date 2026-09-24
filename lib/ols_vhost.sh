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

detect_lsphp_executable() {
    local requested_ver="$1"

    # 1. Check exact requested version
    if [ -x "/usr/local/lsws/lsphp${requested_ver}/bin/lsphp" ]; then
        echo "/usr/local/lsws/lsphp${requested_ver}/bin/lsphp"
        return 0
    fi

    # 2. Check any other installed version in /usr/local/lsws/
    for v in 84 83 82 81 80 74 73 72 71 70; do
        if [ -x "/usr/local/lsws/lsphp${v}/bin/lsphp" ]; then
            echo "/usr/local/lsws/lsphp${v}/bin/lsphp"
            return 0
        fi
    done

    # 3. Check fcgi-bin
    for f in /usr/local/lsws/fcgi-bin/lsphp*; do
        if [ -x "$f" ]; then
            echo "$f"
            return 0
        fi
    done

    # 4. Check aaPanel PHP paths
    for p in /www/server/php/*/bin/php; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done

    # Fallback default
    echo "/usr/local/lsws/lsphp${requested_ver}/bin/lsphp"
}

render_ols_isolate_template() {
    local domain="$1"
    local php_ver="$2"
    local max_conns="${3:-15}"
    local mem_limit="${4:-512M}"
    local req_limit="${5:-10}"
    local output_file="$6"
    local docroot="${7:-/www/wwwroot/${domain}}"

    local template_file="${SCRIPT_DIR}/templates/ols_isolate.conf.tpl"
    if [ ! -f "$template_file" ]; then
        template_file="/opt/wp-isolate/templates/ols_isolate.conf.tpl"
    fi

    if [ ! -f "$template_file" ]; then
        log_error "Template file not found at $template_file"
        return 1
    fi

    local clean_domain
    clean_domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    local user
    user=$(get_site_user "$domain")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    # Memory limits
    local mem_num="${mem_limit%M}"
    local mem_soft="$((mem_num * 80 / 100))M"
    local mem_hard="${mem_limit}"

    # Process limits
    local proc_soft="$((max_conns + 5))"
    local proc_hard="$((max_conns * 2))"

    local lsphp_path
    lsphp_path=$(detect_lsphp_executable "$php_ver")

    mkdir -p "$(dirname "$output_file")"

    sed \
        -e "s|{{DOMAIN}}|${domain}|g" \
        -e "s|{{DOMAIN_CLEAN}}|${clean_domain}|g" \
        -e "s|{{USER}}|${user}|g" \
        -e "s|{{DOCROOT}}|${docroot}|g" \
        -e "s|{{LSPHP_PATH}}|${lsphp_path}|g" \
        -e "s|{{MAX_CONNS}}|${max_conns}|g" \
        -e "s|{{MEM_SOFT_LIMIT}}|${mem_soft}|g" \
        -e "s|{{MEM_HARD_LIMIT}}|${mem_hard}|g" \
        -e "s|{{PROC_SOFT_LIMIT}}|${proc_soft}|g" \
        -e "s|{{PROC_HARD_LIMIT}}|${proc_hard}|g" \
        -e "s|{{PER_CLIENT_CONN_LIMIT}}|25|g" \
        -e "s|{{DYN_REQ_PER_SEC}}|${req_limit}|g" \
        -e "s|{{TIMESTAMP}}|${timestamp}|g" \
        "$template_file" > "$output_file"

    log_success "Generated isolated OLS config at $output_file"
}

inject_ols_include() {
    local domain="$1"
    local vhost_file="$2"
    local isolate_conf_file="$3"

    if [ ! -f "$vhost_file" ]; then
        log_error "VHost file $vhost_file not found."
        return 1
    fi

    # Clean existing block if already present (idempotent)
    remove_ols_include "$domain" "$vhost_file"

    log_info "Injecting include into $vhost_file..."
    cat << EOF >> "$vhost_file"

### BEGIN WP-ISOLATE: ${domain} ###
include ${isolate_conf_file}
### END WP-ISOLATE: ${domain} ###
EOF
    log_success "Include successfully injected into $vhost_file."
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

    local outer_file="/www/server/panel/vhost/openlitespeed/${domain}.conf"
    local detail_file="/www/server/panel/vhost/openlitespeed/detail/${domain}.conf"

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
    local outer_file="/www/server/panel/vhost/openlitespeed/${domain}.conf"
    local detail_file="/www/server/panel/vhost/openlitespeed/detail/${domain}.conf"

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

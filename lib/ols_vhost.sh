#!/usr/bin/env bash
# lib/ols_vhost.sh - OpenLiteSpeed VirtualHost and LSAPI suEXEC configuration module

detect_ols_vhost_file() {
    local domain="$1"
    local candidates=(
        "/www/server/panel/vhost/openlitespeed/${domain}.conf"
        "/www/server/panel/vhost/openlitespeed/detail/${domain}.conf"
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

detect_php_version() {
    local domain="$1"
    local vhost_file
    vhost_file=$(detect_ols_vhost_file "$domain" 2>/dev/null || true)
    
    if [ -n "$vhost_file" ] && [ -f "$vhost_file" ]; then
        # Check for lsphp reference (e.g. lsphp81, lsphp82, lsphp74)
        local ver
        ver=$(grep -oE "lsphp[0-9]{2}" "$vhost_file" | head -n 1 | sed 's/lsphp//')
        if [ -n "$ver" ]; then
            echo "$ver"
            return 0
        fi
    fi

    # Fallback to checking installed lsphp binaries in /usr/local/lsws/
    for v in 83 82 81 80 74; do
        if [ -x "/usr/local/lsws/lsphp${v}/bin/lsphp" ]; then
            echo "$v"
            return 0
        fi
    done
    echo "81" # Default fallback
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

    local lsphp_path="/usr/local/lsws/lsphp${php_ver}/bin/lsphp"

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
    sed -i "/### BEGIN WP-ISOLATE: ${domain} ###/,/### END WP-ISOLATE: ${domain} ###/d" "$vhost_file"
    log_info "Removed WP-ISOLATE include block from $vhost_file."
}

verify_and_reload_ols() {
    log_info "Verifying OpenLiteSpeed configuration syntax..."
    local test_bin="/usr/local/lsws/bin/lswsctrl"
    
    if [ -x "$test_bin" ]; then
        if ! "$test_bin" test >/tmp/ols_test.log 2>&1; then
            log_error "OpenLiteSpeed syntax check failed! Check details in /tmp/ols_test.log"
            cat /tmp/ols_test.log >&2
            return 1
        fi
        log_success "OpenLiteSpeed configuration syntax is OK."
        log_info "Reloading OpenLiteSpeed gracefully..."
        touch /tmp/lshttpd/.rtreport 2>/dev/null || true
        systemctl reload lsws 2>/dev/null || "$test_bin" restart >/dev/null 2>&1 || true
        log_success "OpenLiteSpeed reloaded."
    else
        log_warn "OpenLiteSpeed binary not found at $test_bin (dry-run or non-standard install)."
    fi
    return 0
}

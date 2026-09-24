#!/usr/bin/env bash
# lib/redis_isolate.sh - Automatic Redis Cache and Database ID isolation for wp-isolate

if ! command -v log_info >/dev/null 2>&1; then
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

if ! command -v sanitize_domain_to_user >/dev/null 2>&1; then
    sanitize_domain_to_user() {
        local domain="$1"
        local clean
        clean=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
        clean="${clean:0:28}"
        echo "iso_${clean}"
    }
fi

find_redis_conf() {
    local candidates=(
        "/www/server/redis/redis.conf"
        "/etc/redis/redis.conf"
        "/etc/redis.conf"
        "/usr/local/etc/redis.conf"
    )
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

is_redis_available() {
    if command -v redis-cli >/dev/null 2>&1 || [ -n "$(find_redis_conf 2>/dev/null || true)" ]; then
        return 0
    fi
    return 1
}

ensure_redis_databases() {
    local target_dbs="${1:-64}"
    local conf
    conf=$(find_redis_conf 2>/dev/null || true)

    if [ -n "$conf" ] && [ -f "$conf" ]; then
        local current
        current=$(grep -E "^\s*databases\s+[0-9]+" "$conf" | awk '{print $2}' | head -n 1 || echo "16")
        if [ -z "$current" ] || [ "$current" -lt "$target_dbs" ]; then
            log_info "Increasing Redis databases from ${current:-16} to ${target_dbs} in $conf..."
            if grep -qE "^\s*databases\s+" "$conf"; then
                sed -i -E "s/^\s*databases\s+[0-9]+/databases ${target_dbs}/" "$conf"
            else
                echo -e "\ndatabases ${target_dbs}" >> "$conf"
            fi
            
            # Apply dynamically to running instance if redis-cli works
            redis-cli config set databases "$target_dbs" >/dev/null 2>&1 || true

            # Reload service
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null || true
            elif [ -x "/etc/init.d/redis" ]; then
                /etc/init.d/redis restart >/dev/null 2>&1 || true
            fi
            log_success "Redis databases updated to ${target_dbs}."
        fi
    fi
}

get_next_available_redis_db() {
    local registry="${1:-/opt/wp-isolate/data/sites.json}"
    local used_ids=()

    # Read used IDs from registry JSON
    if [ -f "$registry" ]; then
        while read -r num; do
            [ -n "$num" ] && used_ids+=("$num")
        done < <(grep -oE '"redis_db":\s*[0-9]+' "$registry" | awk -F: '{print $2}' | tr -d ' ' || true)
    fi

    # Also scan /www/wwwroot/*/wp-config.php to avoid collision with manual setups
    if [ -d "/www/wwwroot" ]; then
        for cfg in /www/wwwroot/*/wp-config.php; do
            [ -f "$cfg" ] || continue
            local val
            val=$(grep -E "define\s*\(\s*['\"]WP_REDIS_DATABASE['\"]\s*,\s*[0-9]+" "$cfg" 2>/dev/null \
                  | sed -E "s/.*WP_REDIS_DATABASE['\"]\s*,\s*([0-9]+).*/\1/" | head -n 1 || true)
            if [ -n "$val" ]; then
                used_ids+=("$val")
            fi
        done
    fi

    # Find first available positive integer starting from 1
    local candidate=1
    while true; do
        local found=false
        for u in "${used_ids[@]}"; do
            if [ "$u" -eq "$candidate" ]; then
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            echo "$candidate"
            return 0
        fi
        candidate=$((candidate + 1))
    done
}

apply_wp_redis_config() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local db_id="$3"
    local wp_config="$docroot/wp-config.php"

    if [ ! -f "$wp_config" ]; then
        return 0
    fi

    local clean_prefix
    clean_prefix=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    clean_prefix="${clean_prefix}_"

    log_info "Configuring Redis cache isolation for $domain (DB ID: $db_id, Prefix: $clean_prefix)..."

    # Remove any existing WP-ISOLATE REDIS block
    remove_wp_redis_config "$domain" "$docroot" "$db_id"

    # Handle immutable .user.ini / permissions if needed
    local is_readonly=false
    if [ ! -w "$wp_config" ]; then
        chmod 640 "$wp_config" 2>/dev/null || true
    fi

    # Inject right after <?php line
    local block
    block=$(cat << EOF

/* BEGIN WP-ISOLATE REDIS */
if ( ! defined( 'WP_REDIS_DATABASE' ) ) {
    define( 'WP_REDIS_DATABASE', ${db_id} );
}
if ( ! defined( 'WP_CACHE_KEY_SALT' ) ) {
    define( 'WP_CACHE_KEY_SALT', '${clean_prefix}' );
}
/* END WP-ISOLATE REDIS */
EOF
)

    awk -v b="$block" '
        NR == 1 {
            print
            print b
            next
        }
        { print }
    ' "$wp_config" > "${wp_config}.tmp" && mv "${wp_config}.tmp" "$wp_config"

    # Maintain permissions
    local user
    if command -v get_site_user >/dev/null 2>&1; then
        user=$(get_site_user "$domain")
    else
        user=$(sanitize_domain_to_user "$domain")
    fi
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        chown "${user}:${user}" "$wp_config" 2>/dev/null || true
    fi
    chmod 640 "$wp_config" 2>/dev/null || true
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:www:0 "$wp_config" 2>/dev/null || true
    fi

    log_success "Redis cache configuration injected into $wp_config."
}

remove_wp_redis_config() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local db_id="${3:-}"
    local wp_config="$docroot/wp-config.php"

    if [ -f "$wp_config" ]; then
        sed -i '/\/\* BEGIN WP-ISOLATE REDIS \*\//,/\/\* END WP-ISOLATE REDIS \*\//d' "$wp_config"
        local user
        if command -v get_site_user >/dev/null 2>&1; then
            user=$(get_site_user "$domain")
        else
            user=$(sanitize_domain_to_user "$domain")
        fi
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            chown "${user}:${user}" "$wp_config" 2>/dev/null || true
        fi
    fi

    # Flush that database in Redis
    if [ -n "$db_id" ] && command -v redis-cli >/dev/null 2>&1; then
        log_info "Flushing Redis cache for Database ID: $db_id..."
        redis-cli -n "$db_id" FLUSHDB >/dev/null 2>&1 || true
    fi
}

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
        current=$(grep -E "^[[:space:]]*databases[[:space:]]+[0-9]+" "$conf" | awk '{print $2}' | head -n 1 || echo "16")
        if [ -z "$current" ] || [ "$current" -lt "$target_dbs" ]; then
            log_info "Increasing Redis databases from ${current:-16} to ${target_dbs} in $conf..."
            if grep -qE "^[[:space:]]*databases[[:space:]]+" "$conf"; then
                sed_i -E "s/^[[:space:]]*databases[[:space:]]+[0-9]+/databases ${target_dbs}/" "$conf"
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

get_existing_wp_redis_db() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local registry="${3:-/opt/wp-isolate/data/sites.json}"
    local wp_config="$docroot/wp-config.php"

    # 1. Check existing WP_REDIS_DATABASE in wp-config.php
    if [ -f "$wp_config" ]; then
        local val
        val=$(grep -E "define[[:space:]]*\([[:space:]]*['\"]WP_REDIS_DATABASE['\"][[:space:]]*,[[:space:]]*[0-9]+" "$wp_config" 2>/dev/null \
              | sed -E "s/.*WP_REDIS_DATABASE['\"][[:space:]]*,[[:space:]]*([0-9]+).*/\1/" | head -n 1 || true)
        if [ -n "$val" ] && [[ "$val" =~ ^[0-9]+$ ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 2. Check existing record in sites.json registry
    if [ -f "$registry" ] && command -v python3 >/dev/null 2>&1; then
        local reg_val
        reg_val=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r') as f:
        data = json.load(f)
    val = data.get(sys.argv[2], {}).get('redis_db', '')
    if val != '' and val is not None:
        print(val)
except Exception:
    pass
" "$registry" "$domain" 2>/dev/null || true)
        if [ -n "$reg_val" ] && [[ "$reg_val" =~ ^[0-9]+$ ]]; then
            echo "$reg_val"
            return 0
        fi
    fi

    return 1
}

get_next_available_redis_db() {
    local registry="${1:-/opt/wp-isolate/data/sites.json}"
    local exclude_domain="${2:-}"
    local used_ids=()

    # Read used IDs from registry JSON (excluding exclude_domain if provided)
    if [ -f "$registry" ]; then
        if [ -n "$exclude_domain" ] && command -v python3 >/dev/null 2>&1; then
            while read -r num; do
                [ -n "$num" ] && used_ids+=("$num")
            done < <(python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r') as f:
        data = json.load(f)
    ex = sys.argv[2]
    for d, info in data.items():
        if d != ex and isinstance(info, dict) and 'redis_db' in info:
            r = str(info['redis_db'])
            if r.isdigit():
                print(r)
except Exception:
    pass
" "$registry" "$exclude_domain" 2>/dev/null || true)
        else
            while read -r num; do
                [ -n "$num" ] && used_ids+=("$num")
            done < <(grep -oE '"redis_db":\s*[0-9]+' "$registry" | awk -F: '{print $2}' | tr -d ' ' || true)
        fi
    fi

    # Also scan /www/wwwroot/*/wp-config.php to avoid collision with manual setups
    if [ -d "/www/wwwroot" ]; then
        for cfg in /www/wwwroot/*/wp-config.php; do
            [ -f "$cfg" ] || continue
            if [ -n "$exclude_domain" ] && [[ "$cfg" == *"/www/wwwroot/${exclude_domain}/"* ]]; then
                continue
            fi
            local val
            val=$(grep -E "define[[:space:]]*\([[:space:]]*['\"]WP_REDIS_DATABASE['\"][[:space:]]*,[[:space:]]*[0-9]+" "$cfg" 2>/dev/null \
                  | sed -E "s/.*WP_REDIS_DATABASE['\"][[:space:]]*,[[:space:]]*([0-9]+).*/\1/" | head -n 1 || true)
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

    # If the domain previously had a different DB ID, flush that obsolete DB to prevent orphan cache in Redis
    local old_db=""
    old_db=$(grep -E "define[[:space:]]*\([[:space:]]*['\"]WP_REDIS_DATABASE['\"][[:space:]]*,[[:space:]]*[0-9]+" "$wp_config" 2>/dev/null \
             | sed -E "s/.*WP_REDIS_DATABASE['\"][[:space:]]*,[[:space:]]*([0-9]+).*/\1/" | head -n 1 || true)
    if [ -n "$old_db" ] && [ "$old_db" != "$db_id" ] && command -v redis-cli >/dev/null 2>&1; then
        log_info "Flushing obsolete Redis cache from previous Database ID: $old_db..."
        redis-cli -n "$old_db" FLUSHDB >/dev/null 2>&1 || true
    fi

    # Remove any existing WP-ISOLATE REDIS block from file (pass empty db_id so it doesn't wipe active cache)
    remove_wp_redis_config "$domain" "$docroot" ""

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

    # Inject right after first line
    {
        head -n 1 "$wp_config"
        printf "%s\n" "$block"
        tail -n +2 "$wp_config"
    } > "${wp_config}.tmp" && mv "${wp_config}.tmp" "$wp_config"

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

    # Automatically synchronize Database ID & settings to LiteSpeed Cache plugin if installed
    sync_litespeed_redis_config "$domain" "$docroot" "$db_id"
}

detect_php_cli() {
    if command -v php >/dev/null 2>&1; then
        echo "php"
        return 0
    fi
    for p in /usr/bin/php /usr/local/bin/php /www/server/php/*/bin/php /usr/local/lsws/lsphp*/bin/lsphp /usr/local/lsws/lsphp*/bin/php; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

sync_litespeed_redis_config() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local db_id="$3"
    local wp_config="$docroot/wp-config.php"

    if [ ! -f "$wp_config" ]; then
        return 0
    fi

    # Check if LiteSpeed Cache plugin exists in docroot
    local lscache_dir="$docroot/wp-content/plugins/litespeed-cache"
    if [ ! -d "$lscache_dir" ]; then
        return 0
    fi

    local clean_prefix
    clean_prefix=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    clean_prefix="${clean_prefix}_"

    log_info "Synchronizing Redis Database ID ($db_id) to LiteSpeed Cache plugin for $domain..."

    local synced=false

    # Method 1: Check WP-CLI if available
    local wp_cli=""
    if command -v wp >/dev/null 2>&1; then
        wp_cli="wp"
    elif [ -x "/usr/local/bin/wp" ]; then
        wp_cli="/usr/local/bin/wp"
    elif [ -x "/usr/bin/wp" ]; then
        wp_cli="/usr/bin/wp"
    fi

    if [ -n "$wp_cli" ]; then
        if "$wp_cli" core is-installed --path="$docroot" --allow-root >/dev/null 2>&1; then
            "$wp_cli" litespeed-option set cache-object 1 --path="$docroot" --allow-root >/dev/null 2>&1 || true
            "$wp_cli" litespeed-option set cache-object-kind 2 --path="$docroot" --allow-root >/dev/null 2>&1 || true
            "$wp_cli" litespeed-option set cache-object-host 127.0.0.1 --path="$docroot" --allow-root >/dev/null 2>&1 || true
            "$wp_cli" litespeed-option set cache-object-port 6379 --path="$docroot" --allow-root >/dev/null 2>&1 || true
            "$wp_cli" litespeed-option set cache-object-db_id "$db_id" --path="$docroot" --allow-root >/dev/null 2>&1 || true
            "$wp_cli" litespeed-option set cache-object-key_prefix "$clean_prefix" --path="$docroot" --allow-root >/dev/null 2>&1 || true
            synced=true
        fi
    fi

    # Method 2: Bootstrapped PHP execution via WordPress core (works independently of WP-CLI)
    local php_bin
    php_bin=$(detect_php_cli 2>/dev/null || true)
    if [ -n "$php_bin" ]; then
        $php_bin -d error_reporting=0 -r "
define('WP_USE_THEMES', false);
define('DOING_CRON', true);
if (file_exists('$wp_config')) {
    require_once '$docroot/wp-load.php';
    if (function_exists('update_option')) {
        update_option('litespeed.conf.cache-object', 1);
        update_option('litespeed.conf.cache-object-kind', 2);
        update_option('litespeed.conf.cache-object-host', '127.0.0.1');
        update_option('litespeed.conf.cache-object-port', 6379);
        update_option('litespeed.conf.cache-object-db_id', $db_id);
        update_option('litespeed.conf.cache-object-key_prefix', '$clean_prefix');

        \$conf = get_option('litespeed-conf');
        if (is_array(\$conf)) {
            \$conf['cache-object'] = 1;
            \$conf['cache-object-kind'] = 2;
            \$conf['cache-object-host'] = '127.0.0.1';
            \$conf['cache-object-port'] = 6379;
            \$conf['cache-object-db_id'] = $db_id;
            \$conf['cache-object-key_prefix'] = '$clean_prefix';
            update_option('litespeed-conf', \$conf);
        }

        if (class_exists('LiteSpeed\Conf') && method_exists('LiteSpeed\Conf', 'get_instance')) {
            try {
                \LiteSpeed\Conf::get_instance()->update_confs([
                    'cache-object' => 1,
                    'cache-object-kind' => 2,
                    'cache-object-host' => '127.0.0.1',
                    'cache-object-port' => 6379,
                    'cache-object-db_id' => $db_id,
                    'cache-object-key_prefix' => '$clean_prefix',
                ]);
            } catch (Exception \$e) {}
        }
    }
}
" 2>/dev/null || true
        synced=true
    fi

    if [ "$synced" = true ]; then
        log_success "LiteSpeed Cache synchronized: Object Cache enabled on Redis DB $db_id (Prefix: $clean_prefix)."
    fi
}

remove_wp_redis_config() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local db_id="${3:-}"
    local wp_config="$docroot/wp-config.php"

    if [ -f "$wp_config" ]; then
        sed_i '/\/\* BEGIN WP-ISOLATE REDIS \*\//,/\/\* END WP-ISOLATE REDIS \*\//d' "$wp_config"
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

    # Reset LiteSpeed Cache options if installed
    if [ -d "$docroot/wp-content/plugins/litespeed-cache" ]; then
        local php_bin
        php_bin=$(detect_php_cli 2>/dev/null || true)
        if [ -n "$php_bin" ]; then
            $php_bin -d error_reporting=0 -r "
define('WP_USE_THEMES', false);
define('DOING_CRON', true);
if (file_exists('$wp_config')) {
    require_once '$docroot/wp-load.php';
    if (function_exists('update_option')) {
        update_option('litespeed.conf.cache-object-db_id', 0);
        update_option('litespeed.conf.cache-object-key_prefix', '');
    }
}
" 2>/dev/null || true
        fi
    fi

    # Flush that database in Redis
    if [ -n "$db_id" ] && command -v redis-cli >/dev/null 2>&1; then
        log_info "Flushing Redis cache for Database ID: $db_id..."
        redis-cli -n "$db_id" FLUSHDB >/dev/null 2>&1 || true
    fi
}

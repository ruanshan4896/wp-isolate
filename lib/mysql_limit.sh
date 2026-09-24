#!/usr/bin/env bash
# lib/mysql_limit.sh - MySQL database concurrency isolation for wp-isolate

extract_wp_db_user() {
    local docroot="$1"
    local wp_config="$docroot/wp-config.php"
    if [ ! -f "$wp_config" ]; then
        return 1
    fi
    grep -E "define\s*\(\s*['\"]DB_USER['\"]\s*,\s*['\"][^'\"]+['\"]\s*\)" "$wp_config" 2>/dev/null \
        | sed -E "s/.*['\"]DB_USER['\"]\s*,\s*['\"]([^'\"]+)['\"].*/\1/" \
        | head -n 1
}

set_mysql_user_limit() {
    local db_user="$1"
    local max_conns="${2:-25}"

    if [ -z "$db_user" ]; then
        return 0
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        log_warn "mysql client command not available. Skipping database connection limit."
        return 0
    fi

    log_info "Configuring MySQL MAX_USER_CONNECTIONS=$max_conns for database user: $db_user..."
    mysql -e "ALTER USER '${db_user}'@'localhost' WITH MAX_USER_CONNECTIONS ${max_conns};" 2>/dev/null || true
    mysql -e "ALTER USER '${db_user}'@'127.0.0.1' WITH MAX_USER_CONNECTIONS ${max_conns};" 2>/dev/null || true
    mysql -e "ALTER USER '${db_user}'@'%' WITH MAX_USER_CONNECTIONS ${max_conns};" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_success "MySQL user limits updated for $db_user."
}

remove_mysql_user_limit() {
    local db_user="$1"
    if [ -z "$db_user" ]; then
        return 0
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        return 0
    fi

    log_info "Resetting MySQL MAX_USER_CONNECTIONS for database user: $db_user..."
    mysql -e "ALTER USER '${db_user}'@'localhost' WITH MAX_USER_CONNECTIONS 0;" 2>/dev/null || true
    mysql -e "ALTER USER '${db_user}'@'127.0.0.1' WITH MAX_USER_CONNECTIONS 0;" 2>/dev/null || true
    mysql -e "ALTER USER '${db_user}'@'%' WITH MAX_USER_CONNECTIONS 0;" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_success "MySQL user limits reset for $db_user."
}

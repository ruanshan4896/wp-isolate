#!/usr/bin/env bash
# lib/os_user.sh - Linux user and filesystem ACL isolation for wp-isolate

get_site_user() {
    local domain="$1"
    sanitize_domain_to_user "$domain"
}

create_isolated_user() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local user
    user=$(get_site_user "$domain")

    if id "$user" >/dev/null 2>&1; then
        log_info "System user $user already exists."
        return 0
    fi

    log_info "Creating dedicated system user $user for $domain..."
    useradd --system --no-create-home --home-dir "$docroot" --shell /usr/sbin/nologin --user-group "$user"
    log_success "User $user created successfully."
}

remove_isolated_user() {
    local domain="$1"
    local user
    user=$(get_site_user "$domain")

    if id "$user" >/dev/null 2>&1; then
        log_info "Removing system user $user..."
        userdel "$user" 2>/dev/null || true
        groupdel "$user" 2>/dev/null || true
        log_success "User $user removed."
    fi
}

apply_site_permissions() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"
    local user
    user=$(get_site_user "$domain")

    if [ ! -d "$docroot" ]; then
        log_error "Document root $docroot does not exist."
        return 1
    fi

    log_info "Applying isolation permissions on $docroot for user $user..."

    # Handle aaPanel immutable .user.ini if present
    if [ -f "$docroot/.user.ini" ]; then
        chattr -i "$docroot/.user.ini" 2>/dev/null || true
    fi

    # Change owner to isolated user (if root)
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        chown -R "${user}:${user}" "$docroot" 2>/dev/null || true
    fi
    chmod 750 "$docroot"

    # Restore immutable attribute to .user.ini
    if [ -f "$docroot/.user.ini" ]; then
        chattr +i "$docroot/.user.ini" 2>/dev/null || true
    fi

    # Allow aaPanel OLS web worker (www) read access to static assets via POSIX ACL
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -R -m u:www:rwx "$docroot" 2>/dev/null || true
        setfacl -R -d -m u:www:rwx "$docroot" 2>/dev/null || true
    fi

    # Restrict sensitive config files (wp-config.php, .env)
    for conf_file in "$docroot/wp-config.php" "$docroot/.env"; do
        if [ -f "$conf_file" ]; then
            if [ "$(basename "$conf_file")" = "wp-config.php" ]; then
                if ! grep -q "'FS_METHOD'" "$conf_file"; then
                    local block="
/* BEGIN WP-ISOLATE FS_METHOD */
if ( ! defined( 'FS_METHOD' ) ) {
    define( 'FS_METHOD', 'direct' );
}
/* END WP-ISOLATE FS_METHOD */"
                    {
                        head -n 1 "$conf_file"
                        printf "%s\n" "$block"
                        tail -n +2 "$conf_file"
                    } > "${conf_file}.tmp" && mv "${conf_file}.tmp" "$conf_file"
                    log_info "Injected FS_METHOD direct into $conf_file"
                fi
            fi

            if [ "${EUID:-$(id -u)}" -eq 0 ]; then
                chown "${user}:${user}" "$conf_file"
            fi
            chmod 640 "$conf_file"
            if command -v setfacl >/dev/null 2>&1; then
                setfacl -m u:www:rw "$conf_file" 2>/dev/null || true
            fi
            log_info "Secured configuration file: $conf_file (640, isolated from other users, readable/writable by www)"
        fi
    done
    log_success "Permissions applied successfully."
}

restore_site_permissions() {
    local domain="$1"
    local docroot="${2:-/www/wwwroot/${domain}}"

    if [ ! -d "$docroot" ]; then
        return 0
    fi

    log_info "Restoring standard aaPanel permissions (www:www) on $docroot..."
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -R -b "$docroot" 2>/dev/null || true
    fi

    if [ -f "$docroot/.user.ini" ]; then
        chattr -i "$docroot/.user.ini" 2>/dev/null || true
    fi

    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        chown -R www:www "$docroot" 2>/dev/null || true
    fi
    chmod 755 "$docroot"
    find "$docroot" -type f -exec chmod 644 {} + 2>/dev/null || true
    find "$docroot" -type d -exec chmod 755 {} + 2>/dev/null || true

    if [ -f "$docroot/.user.ini" ]; then
        chattr +i "$docroot/.user.ini" 2>/dev/null || true
    fi
    log_success "Restored permissions to www:www."
}

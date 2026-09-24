#!/usr/bin/env bash
# lib/common.sh - Common utilities and environment validation for wp-isolate

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_CYAN="\033[0;36m"
COLOR_RESET="\033[0m"

log_info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }

# Sanitize domain name to a valid Linux system username (max 31 characters)
sanitize_domain_to_user() {
    local domain="$1"
    local clean
    clean=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    local user="iso_${clean}"
    if [ ${#user} -gt 31 ]; then
        user="${user:0:31}"
        user=$(echo "$user" | sed 's/_$//')
    fi
    echo "$user"
}

# Check system prerequisites for running wp-isolate
check_prerequisites() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_error "wp-isolate must be run as root."
        return 1
    fi

    if [ ! -d "/www/server/panel" ]; then
        log_error "aaPanel not detected (/www/server/panel not found)."
        return 1
    fi

    if [ ! -d "/usr/local/lsws" ]; then
        log_error "OpenLiteSpeed not detected (/usr/local/lsws not found)."
        return 1
    fi

    for cmd in setfacl getfacl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_warn "$cmd not found. Attempting to install acl package..."
            apt-get update -qq && apt-get install -y -qq acl || true
            if ! command -v "$cmd" >/dev/null 2>&1; then
                log_error "Failed to install $cmd. Please install acl package manually."
                return 1
            fi
        fi
    done
    return 0
}

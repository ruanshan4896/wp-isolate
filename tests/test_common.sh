#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

test_sanitize_domain() {
    local result
    result=$(sanitize_domain_to_user "my-cool-site.com")
    [[ "$result" == "iso_my_cool_site_com" ]] || { echo "Failed: $result"; exit 1; }

    result=$(sanitize_domain_to_user "sub.domain.verylongdomainnameexceedinglimit.vn")
    [[ ${#result} -le 31 ]] || { echo "Failed length: ${#result}"; exit 1; }
    [[ "$result" =~ ^iso_[a-z0-9_]+$ ]] || { echo "Failed format: $result"; exit 1; }
    
    result=$(sanitize_domain_to_user "Example.COM")
    [[ "$result" == "iso_example_com" ]] || { echo "Failed case conversion: $result"; exit 1; }

    echo "test_sanitize_domain PASS"
}

test_logging() {
    log_info "Testing log_info" >/dev/null
    log_success "Testing log_success" >/dev/null
    log_warn "Testing log_warn" >/dev/null
    log_error "Testing log_error" 2>/dev/null
    echo "test_logging PASS"
}

test_sanitize_domain
test_logging
echo "ALL TESTS IN test_common.sh PASS"

#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/os_user.sh"

test_user_generation() {
    local domain="test-sample.org"
    local user
    user=$(get_site_user "$domain")
    [[ "$user" == "iso_test_sample_org" ]] || { echo "User mismatch: $user"; exit 1; }
    echo "test_user_generation PASS"
}

test_permission_logic_dry_run() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "${tmp_dir}/wp-content"
    touch "${tmp_dir}/wp-config.php"
    touch "${tmp_dir}/index.php"
    touch "${tmp_dir}/.env"

    # Test file existence check
    local dummy_domain="dryrun.com"
    # When running as non-root in test environment, test that the function validates directory
    if apply_site_permissions "$dummy_domain" "${tmp_dir}/non_existent_dir" 2>/dev/null; then
        echo "Failed: should have returned error on non-existent dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
    echo "test_permission_logic_dry_run PASS"
}

test_user_generation
test_permission_logic_dry_run
echo "ALL TESTS IN test_os_user.sh PASS"

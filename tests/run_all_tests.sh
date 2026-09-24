#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
PASSED=0

echo "=========================================================="
echo "      RUNNING WP-ISOLATE AUTOMATED TEST SUITE             "
echo "=========================================================="

for test_file in "${SCRIPT_DIR}"/test_*.sh; do
    [ -f "$test_file" ] || continue
    test_name=$(basename "$test_file")
    echo -n "Running $test_name ... "
    if bash "$test_file" >/tmp/test_output.log 2>&1; then
        echo -e "\033[0;32m[PASS]\033[0m"
        PASSED=$((PASSED + 1))
    else
        echo -e "\033[0;31m[FAIL]\033[0m"
        cat /tmp/test_output.log
        FAILED=$((FAILED + 1))
    fi
done

echo "=========================================================="
echo "Tests Passed: $PASSED | Tests Failed: $FAILED"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0

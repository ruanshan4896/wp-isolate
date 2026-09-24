#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output=$(bash "${SCRIPT_DIR}/bin/wp-isolate" --help || true)
echo "$output" | grep -q "Usage: wp-isolate" || { echo "Usage string missing"; exit 1; }
echo "$output" | grep -q "isolate <domain>" || { echo "isolate command missing in help"; exit 1; }
echo "$output" | grep -q "restore <domain>" || { echo "restore command missing in help"; exit 1; }
echo "$output" | grep -q "list" || { echo "list command missing in help"; exit 1; }
# Test execution via symlink
tmp_symlink=$(mktemp)
rm -f "$tmp_symlink"
ln -s "${SCRIPT_DIR}/bin/wp-isolate" "$tmp_symlink"
sym_output=$(bash "$tmp_symlink" --help || true)
echo "$sym_output" | grep -q "Usage: wp-isolate" || { echo "Symlink execution failed"; rm -f "$tmp_symlink"; exit 1; }
rm -f "$tmp_symlink"

echo "test_cli_help PASS"

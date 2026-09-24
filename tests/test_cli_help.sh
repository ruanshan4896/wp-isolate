#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output=$(bash "${SCRIPT_DIR}/bin/wp-isolate" --help || true)
echo "$output" | grep -q "Usage: wp-isolate" || { echo "Usage string missing"; exit 1; }
echo "$output" | grep -q "isolate <domain>" || { echo "isolate command missing in help"; exit 1; }
echo "$output" | grep -q "restore <domain>" || { echo "restore command missing in help"; exit 1; }
echo "$output" | grep -q "list" || { echo "list command missing in help"; exit 1; }
echo "test_cli_help PASS"

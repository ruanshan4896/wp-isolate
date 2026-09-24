#!/usr/bin/env bash
# install.sh - Installer for wp-isolate on aaPanel (Ubuntu/Debian)
set -eu
set -o pipefail 2>/dev/null || true

INSTALL_DIR="/opt/wp-isolate"
BIN_LINK="/usr/local/bin/wp-isolate"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[ERROR] Please run install.sh as root." >&2
    exit 1
fi

echo "===> Installing wp-isolate to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/lib" "${INSTALL_DIR}/templates" "${INSTALL_DIR}/data" "${INSTALL_DIR}/backups" "${INSTALL_DIR}/vhosts"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp -r "${SCRIPT_DIR}/bin/"* "${INSTALL_DIR}/bin/"
cp -r "${SCRIPT_DIR}/lib/"* "${INSTALL_DIR}/lib/"
cp -r "${SCRIPT_DIR}/templates/"* "${INSTALL_DIR}/templates/"

chmod +x "${INSTALL_DIR}/bin/wp-isolate"

# Create system symlink
ln -sf "${INSTALL_DIR}/bin/wp-isolate" "$BIN_LINK"

# Install dependencies if missing
for cmd in setfacl getfacl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[INFO] Installing acl package..."
        apt-get update -qq && apt-get install -y -qq acl || true
    fi
done

echo "===> Installation complete! You can now run 'wp-isolate' from anywhere."
wp-isolate --help || true

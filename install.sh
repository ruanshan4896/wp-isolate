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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    echo "[WARNING] You are running install.sh from $SCRIPT_DIR, but the tool expects to be installed in $INSTALL_DIR."
    echo "[INFO] For the best experience, git clone directly into $INSTALL_DIR:"
    echo "       git clone https://github.com/ruanshan4896/wp-isolate.git $INSTALL_DIR"
    
    # Fallback to copy if they didn't clone into /opt/wp-isolate
    mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/lib" "${INSTALL_DIR}/templates"
    cp -r "${SCRIPT_DIR}/bin/"* "${INSTALL_DIR}/bin/"
    cp -r "${SCRIPT_DIR}/lib/"* "${INSTALL_DIR}/lib/"
    cp -r "${SCRIPT_DIR}/templates/"* "${INSTALL_DIR}/templates/"
fi

mkdir -p "${INSTALL_DIR}/data" "${INSTALL_DIR}/backups" "${INSTALL_DIR}/vhosts"

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

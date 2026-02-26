#!/bin/sh
set -e

# binget installer script
# Cross-platform for Linux and macOS

REPO="frostyeti/binget"
BIN_DIR="$HOME/.local/bin"

VERSION="${1:-latest}"

if [ "$VERSION" = "latest" ]; then
    VERSION=$(curl -s "https://api.github.com/repos/${REPO}/releases" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//')
    if [ -z "$VERSION" ]; then
        echo "Failed to fetch latest version."
        exit 1
    fi
fi

# Detect OS and Architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
    linux*) OS="linux" ;;
    darwin*) OS="darwin" ;;
    *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported Architecture: $ARCH"; exit 1 ;;
esac

FILENAME="binget-${OS}-${ARCH}-v${VERSION}.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${FILENAME}"

echo "Downloading ${FILENAME} from ${URL}..."
TMP_DIR=$(mktemp -d)
curl -L -f -o "${TMP_DIR}/${FILENAME}" "${URL}" || { echo "Download failed"; exit 1; }

echo "Extracting..."
tar -xzf "${TMP_DIR}/${FILENAME}" -C "${TMP_DIR}"

echo "Installing to ${BIN_DIR}..."
mkdir -p "${BIN_DIR}"
mv "${TMP_DIR}/binget" "${BIN_DIR}/binget"
chmod +x "${BIN_DIR}/binget"

rm -rf "${TMP_DIR}"

echo "binget successfully installed to ${BIN_DIR}/binget"
echo "Make sure ${BIN_DIR} is in your PATH."

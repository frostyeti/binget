#!/bin/sh
set -e

# binget installer script
# Cross-platform for Linux and macOS

VERSION="0.0.0-alpha.0"
REPO="frostyeti/binget"
BIN_DIR="$HOME/.local/bin"

# Detect OS and Architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
    linux*) OS="linux" ;;
    darwin*) OS="darwin" ;;
    *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
    x86_64) ARCH="x86_64" ;;
    amd64) ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    arm64) ARCH="aarch64" ;;
    *) echo "Unsupported Architecture: $ARCH"; exit 1 ;;
esac

# Handle darwin naming in the release if needed
if [ "$OS" = "darwin" ]; then
    OS="macos"
fi

FILENAME="binget-${OS}-${ARCH}-v${VERSION}.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${FILENAME}"

echo "Downloading ${FILENAME}..."
TMP_DIR=$(mktemp -d)
curl -L -f -o "${TMP_DIR}/${FILENAME}" "${URL}"

echo "Extracting..."
tar -xzf "${TMP_DIR}/${FILENAME}" -C "${TMP_DIR}"

echo "Installing to ${BIN_DIR}..."
mkdir -p "${BIN_DIR}"
mv "${TMP_DIR}/binget" "${BIN_DIR}/binget"
chmod +x "${BIN_DIR}/binget"

rm -rf "${TMP_DIR}"

echo "binget successfully installed to ${BIN_DIR}/binget"
echo "Make sure ${BIN_DIR} is in your PATH."

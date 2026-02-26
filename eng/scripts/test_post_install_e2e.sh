#!/usr/bin/env bash
set -e

# Setup test directory
TEST_DIR="eng/tmp/e2e"
rm -rf "$TEST_DIR"
rm -f mock-link
mkdir -p "$TEST_DIR/mock-registry/m/mock-pkg/1.0.0"
mkdir -p "$TEST_DIR/payload"

# Create mock payload
echo "#!/bin/sh" > "$TEST_DIR/payload/mock-bin"
echo "echo 'Hello from mock-bin!'" >> "$TEST_DIR/payload/mock-bin"
chmod +x "$TEST_DIR/payload/mock-bin"
tar -czf "$TEST_DIR/mock-registry/mock-pkg.tar.gz" -C "$TEST_DIR/payload" mock-bin

# Create versions.json
cat << 'JSON' > "$TEST_DIR/mock-registry/m/mock-pkg/versions.json"
{
  "latest": "1.0.0",
  "versions": [
    { "version": "1.0.0", "description": "Mock package", "status": "active" }
  ]
}
JSON

# Create manifest.linux.json
cat << 'JSON' > "$TEST_DIR/mock-registry/m/mock-pkg/1.0.0/manifest.linux-x86_64.json"
{
  "install_modes": {
    "user": {
      "type": "archive",
      "url": "http://localhost:8080/mock-pkg.tar.gz",
      "bin": ["mock-bin"],
      "shortcuts": [
        { "name": "MockApp", "target": "mock-bin", "location": "desktop" }
      ],
      "links": [
        { "type": "symlink", "link": "mock-link", "target": "mock-bin" }
      ]
    },
    "shim": {
      "type": "archive",
      "url": "http://localhost:8080/mock-pkg.tar.gz",
      "bin": ["mock-bin"]
    }
  }
}
JSON

# Also for arm64 if that's the runner
cp "$TEST_DIR/mock-registry/m/mock-pkg/1.0.0/manifest.linux-x86_64.json" "$TEST_DIR/mock-registry/m/mock-pkg/1.0.0/manifest.linux-aarch64.json"

# Start local HTTP server
pushd "$TEST_DIR/mock-registry" > /dev/null
python3 -m http.server 8080 > /dev/null 2>&1 &
SERVER_PID=$!
popd > /dev/null

# Make sure server is cleaned up on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Give server a second to start
sleep 1

echo "--- RUNNING BINGET INSTALL (USER MODE) ---"
export BINGET_REGISTRY_URL="http://localhost:8080"
export XDG_DATA_HOME="$PWD/$TEST_DIR/xdg_data"
export HOME="$PWD/$TEST_DIR/home"
mkdir -p "$HOME/Desktop"
mkdir -p "$HOME/.local/share/applications"

./zig-out/bin/binget install mock-pkg || { echo "Install failed"; exit 1; }

echo "--- VERIFYING USER MODE POST INSTALL ---"
if [ ! -L "mock-link" ]; then
    echo "Error: mock-link symlink not found!"
    exit 1
fi

if [ ! -f "$HOME/Desktop/MockApp.desktop" ]; then
    echo "Error: MockApp.desktop shortcut not found on Desktop!"
    exit 1
fi

echo "--- RUNNING BINGET INSTALL (SHIM MODE) ---"
./zig-out/bin/binget install mock-pkg --shim || { echo "Install failed"; exit 1; }

if [ ! -L "$HOME/.local/share/binget/env/mock-pkg/1.0.0/mock-bin" ]; then
    echo "Error: shim not found!"
    ls -la "$HOME/.local/share/binget/env/mock-pkg/1.0.0/" || true
    exit 1
fi

rm -rf "$TEST_DIR" mock-link
echo "--- ALL TESTS PASSED ---"

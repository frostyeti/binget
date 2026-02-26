$ErrorActionPreference = "Stop"

# binget PowerShell installer script
# For Windows

$VERSION = "0.0.0-alpha.0"
$REPO = "frostyeti/binget"
$BIN_DIR = "$env:LOCALAPPDATA\Programs\bin"

# Detect Architecture
$ARCH = if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") { "x86_64" } else { "aarch64" }

$FILENAME = "binget-windows-${ARCH}-v${VERSION}.zip"
$URL = "https://github.com/${REPO}/releases/download/v${VERSION}/${FILENAME}"

Write-Host "Downloading ${FILENAME}..."
$TMP_DIR = Join-Path $env:TEMP "binget-install-$([guid]::NewGuid().ToString())"
New-Item -ItemType Directory -Path $TMP_DIR | Out-Null
$ZIP_PATH = Join-Path $TMP_DIR $FILENAME

Invoke-WebRequest -Uri $URL -OutFile $ZIP_PATH

Write-Host "Extracting..."
Expand-Archive -Path $ZIP_PATH -DestinationPath $TMP_DIR

Write-Host "Installing to ${BIN_DIR}..."
if (!(Test-Path -Path $BIN_DIR)) {
    New-Item -ItemType Directory -Path $BIN_DIR | Out-Null
}

Move-Item -Path (Join-Path $TMP_DIR "binget.exe") -Destination (Join-Path $BIN_DIR "binget.exe") -Force

Remove-Item -Recurse -Force $TMP_DIR

Write-Host "binget successfully installed to ${BIN_DIR}\binget.exe"
Write-Host "Make sure ${BIN_DIR} is in your PATH."

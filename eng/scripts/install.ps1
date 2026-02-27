$ErrorActionPreference = "Stop"

# binget PowerShell installer script
# For Windows

$REPO = "frostyeti/binget"
$BIN_DIR = if ($env:BINGET_BIN_DIR) { $env:BINGET_BIN_DIR } else { "$env:LOCALAPPDATA\Programs\bin" }

if (-not $VERSION) {
    Write-Host "Fetching latest version..."
    $ReleaseData = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases" -UseBasicParsing
    # Assuming the first release in the array is the latest
    $VERSION = $ReleaseData[0].tag_name.TrimStart("v")
}

# Detect Architecture
$ARCH = if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") { "amd64" } else { "arm64" }

$FILENAME = "binget-windows-${ARCH}-v${VERSION}.zip"
$URL = "https://github.com/${REPO}/releases/download/v${VERSION}/${FILENAME}"

Write-Host "Downloading ${FILENAME}..."
$TMP_DIR = Join-Path $env:TEMP "binget-install-$([guid]::NewGuid().ToString())"
New-Item -ItemType Directory -Path $TMP_DIR | Out-Null
$ZIP_PATH = Join-Path $TMP_DIR $FILENAME

Invoke-WebRequest -Uri $URL -OutFile $ZIP_PATH

Write-Host "Extracting..."
Expand-Archive -Path $ZIP_PATH -DestinationPath $TMP_DIR -Force

Write-Host "Installing to ${BIN_DIR}..."
if (!(Test-Path -Path $BIN_DIR)) {
    New-Item -ItemType Directory -Path $BIN_DIR | Out-Null
}

Move-Item -Path (Join-Path $TMP_DIR "binget.exe") -Destination (Join-Path $BIN_DIR "binget.exe") -Force

Remove-Item -Recurse -Force $TMP_DIR

Write-Host "binget successfully installed to ${BIN_DIR}\binget.exe"
Write-Host "Make sure ${BIN_DIR} is in your PATH."

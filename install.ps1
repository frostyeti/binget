$ErrorActionPreference = "Stop"

# binget PowerShell installer script
# For Windows

param(
    [string]$Version = "latest"
)

$REPO = "frostyeti/binget"
$BIN_DIR = "$env:LOCALAPPDATA\Programs\bin"

if ($Version -eq "latest") {
    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases" -Headers @{"Accept"="application/vnd.github.v3+json"} | ConvertFrom-Json
        $Version = $releases[0].tag_name.TrimStart('v')
    } catch {
        Write-Error "Failed to fetch latest version from GitHub API."
        exit 1
    }
}

# Detect Architecture
$ARCH = if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") { "amd64" } else { "arm64" }

$FILENAME = "binget-windows-${ARCH}-v${Version}.zip"
$URL = "https://github.com/${REPO}/releases/download/v${Version}/${FILENAME}"

Write-Host "Downloading ${FILENAME} from ${URL}..."
$TMP_DIR = Join-Path $env:TEMP "binget-install-$([guid]::NewGuid().ToString())"
New-Item -ItemType Directory -Path $TMP_DIR -Force | Out-Null
$ZIP_PATH = Join-Path $TMP_DIR $FILENAME

Invoke-WebRequest -Uri $URL -OutFile $ZIP_PATH

Write-Host "Extracting..."
Expand-Archive -Path $ZIP_PATH -DestinationPath $TMP_DIR -Force

Write-Host "Installing to ${BIN_DIR}..."
if (!(Test-Path -Path $BIN_DIR)) {
    New-Item -ItemType Directory -Path $BIN_DIR -Force | Out-Null
}

Move-Item -Path (Join-Path $TMP_DIR "binget.exe") -Destination (Join-Path $BIN_DIR "binget.exe") -Force

Remove-Item -Recurse -Force $TMP_DIR

Write-Host "binget successfully installed to ${BIN_DIR}\binget.exe"
Write-Host "Make sure ${BIN_DIR} is in your PATH."

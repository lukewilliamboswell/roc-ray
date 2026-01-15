# Build a Roc app for WASM and serve it locally
#
# Usage: .\build_wasm.ps1 examples\hello_world.roc
#        .\build_wasm.ps1 examples\hello_world.roc -NoServe
#
# This script:
# 1. Builds the host library (zig build)
# 2. Builds the Roc app for wasm32 target
# 3. Copies app.wasm, host.js, and index.html to www/
# 4. Starts a local web server on port 8080

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$RocFile,

    [switch]$NoServe
)

$ErrorActionPreference = "Stop"

# Validate the Roc file exists
if (-not (Test-Path $RocFile)) {
    Write-Error "Error: Roc file not found: $RocFile"
    exit 1
}

# Get the base name without extension
$Basename = [System.IO.Path]::GetFileNameWithoutExtension($RocFile)
$SourceDir = Split-Path -Parent $RocFile
if ([string]::IsNullOrEmpty($SourceDir)) {
    $SourceDir = "."
}

Write-Host "=== Building host library ===" -ForegroundColor Cyan
zig build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "=== Building Roc app for WASM ===" -ForegroundColor Cyan
roc build --target=wasm32 $RocFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "=== Setting up www/ directory ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path www | Out-Null

# Find the wasm file (Roc outputs to same directory as source)
$WasmFile = Join-Path $SourceDir "$Basename.wasm"
if (-not (Test-Path $WasmFile)) {
    # Try current directory if not in source dir
    $WasmFile = "$Basename.wasm"
}

if (-not (Test-Path $WasmFile)) {
    Write-Error "Error: WASM file not found. Expected: $SourceDir\$Basename.wasm or $Basename.wasm"
    exit 1
}

Copy-Item $WasmFile www\app.wasm
Copy-Item platform\web\host.js www\
Copy-Item platform\web\index.html www\

Write-Host "=== Files ready in www/ ===" -ForegroundColor Cyan
Get-ChildItem www

if ($NoServe) {
    Write-Host ""
    Write-Host "Build complete. To serve manually:"
    Write-Host "  cd www; python -m http.server 8080"
    exit 0
}

Write-Host ""
Write-Host "=== Starting web server ===" -ForegroundColor Cyan
Write-Host "Open http://localhost:8080 in your browser" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop"
Write-Host ""

Push-Location www
try {
    python -m http.server 8080
} finally {
    Pop-Location
}

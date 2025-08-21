# Configuration
$url = "https://github.com/lukewilliamboswell/roc/releases/download/windows-20250129/roc-windows-x86_64-unnoficial-689c58f35e.7z"
$binDir = "$PSScriptRoot\bin"
$tempDir = "$PSScriptRoot\temp"
$archivePath = "$tempDir\roc.7z"
$finalPath = "$binDir\roc.exe"

# Create necessary directories
New-Item -ItemType Directory -Force -Path $binDir
New-Item -ItemType Directory -Force -Path $tempDir

# Only download and extract if the final executable doesn't exist
if (!(Test-Path $finalPath)) {
    Write-Host "Downloading Roc archive..."

    # Download the archive
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $archivePath)

    # Check if 7-Zip is installed
    $7zipPath = "$env:ProgramFiles\7-Zip\7z.exe"

    if (!(Test-Path $7zipPath)) {
        Write-Host "7-Zip is required but not found. Please install it from https://7-zip.org/"
        exit 1
    }

    Write-Host "Extracting archive..."
    # Extract the archive
    & $7zipPath x "$archivePath" "-o$tempDir" -y

    # Find roc.exe recursively in the temp directory
    $rocExePath = Get-ChildItem -Path $tempDir -Filter "roc.exe" -Recurse | Select-Object -First 1 -ExpandProperty FullName

    if ($rocExePath) {
        # Move the executable to the final location
        Move-Item $rocExePath $finalPath -Force

        # Clean up
        Remove-Item $tempDir -Recurse -Force

        Write-Host "Roc has been successfully installed to $finalPath"
    } else {
        Write-Host "Error: Could not find roc.exe in the extracted archive"
        exit 1
    }
} else {
    Write-Host "Roc is already installed at $finalPath"
}

$url = "https://github.com/lukewilliamboswell/roc/releases/download/windows-20241108/roc.exe"
$binDir = "$PSScriptRoot\bin\"
$path = "$binDir\roc.exe"

# download roc to /windows/bin
if (!(Test-Path $path)) {
  New-Item -ItemType Directory -Force -Path $binDir
  $wc = New-Object System.Net.WebClient
  $wc.DownloadFile($url, $path)
}

# Add to PATH if not already present
$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentPath -notlike "*$binDir*") {
    $newPath = $currentPath + ";" + $binDir
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

    # Update current session's PATH as well
    $env:Path = $newPath

    Write-Host "Added $binDir to PATH"
} else {
    Write-Host "$binDir is already in PATH"
}

$url = "https://github.com/lukewilliamboswell/roc/releases/download/windows-20241108/roc.exe"
$binDir = "$PSScriptRoot\bin\"
$path = "$binDir\roc.exe"

# download roc to /windows/bin
if (!(Test-Path $path)) {
  New-Item -ItemType Directory -Force -Path $binDir
  $wc = New-Object System.Net.WebClient
  $wc.DownloadFile($url, $path)
}

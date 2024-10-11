param(
    [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$false)] [System.String] $App = "examples/basic-shapes.roc"
)

# Check if the ZIG environment variable is set
if ($env:ZIG) {
    $zigPath = $env:ZIG
} else {
    $zigPath = "zig"
}

# Build the roc app and then link that with the host to produce the executable
& $zigPath build --release=fast -Dapp="$App"

# Run the executable
.\zig-out\bin\rocray.exe

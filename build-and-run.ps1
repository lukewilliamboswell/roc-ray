param(
    [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$false)] [System.String] $App = "examples/basic-shapes.roc"
)

# Build the roc app and then link that with the host to produce the executable
zig build --release=fast -Dapp="$App"

# Run the executable
.\zig-out\bin\rocray.exe

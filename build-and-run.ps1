param(
    [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$false)] [System.String] $App = "examples/basic-shapes.roc"
)

# --no-link will instruct roc not to link with the host, we will use the rust toolchain to do this
# --optimize will instruct roc to use the LLVM backend and produce runtime optimised machine code
# --output will instruct roc to put the output in the current directory
# $App is the path to the roc app we want to build
roc build --no-link --optimize --output=app.lib "$App"

# Build the app executable
cargo run

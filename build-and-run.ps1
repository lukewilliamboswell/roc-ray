param(
    [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$false)] [System.String] $App = "examples/basic-shapes.roc"
)

roc build --no-link --output=app.lib "$App"

cargo run

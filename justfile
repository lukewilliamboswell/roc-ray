
# list the available commands
list:
    just --list --unsorted

# check, build, and run an executable
[unix]
dev app="examples/basic-shapes.roc":
    roc check {{app}}
    roc build --no-link --output app.o {{app}}
    cargo run

# clean build artifacts
[unix]
clean:
    rm app.o
    cargo clean

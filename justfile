set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# the unix commands assume a recent roc is on the path
#
# the windows commands include a 'setup' recipe,
# to download an unofficial windows build of roc


# list the available commands
list:
    just --list --unsorted


# download roc.exe to ./windows/bin/
[windows]
setup:
    ./windows/setup.ps1


# build and run an executable
[unix]
dev app="examples/basic-shapes.roc" features="default":
    roc check {{app}}
    roc build --no-link --emit-llvm-ir --output app.o {{app}}
    cargo run --features {{features}}

# build and run an executable
[windows]
dev app="examples/basic-shapes.roc":
    .\windows\bin\roc.exe check {{app}}
    .\windows\bin\roc.exe build --no-link --output app.obj {{app}}
    cargo run


# build a release executable
[unix]
build app:
    roc check {{app}}
    roc build --no-link --optimize --output app.o {{app}}
    cargo build --release

# build a release executable
[windows]
build app:
    .\windows\bin\roc.exe check {{app}}
    .\windows\bin\roc.exe build --no-link --optimize --output app.obj {{app}}
    cargo build --release


# clean build artifacts
[unix]
clean:
    rm -f *.o
    rm -f *.a
    cargo clean

# clean build artifacts
[windows]
clean:
    Remove-Item . -include *.obj
    Remove-Item . -include *.lib
    cargo clean


[unix]
check app:
    roc check {{app}}

[windows]
check app:
    .\windows\bin\roc.exe check {{app}}


[unix]
format file:
    roc format {{file}}

[windows]
format file:
    .\windows\bin\roc.exe format {{file}}

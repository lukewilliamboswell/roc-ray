set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# the unix commands assume a recent roc is on the path
# the windows commands include a 'setup' recipe to download a windows build of roc

# list the available commands
list:
    just --list --unsorted


# download roc.exe to ./windows/bin/
[windows]
setup:
    ./windows/setup.ps1


# build and run an executable
[unix]
dev app:
    roc check {{app}}
    roc build --no-link --output app.o {{app}}
    cargo run

# build and run an executable
[windows]
dev app:
    .\windows\bin\roc.exe check {{app}}
    .\windows\bin\roc.exe build --no-link --output app.obj {{app}}
    cargo run


# clean build artifacts
[unix]
clean:
    rm -f app.o
    rm -f libapp.a
    cargo clean

# clean build artifacts
[windows]
clean:
    rm -f app.obj
    rm -f app.lib
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
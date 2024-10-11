
# build host
C:\zig-windows-x86_64-0.13.0\zig.exe build --release=fast

# run the executable
.\zig-out\bin\rocray.exe

# bundle the host with raylib (NOT USED... leaving this here for a future where we try to prebuild the host)
#LIB.EXE /OUT:./platform/windows-x64.lib /VERBOSE /LTCG .\zig-out\lib\raylib.lib .\zig-out\lib\rocray.lib
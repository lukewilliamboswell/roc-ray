# C23 aliases the prebuilt Linux raylib archive references.
#
# glibc 2.38 headers redirect strtol, strtoll, strtoul and sscanf to C23
# variants named __isoc23_*, and vendor/raylib/linux-x64 was compiled against
# them. Left to the dynamic linker those names exist only in glibc 2.38 and
# later, so on Ubuntu 22.04 or Debian 12 every app aborted the moment raylib
# initialised. Defining them in the host resolves raylib's references inside
# the app instead. The C23 behaviour they add -- `0b` binary prefixes -- is
# nothing raylib parses.
#
# Each is a tail jump to the classic function every glibc has, which forwards
# every argument untouched, variadic ones included, so sscanf needs no
# vsscanf. strtoll is strtol on LP64. Only symbols the link-time libc stub
# declares are named, since that stub is a locked linker input.
#
# Assembled into libhost.a for x86_64 glibc only; see build.zig.

    .text

    .globl __isoc23_strtol
    .type __isoc23_strtol, @function
__isoc23_strtol:
    jmp strtol@PLT
    .size __isoc23_strtol, . - __isoc23_strtol

    .globl __isoc23_strtoll
    .type __isoc23_strtoll, @function
__isoc23_strtoll:
    jmp strtol@PLT
    .size __isoc23_strtoll, . - __isoc23_strtoll

    .globl __isoc23_strtoul
    .type __isoc23_strtoul, @function
__isoc23_strtoul:
    jmp strtoul@PLT
    .size __isoc23_strtoul, . - __isoc23_strtoul

    .globl __isoc23_sscanf
    .type __isoc23_sscanf, @function
__isoc23_sscanf:
    jmp sscanf@PLT
    .size __isoc23_sscanf, . - __isoc23_sscanf

    .section .note.GNU-stack, "", @progbits

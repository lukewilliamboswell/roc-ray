# Windows DEF Files

These module definition (.def) files are used to generate Windows import libraries (.lib) for cross-compilation support.

## Source

These files are copied from **MinGW-w64**, which is bundled with Zig at:
```
<zig-installation>/lib/libc/mingw/lib-common/
```

For example, on a typical installation:
- Windows: `C:\Users\<user>\zig-x86_64-windows-<version>\lib\libc\mingw\lib-common\`
- Linux/macOS: `~/.local/lib/zig/lib/libc/mingw/lib-common/`

## License

MinGW-w64 is licensed under the **Zope Public License (ZPL) Version 2.1**, which is an open source license certified by the OSI and designated as GPL-compatible by the FSF.

See the full license text in the MinGW-w64 COPYING file, or at:
https://github.com/mingw-w64/mingw-w64/blob/master/COPYING

## Modifications

The `user32.def` file was modified from the original `user32.def.in`:
- Removed `#include "func.def.in"` preprocessor directive
- Expanded `F64(FunctionName)` macros to just `FunctionName` for 64-bit pointer functions:
  - `GetClassLongPtrA`, `GetClassLongPtrW`
  - `GetWindowLongPtrA`, `GetWindowLongPtrW`
  - `SetClassLongPtrA`, `SetClassLongPtrW`
  - `SetWindowLongPtrA`, `SetWindowLongPtrW`

`kernel32.def`, `ntdll.def`, and `ucrtbase.def` are the preprocessed output of
their `.def.in` templates for x86-64, with blank lines removed:

```
zig cc -E -P -x c -target x86_64-windows-gnu     -I <mingw>/def-include -I <mingw>/lib-common <mingw>/lib-common/<name>.def.in
```

where `<mingw>` is `<zig-installation>/lib/libc/mingw`.

## Usage

`zig build link-inputs` runs `zig dlltool` over these DEF files to generate the
import libraries of the `x64win` linker-input profile; see
`dependencies/link-inputs/README.md`.

`roc build` links only the inputs `platform/main.roc` lists and takes nothing
from a Visual Studio or Windows SDK install, so this set is everything an
`x64win` executable imports:

- `ucrtbase.lib` - the Universal C Runtime
- `kernel32.lib`, `ntdll.lib` - core Windows APIs, also imported by Roc's runtime
- `gdi32.lib`, `user32.lib`, `winmm.lib`, `opengl32.lib`, `shell32.lib` - raylib's windowing, timing and graphics
- `ws2_32.lib`, `crypt32.lib`, `shlwapi.lib`, `bcryptprimitives.lib` - networking, certificates, paths and entropy

## Updating

To update these files for a newer version of MinGW-w64:
1. Copy the relevant .def files from your Zig installation's `lib/libc/mingw/lib-common/`
2. For `user32.def.in`, apply the modifications listed above; for the three
   preprocessed files, rerun the command above
3. Follow the producer procedure in `dependencies/link-inputs/README.md` to
   publish the regenerated import libraries

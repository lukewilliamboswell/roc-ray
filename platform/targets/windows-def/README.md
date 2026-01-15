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

## Usage

During `zig build`, these DEF files are processed by `zig dlltool` to generate import libraries:
- `gdi32.lib` - Graphics Device Interface
- `user32.lib` - Windows USER API (windows, messages, input)
- `winmm.lib` - Windows Multimedia (timers)
- `opengl32.lib` - OpenGL
- `shell32.lib` - Windows Shell

These import libraries are required by raylib on Windows and are placed in `platform/targets/x64win/`.

## Updating

To update these files for a newer version of MinGW-w64:
1. Copy the relevant .def files from your Zig installation's `lib/libc/mingw/lib-common/`
2. For `user32.def.in`, apply the modifications listed above
3. Run `zig build` to regenerate the import libraries

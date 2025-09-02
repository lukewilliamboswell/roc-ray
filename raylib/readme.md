
A wrapper around raylib (version 5.5).

Regenerate rust bindings using bindgen cli with:

```sh
$ cd path/to/raylib/vendor && bash generate-bindings.sh
```

### Sources

Raylib sources were obtained from the [release page](https://github.com/raysan5/raylib/releases/tag/5.5) for each OS. The respective static library files are found within the `lib` folders in those source archives. Additionally, the header files can be taken from the `lib` folder in any of sources.

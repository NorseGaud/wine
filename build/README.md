# Silicon Cellar Wine build

This branch holds the Wine source from CodeWeavers CrossOver (branch `crossover`) with the Silicon Cellar fixes. [Silicon Cellar](https://github.com/NorseGaud/siliconcellar) uses the result as its Engine.

## Build

```sh
build/build-engine.sh <output-dir>
```

The output has the folders `bin`, `lib`, `libexec` (the GStreamer plugin scanner), and `share`. You can move the folder, because all libraries use `@rpath`.

Requirements:

- x86_64 Homebrew in `/usr/local`. On Apple Silicon, install it with `arch -x86_64`. The script starts itself under `arch -x86_64`.
- The Homebrew formulas in `deps.json` (`homebrew.build_formulas`). These are build tools only. No Homebrew library goes into the output. The script stops and shows the install command if one is missing.
- Xcode (for MoltenVK).

The script downloads the pinned inputs in `deps.json` into `.work/cache` and checks each SHA-256. Work files go into `.work` (set `SC_WORK_DIR` to change this). A new run skips the steps that are complete. To build again from the start, remove `.work/stage` and `.work/wine-build`.

Set `SC_SKIP_SMOKE_TESTS=1` to skip the smoke tests.

## Steps

1. Check the tools.
2. Download and check the pinned inputs: the CrossOver source archive, Nettle, GnuTLS, SDL2, llvm-mingw, and GStreamer.
3. Build GMP, FreeType, and MoltenVK from the CrossOver archive (MoltenVK keeps the CrossOver SPIRV-Cross). Build Nettle, GnuTLS (with the CrossOver source change in `patches/`), and SDL2 from the upstream releases. The CrossOver copies of Nettle and GnuTLS do not build on their own, and Homebrew `sdl2` is now `sdl2-compat`, which loads SDL3 at run time. Expand the GStreamer packages, except the ones in `gstreamer.skip_packages` (GTK, Python, developer tools, analytics, and editing), which Wine does not use for media. Give all these libraries `@rpath` install names.
4. Configure Wine. The script stops if Wine would open a library from a build path.
5. Build Wine and run `make install-lib`.
6. Copy every non-system library into `lib/`, change the references to `@rpath`, and add the rpaths. Wine opens some libraries at run time (GnuTLS, FreeType, SDL2, MoltenVK). On macOS their `SONAME_*` values in `config.h` are file names only, and dyld finds them through the rpath of the Wine `.so` files. So each staged library with a SONAME is copied too.
7. Smoke tests: `wine --version`, `wineboot --init`, the probes in `probe/`, each SONAME library loads from `lib/`, and no `/usr/local` or `.work` paths in any library.

## Probes

- `probe/boolean-args.c`: calls `NtQueryDirectoryObject` with dirty upper bits in the `BOOLEAN` arguments. The enumeration must end.
- `probe/child-args.c`: checks that `SILICONCELLAR_CHILD_ARGS` adds arguments to a child process one time only.
- `probe/app-dll-path.c` and `probe/app-dll-path-lib.c`: the build marks the library as builtin (`winebuild --builtin`) and puts it only in a temporary folder. The probe sets `DllPath` for one copy of itself. That copy must load the library, and a copy with another name must not find it.
- `probe/load-libraries.c`: a macOS program (not Windows) with an rpath to `lib/`. It opens each SONAME library by file name, in the same way as Wine.

## Fixes on this branch

- Backport of the upstream Wine `BOOLEAN` syscall fix (`d1415ab24e`, `f43402cde3`, `565091afa4`).
- `SILICONCELLAR_CHILD_ARGS`: rules `exe=arguments` separated by `;`. A matching child process gets the arguments at the end of its command line.
- `FullscreenBelowNotch`: Mac Driver option for each app (`HKCU\Software\Wine\AppDefaults\<app>.exe\Mac Driver`). Fullscreen stays below the camera housing.
- Renderer for each app (`HKCU\Software\Wine\AppDefaults\<app>.exe\SiliconCellar`), read when the process starts:
  - `DllPath`: a Unix folder with `x86_64-windows`, `i386-windows` and `x86_64-unix`. Wine searches it before its own DLL folder, for that app only. Steam and other apps in the same session keep the Wine DLLs. This replaces CrossOver's closed `cxcompatdb.so`, which calls `prepend_dll_path()`. The folder can also add DLLs that Wine does not have (for example DXMT `winemetal.dll`): Wine loads a builtin DLL only if a file with that name is on the Windows search path, so the Unix side exports the folder to that app as `WINEAPPDLLDIR`, and the PE loader looks there when the Windows search path has no file.
  - `D3DSharedPath`: the Unix path of D3DMetal's `libd3dshared.dylib`. It replaces `CX_APPLEGPTK_LIBD3DSHARED_PATH` for that app.

## Releases

Push a tag `sc-<crossover version>-<n>` (for example `sc-26.3.0-1`). The `Engine` workflow builds on `macos-15-intel` and publishes the archive, its `.sha256`, and the source archive.

## Licence

Wine is LGPL-2.1-or-later (`COPYING.LIB`). The Engine has only LGPL and permissive libraries. The build skips the GPL GStreamer packages (`gstreamer.skip_packages` in `deps.json`) and stops if a file in `gstreamer.gpl_files` is in the Engine.

The Engine archive has the licences of all bundled libraries in `share/doc`. `build/collect-gstreamer-licenses.py` copies the licence files of each GStreamer library from the GStreamer source bundle (`gstreamer.source_url`), which is also the source of the GStreamer package. `share/doc/gstreamer/SOURCE.txt` gives its URL and SHA-256. When you change the GStreamer version, update `gstreamer.license_skipped_sources` (build tools and GPL sources) for the new bundle.

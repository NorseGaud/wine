#!/bin/sh
# Build Silicon Cellar Wine (the Engine) into <output-dir>.
# Usage: build/build-engine.sh <output-dir>
# Output layout: <output-dir>/{bin,lib,share}. See build/README.md.
set -eu

if [ "$(uname -m)" = "arm64" ]; then
    exec arch -x86_64 /bin/sh "$0" "$@"
fi

[ $# -eq 1 ] || { echo "usage: $0 <output-dir>" >&2; exit 2; }

SOURCE_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPS_FILE="$SOURCE_ROOT/build/deps.json"
WORK_DIR="${SC_WORK_DIR:-$SOURCE_ROOT/.work}"
CACHE_DIR="$WORK_DIR/cache"
SOURCES_DIR="$WORK_DIR/src"
STAGE_DIR="$WORK_DIR/stage"
WINE_BUILD_DIR="$WORK_DIR/wine-build"
mkdir -p "$1" "$CACHE_DIR" "$SOURCES_DIR" "$STAGE_DIR/lib"
OUTPUT_DIR=$(cd "$1" && pwd)
JOBS=$(sysctl -n hw.ncpu)

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export CC=/usr/bin/clang
export CXX=/usr/bin/clang++

log() { printf '\n==> %s\n' "$*"; }
install_name_of() { otool -D "$1" | tail -n +2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
dep() { plutil -extract "$1" raw -o - "$DEPS_FILE"; }
# A step marker holds the output folder, because configure bakes it into the build.
step_done() { [ -f "$STAGE_DIR/.done-$1" ] && [ "$(cat "$STAGE_DIR/.done-$1")" = "$OUTPUT_DIR" ]; }
mark_step_done() { echo "$OUTPUT_DIR" > "$STAGE_DIR/.done-$1"; }

BREW_PREFIX=$(dep homebrew.prefix)
BUILD_FORMULAS=$(dep homebrew.build_formulas)
RUNTIME_FORMULAS=$(dep homebrew.runtime_formulas)
LLVM_MINGW_DIR="$SOURCES_DIR/llvm-mingw-$(dep llvm_mingw.version)"
# The CrossOver copies of Nettle and GnuTLS have CrossOver build files that do not
# build on their own. The upstream releases are used, plus the CrossOver GnuTLS
# source change in build/patches.
NETTLE_SOURCE_DIR="$SOURCES_DIR/nettle-$(dep nettle.version)"
GNUTLS_SOURCE_DIR="$SOURCES_DIR/gnutls-$(dep gnutls.version)"
GSTREAMER_ROOT="$STAGE_DIR/gstreamer"

export PATH="$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/opt/flex/bin:$BREW_PREFIX/opt/gettext/bin:$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin:$LLVM_MINGW_DIR/bin"

# ---------------------------------------------------------------- 1. tools

check_tools() {
    log "Check tools"
    [ -x "$BREW_PREFIX/bin/brew" ] || die "x86_64 Homebrew not found in $BREW_PREFIX. Install it with:
  arch -x86_64 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    missing_formulas=""
    for formula in $BUILD_FORMULAS $RUNTIME_FORMULAS; do
        "$BREW_PREFIX/bin/brew" list --versions "$formula" >/dev/null 2>&1 || missing_formulas="$missing_formulas $formula"
    done
    [ -z "$missing_formulas" ] || die "missing Homebrew formulas. Install them with:
  arch -x86_64 $BREW_PREFIX/bin/brew install$missing_formulas"
    xcodebuild -version >/dev/null 2>&1 || die "Xcode is required to build MoltenVK. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
    [ ! -e "$BREW_PREFIX/lib/libvulkan.dylib" ] || die "$BREW_PREFIX/lib/libvulkan.dylib exists. Wine would link it instead of MoltenVK. Run: brew uninstall vulkan-loader"
}

# ---------------------------------------------------------------- 2. inputs

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# fetch_pinned <url> <sha256> <file name in cache>
fetch_pinned() {
    pinned_file="$CACHE_DIR/$3"
    if [ ! -f "$pinned_file" ] || [ "$(sha256_of "$pinned_file")" != "$2" ]; then
        log "Download $3"
        curl -fL --retry 3 -o "$pinned_file.part" "$1"
        mv "$pinned_file.part" "$pinned_file"
    fi
    [ "$(sha256_of "$pinned_file")" = "$2" ] || die "SHA-256 mismatch for $3"
}

fetch_inputs() {
    fetch_pinned "$(dep crossover.url)" "$(dep crossover.sha256)" "crossover-sources-$(dep crossover.version).tar.gz"
    fetch_pinned "$(dep nettle.url)" "$(dep nettle.sha256)" "nettle-$(dep nettle.version).tar.gz"
    fetch_pinned "$(dep gnutls.url)" "$(dep gnutls.sha256)" "gnutls-$(dep gnutls.version).tar.xz"
    fetch_pinned "$(dep llvm_mingw.url)" "$(dep llvm_mingw.sha256)" "llvm-mingw-$(dep llvm_mingw.version).tar.xz"
    fetch_pinned "$(dep gstreamer.runtime_url)" "$(dep gstreamer.runtime_sha256)" "gstreamer-$(dep gstreamer.version).pkg"
    fetch_pinned "$(dep gstreamer.devel_url)" "$(dep gstreamer.devel_sha256)" "gstreamer-devel-$(dep gstreamer.version).pkg"

    if ! step_done extract; then
        log "Extract inputs"
        rm -rf "$SOURCES_DIR/sources" "$NETTLE_SOURCE_DIR" "$GNUTLS_SOURCE_DIR" "$LLVM_MINGW_DIR"
        tar -xzf "$CACHE_DIR/crossover-sources-$(dep crossover.version).tar.gz" -C "$SOURCES_DIR" \
            sources/freetype sources/gnutls/gmp sources/moltenvk
        mkdir -p "$NETTLE_SOURCE_DIR" "$GNUTLS_SOURCE_DIR"
        tar -xzf "$CACHE_DIR/nettle-$(dep nettle.version).tar.gz" -C "$NETTLE_SOURCE_DIR" --strip-components 1
        tar -xJf "$CACHE_DIR/gnutls-$(dep gnutls.version).tar.xz" -C "$GNUTLS_SOURCE_DIR" --strip-components 1
        patch -d "$GNUTLS_SOURCE_DIR" -p1 < "$SOURCE_ROOT/build/patches/gnutls-$(dep gnutls.version)-client-hello-order.patch"
        mkdir -p "$LLVM_MINGW_DIR"
        tar -xJf "$CACHE_DIR/llvm-mingw-$(dep llvm_mingw.version).tar.xz" -C "$LLVM_MINGW_DIR" --strip-components 1
        mark_step_done extract
    fi
}

# ---------------------------------------------------------------- 3. libraries

AUTOTOOLS_CFLAGS="-O2 -arch x86_64"
AUTOTOOLS_LDFLAGS="-arch x86_64 -L$STAGE_DIR/lib -Wl,-headerpad_max_install_names"

# build_autotools <name> <source dir> [configure options...]
build_autotools() {
    library_name=$1
    library_source=$2
    shift 2
    step_done "$library_name" && return 0
    log "Build $library_name"
    rm -rf "$WORK_DIR/build-$library_name"
    mkdir -p "$WORK_DIR/build-$library_name"
    (
        cd "$WORK_DIR/build-$library_name"
        CFLAGS="$AUTOTOOLS_CFLAGS" CXXFLAGS="$AUTOTOOLS_CFLAGS" CPPFLAGS="-I$STAGE_DIR/include" \
        LDFLAGS="$AUTOTOOLS_LDFLAGS" PKG_CONFIG_LIBDIR="$STAGE_DIR/lib/pkgconfig" \
            "$library_source/configure" --prefix="$STAGE_DIR" --enable-shared --disable-static "$@"
        make -j"$JOBS"
        make install
    )
    mark_step_done "$library_name"
}

build_libraries() {
    build_autotools gmp "$SOURCES_DIR/sources/gnutls/gmp" --enable-fat --disable-cxx
    build_autotools nettle "$NETTLE_SOURCE_DIR" \
        --enable-fat --disable-documentation --disable-openssl \
        --with-include-path="$STAGE_DIR/include" --with-lib-path="$STAGE_DIR/lib"
    build_autotools gnutls "$GNUTLS_SOURCE_DIR" \
        --disable-doc --disable-manpages --disable-tools --disable-tests --disable-cxx --disable-nls \
        --disable-guile --disable-libdane --disable-full-test-suite --disable-gost \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
        --without-brotli --without-zstd --without-tpm --without-tpm2 \
        NETTLE_CFLAGS="-I$STAGE_DIR/include" NETTLE_LIBS="-L$STAGE_DIR/lib -lnettle" \
        HOGWEED_CFLAGS="-I$STAGE_DIR/include" HOGWEED_LIBS="-L$STAGE_DIR/lib -lhogweed" \
        GMP_CFLAGS="-I$STAGE_DIR/include" GMP_LIBS="-L$STAGE_DIR/lib -lgmp"
    if [ ! -f "$SOURCES_DIR/sources/freetype/builds/unix/configure" ]; then
        (cd "$SOURCES_DIR/sources/freetype" && LIBTOOLIZE=glibtoolize ./autogen.sh)
    fi
    # The archive has an empty dlg submodule. dlg is compiled only with FT_DEBUG_LOGGING, but
    # the make rules need its files to exist (src/dlg/rules.mk and the setup checkout check).
    freetype_source="$SOURCES_DIR/sources/freetype"
    mkdir -p "$freetype_source/include/dlg"
    touch "$freetype_source/src/dlg/dlg.c" "$freetype_source/include/dlg/dlg.h" "$freetype_source/include/dlg/output.h"
    build_autotools freetype "$SOURCES_DIR/sources/freetype" \
        --without-harfbuzz --without-png --without-brotli --without-bzip2
    build_moltenvk
    stage_homebrew_runtime
    stage_gstreamer
    set_stage_install_names
}

build_moltenvk() {
    step_done moltenvk && return 0
    log "Build MoltenVK"
    moltenvk_source="$SOURCES_DIR/sources/moltenvk"
    crossover_spirv_cross="$SOURCES_DIR/moltenvk-spirv-cross"
    if [ -d "$moltenvk_source/External/SPIRV-Cross" ] && [ ! -L "$moltenvk_source/External/SPIRV-Cross" ]; then
        rm -rf "$crossover_spirv_cross"
        mv "$moltenvk_source/External/SPIRV-Cross" "$crossover_spirv_cross"
    fi
    (
        cd "$moltenvk_source"
        [ -d .git ] || { git init -q && git add -A && git -c user.name=build -c user.email=build@localhost commit -qm "CrossOver MoltenVK"; }
        ./fetchDependencies --macos --spirv-cross-root "$crossover_spirv_cross"
        make macos
    )
    moltenvk_dylib=$(find "$moltenvk_source/Package/Release" -name libMoltenVK.dylib -path '*macOS*' | head -n 1)
    [ -n "$moltenvk_dylib" ] || die "libMoltenVK.dylib not found after the MoltenVK build"
    copy_x86_64 "$moltenvk_dylib" "$STAGE_DIR/lib/libMoltenVK.dylib"
    cp "$moltenvk_source/LICENSE" "$STAGE_DIR/MoltenVK-LICENSE"
    mark_step_done moltenvk
}

stage_homebrew_runtime() {
    step_done homebrew-runtime && return 0
    log "Stage SDL2 from Homebrew"
    cp -L "$BREW_PREFIX/opt/sdl2/lib/libSDL2-2.0.0.dylib" "$STAGE_DIR/lib/libSDL2-2.0.0.dylib"
    ln -sf libSDL2-2.0.0.dylib "$STAGE_DIR/lib/libSDL2.dylib"
    mark_step_done homebrew-runtime
}

# The GStreamer packages are expanded, not installed, so no root access is needed.
stage_gstreamer() {
    step_done gstreamer && return 0
    log "Stage GStreamer $(dep gstreamer.version)"
    rm -rf "$GSTREAMER_ROOT" "$WORK_DIR/gstreamer-expanded"
    mkdir -p "$GSTREAMER_ROOT"
    for gstreamer_package in "gstreamer-$(dep gstreamer.version).pkg" "gstreamer-devel-$(dep gstreamer.version).pkg"; do
        pkgutil --expand-full "$CACHE_DIR/$gstreamer_package" "$WORK_DIR/gstreamer-expanded/$gstreamer_package"
    done
    find "$WORK_DIR/gstreamer-expanded" -type d -name Payload | while read -r gstreamer_payload; do
        ditto "$gstreamer_payload" "$GSTREAMER_ROOT"
    done
    rm -rf "$WORK_DIR/gstreamer-expanded"
    mark_step_done gstreamer
}

gstreamer_prefix() {
    gstreamer_pc=$(find "$GSTREAMER_ROOT" -path '*/lib/pkgconfig/gstreamer-1.0.pc' | head -n 1)
    [ -n "$gstreamer_pc" ] || die "gstreamer-1.0.pc not found in $GSTREAMER_ROOT"
    dirname "$(dirname "$(dirname "$gstreamer_pc")")"
}

# Wine records the install name of each library it opens at run time, so the
# staged libraries must have @rpath install names before Wine is configured.
set_stage_install_names() {
    step_done install-names && return 0
    log "Set @rpath install names"
    for staged_library in "$STAGE_DIR"/lib/*.dylib; do
        [ -L "$staged_library" ] && continue
        chmod u+w "$staged_library"
        install_name_tool -id "@rpath/$(basename "$(install_name_of "$staged_library")")" "$staged_library"
    done
    gstreamer_library_prefix=$(gstreamer_prefix)
    for gstreamer_pc in "$gstreamer_library_prefix"/lib/pkgconfig/*.pc; do
        sed -i '' "s|^prefix=.*|prefix=$gstreamer_library_prefix|" "$gstreamer_pc"
    done
    mark_step_done install-names
}

# ---------------------------------------------------------------- 4 + 5. Wine

WINE_CONFIGURE_OPTIONS="--enable-archs=i386,x86_64 --with-mingw --disable-tests
    --with-coreaudio --with-cups --with-freetype --with-gettext --with-gnutls --with-gstreamer
    --with-opencl --with-pcap --with-pcsclite --with-pthread --with-sdl --with-vulkan
    --without-alsa --without-capi --without-dbus --without-ffmpeg --without-fontconfig --without-gphoto
    --without-gssapi --without-inotify --without-krb5 --without-netapi --without-oss --without-pulse
    --without-sane --without-udev --without-usb --without-v4l2 --without-wayland --without-x"

configure_wine() {
    step_done wine-configure && return 0
    log "Configure Wine"
    gstreamer_library_prefix=$(gstreamer_prefix)
    rm -rf "$WINE_BUILD_DIR"
    mkdir -p "$WINE_BUILD_DIR"
    (
        cd "$WINE_BUILD_DIR"
        # shellcheck disable=SC2086
        "$SOURCE_ROOT/configure" --prefix="$OUTPUT_DIR" $WINE_CONFIGURE_OPTIONS \
            CPPFLAGS="-I$STAGE_DIR/include" \
            LDFLAGS="-L$STAGE_DIR/lib -Wl,-headerpad_max_install_names" \
            PKG_CONFIG_LIBDIR="$STAGE_DIR/lib/pkgconfig:$gstreamer_library_prefix/lib/pkgconfig:$BREW_PREFIX/opt/sdl2/lib/pkgconfig" \
            SDL2_LIBS="-L$STAGE_DIR/lib -lSDL2"
    )
    check_wine_sonames
    mark_step_done wine-configure
}

# Every library that Wine opens by name must come from the stage (@rpath) or the system.
check_wine_sonames() {
    wrong_sonames=$(grep '^#define SONAME_' "$WINE_BUILD_DIR/include/config.h" |
        grep -v -e '"@rpath/' -e '"/usr/lib/' -e '"/System/' || true)
    [ -z "$wrong_sonames" ] || die "Wine would open these libraries from a build path:
$wrong_sonames"
}

build_wine() {
    step_done wine-build && return 0
    log "Build Wine"
    make -C "$WINE_BUILD_DIR" -j"$JOBS"
    mark_step_done wine-build
}

install_wine() {
    log "Install Wine into $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/share"
    make -C "$WINE_BUILD_DIR" install-lib
}

# ---------------------------------------------------------------- 6. bundle

is_macho() { file -b "$1" | grep -q 'Mach-O'; }

list_output_machos() {
    find "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" -type f \( -perm -100 -o -name '*.so' -o -name '*.dylib' \) | while read -r output_file; do
        is_macho "$output_file" && echo "$output_file"
    done
}

# rpath_for <Mach-O in the output>: the rpath that points at <output>/lib.
rpath_for() {
    case "$1" in
        "$OUTPUT_DIR"/bin/*) echo "@loader_path/../lib" ;;
        "$OUTPUT_DIR"/lib/wine/*/*) echo "@loader_path/../.." ;;
        "$OUTPUT_DIR"/lib/gstreamer-1.0/*) echo "@loader_path/.." ;;
        *) echo "@loader_path" ;;
    esac
}

add_rpath_once() {
    otool -l "$2" | grep -q "path $1 (offset" || install_name_tool -add_rpath "$1" "$2"
}

# find_library_source <dependency path>: the staged or Homebrew file for a dependency.
find_library_source() {
    library_file_name=$(basename "$1")
    for library_candidate in "$1" "$STAGE_DIR/lib/$library_file_name" "$(gstreamer_prefix)/lib/$library_file_name"; do
        case "$library_candidate" in @*) continue ;; esac
        [ -f "$library_candidate" ] && { echo "$library_candidate"; return 0; }
    done
    return 1
}

# copy_x86_64 <source Mach-O> <destination>: copy only the x86_64 part of a universal file.
copy_x86_64() {
    if lipo -archs "$1" 2>/dev/null | grep -q ' '; then
        lipo "$1" -thin x86_64 -output "$2"
    else
        cp -L "$1" "$2"
    fi
    chmod u+w "$2"
}

# copy_library_to_output <source file>: copy into <output>/lib with an @rpath install name.
copy_library_to_output() {
    copied_library="$OUTPUT_DIR/lib/$(basename "$1")"
    [ -f "$copied_library" ] && return 1
    copy_x86_64 "$1" "$copied_library"
    install_name_tool -id "@rpath/$(basename "$1")" "$copied_library"
    return 0
}

# relink_macho <file>: copy its non-system libraries into <output>/lib and point it at them.
# Prints "copied <name>" for each new library and "missing <file> <dependency>" on failure.
relink_macho() {
    chmod u+w "$1"
    own_install_name=$(install_name_of "$1")
    otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dependency_path; do
        [ "$dependency_path" = "$own_install_name" ] && continue
        case "$dependency_path" in
            /usr/lib/*|/System/*) continue ;;
            *.dylib) ;;
            *) continue ;;
        esac
        dependency_name=$(basename "$dependency_path")
        if [ ! -f "$OUTPUT_DIR/lib/$dependency_name" ]; then
            if ! dependency_source=$(find_library_source "$dependency_path"); then
                echo "missing $1 $dependency_path"
                continue
            fi
            copy_library_to_output "$dependency_source" && echo "copied $dependency_name"
        fi
        [ "$dependency_path" = "@rpath/$dependency_name" ] ||
            install_name_tool -change "$dependency_path" "@rpath/$dependency_name" "$1"
    done
    case "$own_install_name" in
        "$WORK_DIR"/*|"$BREW_PREFIX"/*) install_name_tool -id "@rpath/$(basename "$1")" "$1" ;;
    esac
    add_rpath_once "$(rpath_for "$1")" "$1"
}

bundle_libraries() {
    log "Bundle libraries"
    gstreamer_library_prefix=$(gstreamer_prefix)
    grep '^#define SONAME_' "$WINE_BUILD_DIR/include/config.h" | sed -n 's|.*"@rpath/\(.*\)".*|\1|p' | while read -r opened_library; do
        copy_library_to_output "$STAGE_DIR/lib/$opened_library" || true
    done
    mkdir -p "$OUTPUT_DIR/lib/gstreamer-1.0"
    for gstreamer_plugin in "$gstreamer_library_prefix"/lib/gstreamer-1.0/*.dylib; do
        copy_x86_64 "$gstreamer_plugin" "$OUTPUT_DIR/lib/gstreamer-1.0/$(basename "$gstreamer_plugin")"
    done

    relink_log="$WORK_DIR/relink.log"
    relink_pass=1
    while :; do
        log "Relink pass $relink_pass"
        list_output_machos | while read -r output_macho; do relink_macho "$output_macho"; done > "$relink_log"
        if grep '^missing ' "$relink_log" >&2; then
            die "some libraries were not found"
        fi
        grep -q '^copied ' "$relink_log" || break
        relink_pass=$((relink_pass + 1))
    done

    list_output_machos | while read -r output_macho; do
        codesign --force --sign - "$output_macho" 2>/dev/null || true
    done
}

copy_licenses() {
    log "Copy licences"
    license_dir="$OUTPUT_DIR/share/doc"
    mkdir -p "$license_dir/wine" "$license_dir/moltenvk" "$license_dir/freetype" "$license_dir/gnutls" "$license_dir/sdl2" "$license_dir/gstreamer"
    cp "$SOURCE_ROOT/COPYING.LIB" "$SOURCE_ROOT/LICENSE" "$SOURCE_ROOT/AUTHORS" "$license_dir/wine/"
    cp "$STAGE_DIR/MoltenVK-LICENSE" "$license_dir/moltenvk/LICENSE"
    cp "$SOURCES_DIR/sources/freetype/LICENSE.TXT" "$SOURCES_DIR/sources/freetype/docs/FTL.TXT" "$license_dir/freetype/"
    cp "$GNUTLS_SOURCE_DIR/LICENSE" "$GNUTLS_SOURCE_DIR/doc/COPYING.LESSER" "$license_dir/gnutls/"
    cp "$NETTLE_SOURCE_DIR/COPYING.LESSERv3" "$license_dir/gnutls/nettle-COPYING.LESSERv3"
    cp "$SOURCES_DIR/sources/gnutls/gmp/COPYING.LESSERv3" "$license_dir/gnutls/gmp-COPYING.LESSERv3"
    cp "$BREW_PREFIX"/opt/sdl2/LICENSE* "$license_dir/sdl2/" 2>/dev/null || true
    echo "GStreamer $(dep gstreamer.version) from $(dep gstreamer.runtime_url) (LGPL-2.1)" > "$license_dir/gstreamer/SOURCE.txt"
}

write_build_info() {
    {
        echo "source: $(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "crossover: $(dep crossover.version)"
        echo "llvm-mingw: $(dep llvm_mingw.version)"
        echo "gstreamer: $(dep gstreamer.version)"
        echo "macos-sdk: $(xcrun --show-sdk-version)"
        echo "xcode: $(xcodebuild -version | head -n 1)"
        # shellcheck disable=SC2086
        "$BREW_PREFIX/bin/brew" list --versions $BUILD_FORMULAS $RUNTIME_FORMULAS | sed 's/^/homebrew: /'
    } > "$OUTPUT_DIR/share/wine/siliconcellar-build-info.txt"
}

# ---------------------------------------------------------------- 7. smoke tests

# run_with_timeout <seconds> <command...>
run_with_timeout() {
    timeout_seconds=$1
    shift
    "$@" &
    command_pid=$!
    ( sleep "$timeout_seconds" && kill "$command_pid" 2>/dev/null ) &
    watchdog_pid=$!
    command_status=0
    wait "$command_pid" || command_status=$?
    kill "$watchdog_pid" 2>/dev/null || true
    return "$command_status"
}

build_probes() {
    probe_output_dir="$WORK_DIR/probe"
    mkdir -p "$probe_output_dir"
    for probe_name in boolean-args child-args; do
        x86_64-w64-mingw32-clang -O2 -o "$probe_output_dir/$probe_name.exe" "$SOURCE_ROOT/build/probe/$probe_name.c"
    done
}

smoke_tests() {
    log "Smoke tests"
    smoke_prefix=$(mktemp -d "${TMPDIR:-/tmp}/sc-engine-prefix.XXXXXX")
    export WINEPREFIX="$smoke_prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
    wine_binary="$OUTPUT_DIR/bin/wine"

    wine_version=$("$wine_binary" --version)
    echo "$wine_version"
    case "$wine_version" in wine-11.0*) ;; *) die "unexpected Wine version: $wine_version" ;; esac

    run_with_timeout 900 "$wine_binary" wineboot --init || die "wineboot --init failed"
    "$OUTPUT_DIR/bin/wineserver" -w

    build_probes
    for probe_name in boolean-args child-args; do
        run_with_timeout 300 "$wine_binary" "$WORK_DIR/probe/$probe_name.exe" || die "probe $probe_name failed"
    done
    "$OUTPUT_DIR/bin/wineserver" -k || true

    bad_links=$(list_output_machos | while read -r output_macho; do
        otool -L "$output_macho" | tail -n +2 | grep -e "$BREW_PREFIX/" -e "$WORK_DIR" | sed "s|^|$output_macho: |"
    done || true)
    [ -z "$bad_links" ] || die "libraries still point at build paths:
$bad_links"
    rm -rf "$smoke_prefix"
}

# ---------------------------------------------------------------- main

check_tools
fetch_inputs
build_libraries
configure_wine
build_wine
install_wine
bundle_libraries
copy_licenses
write_build_info
if [ "${SC_SKIP_SMOKE_TESTS:-0}" = "1" ]; then
    log "Smoke tests skipped (SC_SKIP_SMOKE_TESTS=1)"
else
    smoke_tests
fi
log "Engine ready in $OUTPUT_DIR"

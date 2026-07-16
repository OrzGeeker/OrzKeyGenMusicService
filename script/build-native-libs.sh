#!/usr/bin/env bash
# ============================================================================
# OrzAudioKit Native Library Build Script
# ============================================================================
# Compiles audio decoder libraries from source for the host platform.
# Reuses downloaded sources from .wasm-build/ (shared with WASM build).
# Outputs .a files to .wasm-build/native/ for SPM static linking.
#
# Zero system dependency — no brew install, no apt install.
# Version-locked — same versions as WASM build (libopenmpt 0.8.0, etc.)
# Cross-platform — same script works on macOS ARM/x64 and Linux.
#
# Usage:
#   ./script/build-native-libs.sh              # Build all libraries
#   ./script/build-native-libs.sh --only-openmpt # Build only libopenmpt
#   ./script/build-native-libs.sh --clean       # Clean native artifacts
# ============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.wasm-build"
SRC_DIR="$BUILD_DIR/src"
NATIVE_DIR="$BUILD_DIR/native"
CACHE_DIR="$BUILD_DIR/cache"

JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}
HOST_CC=${CC:-clang}
HOST_CXX=${CXX:-clang++}

# Detect host architecture for --host flag in configure
detect_host() {
    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$arch" in
        x86_64)  echo "x86_64-unknown-${os}-gnu" ;;
        arm64)   echo "aarch64-apple-${os}" ;;
        aarch64) echo "aarch64-unknown-${os}-gnu" ;;
        *)       echo "$arch-unknown-${os}" ;;
    esac
}
HOST=$(detect_host)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${GREEN}[BUILD]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERR]${NC} %s\n" "$*"; exit 1; }

CLEAN=false
ONLY_LIB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN=true; shift ;;
        --only-*) ONLY_LIB="${1#--only-}"; shift ;;
        *) err "Unknown option: $1" ;;
    esac
done

mkdir -p "$NATIVE_DIR"

if $CLEAN; then
    log "Cleaning native build artifacts..."
    rm -rf "$NATIVE_DIR" "$BUILD_DIR/build-*-native"
    log "Done."
    exit 0
fi

# ============================================================================
# libopenmpt (autotools) — XM, MOD, IT, S3M, MO3, MTM, FC13, FC14
# ============================================================================
build_libopenmpt() {
    log "Building libopenmpt..."
    local src_dir="$SRC_DIR/libopenmpt"
    local build_dir="$BUILD_DIR/build-libopenmpt-native"
    local output="$NATIVE_DIR/libopenmpt.a"

    if [ ! -f "$src_dir/configure" ]; then
        warn "libopenmpt source not found at $src_dir"
        return 1
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    log "Configuring libopenmpt (native)..."
    CC="$HOST_CC" CXX="$HOST_CXX" \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        --disable-examples \
        --disable-tests \
        --disable-openmpt123 \
        --without-mpg123 \
        --without-ogg \
        --without-vorbis \
        --without-vorbisfile \
        --without-portaudio \
        --without-sdl2 \
        --without-flac \
        --without-zlib \
        >/dev/null 2>&1 || {
            warn "libopenmpt configure failed"
            popd >/dev/null
            return 1
        }

    log "Compiling libopenmpt..."
    make -j"$JOBS" >/dev/null 2>&1 || {
        warn "libopenmpt make failed"
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    # Find the .a file
    local libfile=""
    for try in "$build_dir/.libs/libopenmpt.a" "$build_dir/libopenmpt.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libopenmpt.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libopenmpt.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# Game Music Emu (cmake) — NSF, SPC
# ============================================================================
build_libgme() {
    log "Building Game Music Emu..."
    local src_dir="$SRC_DIR/game-music-emu"
    local build_dir="$BUILD_DIR/build-gme-native"
    local output="$NATIVE_DIR/libgme.a"

    if [ ! -d "$src_dir" ]; then
        warn "GME source not found at $src_dir"
        return 1
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    CC="$HOST_CC" CXX="$HOST_CXX" \
    cmake "$src_dir" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DENABLE_UBSAN=OFF \
        -DGME_ENABLE_SPC=ON \
        -DGME_ENABLE_NSF=ON \
        -DGME_ENABLE_GBS=OFF \
        -DGME_ENABLE_GYM=OFF \
        -DGME_ENABLE_HES=OFF \
        >/dev/null 2>&1 || {
            warn "GME cmake failed"
            popd >/dev/null
            return 1
        }

    make -j"$JOBS" >/dev/null 2>&1 || {
        warn "GME make failed"
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/gme/libgme.a" "$build_dir/libgme.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libgme.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libgme.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# libsidplayfp (autotools) — SID
# ============================================================================
build_libsidplayfp() {
    log "Building libsidplayfp..."
    local src_dir="$SRC_DIR/libsidplayfp"
    local build_dir="$BUILD_DIR/build-sidplayfp-native"
    local output="$NATIVE_DIR/libsidplayfp.a"

    if [ ! -f "$src_dir/configure" ]; then
        warn "libsidplayfp source not found at $src_dir"
        return 1
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    log "Configuring libsidplayfp (native)..."
    CC="$HOST_CC" CXX="$HOST_CXX" \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        >/dev/null 2>&1 || {
            warn "libsidplayfp configure failed"
            popd >/dev/null
            return 1
        }

    log "Compiling libsidplayfp..."
    make -j"$JOBS" >/dev/null 2>&1 || {
        warn "libsidplayfp make failed"
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/src/.libs/libsidplayfp.a" "$build_dir/libsidplayfp.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libsidplayfp.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libsidplayfp.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# libbinio (autotools) — binary I/O, dependency of AdPlug
# ============================================================================
build_libbinio() {
    log "Building libbinio..."
    local src_dir="$SRC_DIR/libbinio"
    local build_dir="$BUILD_DIR/build-libbinio-native"
    local output="$NATIVE_DIR/liblibbinio.a"

    # Download source if not present
    local BINIO_VERSION="1.5"
    local BINIO_URL="https://github.com/adplug/libbinio/releases/download/libbinio-${BINIO_VERSION}/libbinio-${BINIO_VERSION}.tar.gz"

    if [ ! -f "$src_dir/configure" ]; then
        warn "libbinio source not found at $src_dir, need to download"
        mkdir -p "$SRC_DIR/libbinio"
        curl -sL "$BINIO_URL" | tar xz -C "$SRC_DIR/libbinio" --strip-components=1 2>/dev/null || {
            warn "libbinio download failed"
            return 1
        }
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    CC="$HOST_CC" CXX="$HOST_CXX" \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        >/dev/null 2>&1 || {
            warn "libbinio configure failed"
            popd >/dev/null
            return 1
        }

    make -j"$JOBS" >/dev/null 2>&1 || {
        warn "libbinio make failed"
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/src/.libs/liblibbinio.a" "$build_dir/liblibbinio.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "liblibbinio.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "liblibbinio.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# AdPlug (autotools) — OPL2/3 formats (RAD, D00, HSC)
# ============================================================================
build_adplug() {
    log "Building AdPlug..."
    local src_dir="$SRC_DIR/adplug"
    local build_dir="$BUILD_DIR/build-adplug-native"
    local output="$NATIVE_DIR/libadplug.a"

    if [ ! -f "$src_dir/configure" ]; then
        warn "AdPlug source not found at $src_dir"
        return 1
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    # AdPlug needs libbinio
    local binio_prefix="$BUILD_DIR/build-libbinio-native"

    CC="$HOST_CC" CXX="$HOST_CXX" \
    CPPFLAGS="-I$binio_prefix" \
    LDFLAGS="-L$binio_prefix/src/.libs" \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        --with-binio="$binio_prefix" \
        >/dev/null 2>&1 || {
            warn "AdPlug configure failed"
            popd >/dev/null
            return 1
        }

    make -j"$JOBS" >/dev/null 2>&1 || {
        warn "AdPlug make failed"
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/src/.libs/libadplug.a" "$build_dir/libadplug.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libadplug.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libadplug.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}


# ============================================================================
# sc68 (Atari ST YM / Amiga format) — manual .c compilation
# ============================================================================
build_libsc68() {
    log "Building sc68..."
    local src_dir="$SRC_DIR/sc68"
    local build_dir="$BUILD_DIR/build-sc68-native"
    local output="$NATIVE_DIR/libsc68.a"

    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/api68/api68.h" ]; then
        warn "sc68 source not found at $src_dir"
        return 1
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    local C_FILES=()
    # 只编译库核心模块，排除 sc68/（CLI 工具，含 main()）
    for d in api68 emu68 file68 io68 unice68; do
        for f in "$src_dir/$d"/*.c; do
            [ -f "$f" ] && C_FILES+=("$f")
        done
    done
    # 添加 rsc68 存根（替换原版 rsc68，避免依赖原始 SC68 资源管理）
    [ -f "$src_dir/file68/rsc68_stub.c" ] && C_FILES+=("$src_dir/file68/rsc68_stub.c")

    if [ ${#C_FILES[@]} -eq 0 ]; then
        warn "No sc68 source files found"
        popd >/dev/null; return 1
    fi

    local inc_flags="-I$src_dir -I$src_dir/file68 -I$src_dir/api68"
    # EMSCRIPTEN_KEEPALIVE 在原生编译时定义为空
    local cflags="-Wno-pointer-sign -Wno-incompatible-function-pointer-types -O3 -DEMSCRIPTEN_KEEPALIVE= -DEMSCRIPTEN=1"
    local compile_ok=0
    for cfile in "${C_FILES[@]}"; do
        local basename="${cfile##*/}"
        local dirpart="${cfile%/*}"
        local subdir="${dirpart##*/}"
        local objname="${subdir}_${basename%.c}.o"
        $HOST_CC -c "$cfile" -o "$objname" $inc_flags $cflags 2>/dev/null && compile_ok=$((compile_ok + 1))
    done

    local objs=( *.o )
    if [ ${#objs[@]} -eq 0 ]; then
        warn "No sc68 object files produced"
        popd >/dev/null; return 1
    fi

    ar cr "$output" "${objs[@]}" 2>/dev/null && ranlib "$output" 2>/dev/null
    log "libsc68.a → $output (${#objs[@]} objects, ${compile_ok}/${#C_FILES[@]} compiled)"
    echo "$NATIVE_DIR"
}

# ============================================================================
# ASAP (Atari POKEY format: sap) — requires xasm 6502 assembler
# ============================================================================
build_libasap() {
    log "Building ASAP..."
    local src_dir="$SRC_DIR/asap"
    local build_dir="$BUILD_DIR/build-asap-native"
    local output="$NATIVE_DIR/libasap.a"

    if [ ! -f "$src_dir/asap.h" ]; then
        warn "ASAP source not found at $src_dir"
        return 1
    fi

    # ASAP 的 asap.c 是预生成的（从 .fu 文件），可以直接编译
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    $HOST_CC -c "$src_dir/asap.c" -o asap.o -I"$src_dir" -O2 2>/dev/null || {
        warn "ASAP compile failed"; popd >/dev/null; return 1
    }
    ar cr "$output" asap.o 2>/dev/null && ranlib "$output" 2>/dev/null
    log "libasap.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# uade / UAE Amiga emulator (AHX, FC14 formats)
# ============================================================================
build_libuade() {
    log "Building uade (UAE Amiga emulator core)..."
    local src_dir="$SRC_DIR/uade"
    local build_dir="$BUILD_DIR/build-uade-native"
    local output="$NATIVE_DIR/libuade.a"

    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/newcpu.c" ]; then
        warn "UAE core source not available at $src_dir, trying uade-3.05..."
        src_dir="$SRC_DIR/uade-3.05/src"
        [ ! -f "$src_dir/newcpu.c" ] && { warn "UAE core not found"; return 1; }
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    local uade_core_files=(
        newcpu.c memory.c custom.c cia.c audio.c missing.c
        readcpu.c sd-sound-generic.c
    )

    # 首先生成 68000 CPU 指令表
    local cpustbl_src=""
    local gen_dir="$BUILD_DIR/src/uade"
    if [ -d "$gen_dir" ] && [ -f "$gen_dir/cpustbl.c" ]; then
        cpustbl_src="$gen_dir"
    else
        # 用 uade-3.05 完整源码生成
        local uade_src="$SRC_DIR/uade-3.05"
        if [ -f "$uade_src/src/build68k.c" ] && [ -f "$uade_src/src/table68k" ]; then
            log "Generating 68000 CPU tables..."
            $HOST_CC -o "${build_dir}/build68k" "$uade_src/src/build68k.c" \
                -I"$uade_src/src" -I"$uade_src/src/include" \
                -include "$uade_src/src/sysconfig.h" -lm 2>/dev/null || {
                warn "build68k compile failed"; popd >/dev/null; return 1
            }
            # 生成 CPU 表文件
            (cd "$uade_src/src" && "${build_dir}/build68k" > "${build_dir}/cpustbl.c" 2>/dev/null)
            if [ ! -s "${build_dir}/cpustbl.c" ] || [ "$(grep -c 'n_defs68k' "${build_dir}/cpustbl.c")" -eq 0 ]; then
                warn "build68k generated empty CPU table (uade will use stub)"
                # 创建空存根
                echo 'struct instr_def defs68k[] = {}; int n_defs68k = 0;' > "${build_dir}/cpustbl.c"
            fi
            cpustbl_src="$build_dir"
        else
            warn "UAE source incomplete — build68k or table68k missing"
        fi
    fi

    local inc_dirs="-I$uade_src/src -I$uade_src/src/include"
    [ -n "$cpustbl_src" ] && inc_dirs="$inc_dirs -I$cpustbl_src"
    local cflags="-Dunlikely(x)=__builtin_expect((x),0) -O2"
    local compile_ok=0

    for f in "${uade_core_files[@]}"; do
        local src_file="$SRC_DIR/uade-3.05/src/$f"
        [ ! -f "$src_file" ] && continue
        local objname="${f//\//_}.o"
        $HOST_CC -c "$src_file" -o "$objname" $inc_dirs -include "$SRC_DIR/uade-3.05/src/sysconfig.h" $cflags 2>/dev/null && compile_ok=$((compile_ok + 1))
    done
    # 编译 CPU 表（如果生成了）
    if [ -n "$cpustbl_src" ] && [ -f "$cpustbl_src/cpustbl.c" ]; then
        $HOST_CC -c "$cpustbl_src/cpustbl.c" -o cpustbl.o $inc_dirs -include "$SRC_DIR/uade-3.05/src/sysconfig.h" -O2 2>/dev/null && compile_ok=$((compile_ok + 1))
    fi

    [ $compile_ok -eq 0 ] && { warn "No UAE core files compiled"; popd >/dev/null; return 1; }

    local objs=( *.o )
    ar cr "$output" "${objs[@]}" 2>/dev/null && ranlib "$output" 2>/dev/null
    log "libuade.a → $output (${#objs[@]} objects)"
    echo "$NATIVE_DIR"
}

# ============================================================================
# v2m-player (Farbrausch V2 format: v2m)
# ============================================================================
build_libv2m() {
    log "Building v2m-player..."
    local src_dir="$SRC_DIR/v2m"
    local build_dir="$BUILD_DIR/build-v2m-native"
    local output="$NATIVE_DIR/libv2m.a"

    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/src/synth_core.cpp" ]; then
        warn "v2m-player source not found at $src_dir"
        return 1
    fi

    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    # Compile all v2m source files (与 WASM 构建保持一致)
    local objs=""
    for f in v2mplayer.cpp v2mconv.cpp sounddef.cpp ronan.cpp synth_core.cpp; do
        local src="$src_dir/src/$f"
        if [ -f "$src" ]; then
            local obj_name="${f%.cpp}.o"
            $HOST_CXX -c "$src" -o "$build_dir/$obj_name" \
                -I"$src_dir/src" -O2 2>/dev/null || {
                warn "v2m $f compile failed"; continue
            }
            objs="$objs $build_dir/$obj_name"
        fi
    done
    if [ -z "$objs" ]; then
        warn "v2m no source files compiled"; popd >/dev/null; return 1
    fi
    ar cr "$output" $objs 2>/dev/null && ranlib "$output" 2>/dev/null

    if [ -f "$output" ]; then
        log "libv2m.a → $output ($(du -h "$output" | cut -f1))"
        echo "$NATIVE_DIR"
    else
        warn "v2m build produced no .a file"
        return 1
    fi
}


# ============================================================================
# Main: build requested libraries
# ============================================================================

if [ -n "$ONLY_LIB" ]; then
    log "Building only: $ONLY_LIB"
    case "$ONLY_LIB" in
        openmpt)     build_libopenmpt ;;
        gme)         build_libgme ;;
        sidplayfp)   build_libsidplayfp ;;
        binio)       build_libbinio ;;
        adplug)      build_libbinio && build_adplug ;;
        sc68)        build_libsc68 ;;
        asap)        build_libasap ;;
        uade)        build_libuade ;;
        v2m)         build_libv2m ;;
        *)           err "Unknown library: $ONLY_LIB" ;;
    esac
else
    log "Building all native libraries..."

    build_libopenmpt || warn "libopenmpt build failed (will use stub)"

    build_libgme || warn "libgme build failed (will use stub)"

    build_libsidplayfp || warn "libsidplayfp build failed (will use stub)"

    build_libbinio || warn "libbinio build failed"
    build_adplug || warn "AdPlug build failed (will use stub)"
    build_libsc68 || warn "sc68 build failed (will use stub)"
    build_libasap || warn "ASAP build failed (will use stub)"
    build_libuade || warn "uade build failed (will use stub)"
    build_libv2m || warn "v2m build failed (will use stub)"
fi

log "=== Native libraries built ==="
ls -lh "$NATIVE_DIR"/*.a 2>/dev/null || echo "(no .a files)"
echo ""
log "Next: update Package.swift with -L$NATIVE_DIR and remove decoder excludes"

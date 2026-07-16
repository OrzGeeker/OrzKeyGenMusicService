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
        *)           err "Unknown library: $ONLY_LIB" ;;
    esac
else
    log "Building all native libraries..."

    build_libopenmpt || warn "libopenmpt build failed (will use stub)"

    build_libgme || warn "libgme build failed (will use stub)"

    build_libsidplayfp || warn "libsidplayfp build failed (will use stub)"

    build_libbinio || warn "libbinio build failed"
    build_adplug || warn "AdPlug build failed (will use stub)"
fi

log "=== Native libraries built ==="
ls -lh "$NATIVE_DIR"/*.a 2>/dev/null || echo "(no .a files)"
echo ""
log "Next: update Package.swift with -L$NATIVE_DIR and remove decoder excludes"

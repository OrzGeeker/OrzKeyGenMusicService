#!/usr/bin/env bash
# ============================================================================
# OrzAudioKit WASM Build Script
# ============================================================================
# Builds libopenmpt and other audio libraries to WebAssembly for browser-side
# chiptune playback without server CPU usage.
#
# Prerequisites:
#   - Emscripten SDK (emsdk) installed and activated
#   - cmake, make, pkg-config
#
# Usage:
#   ./script/build-wasm.sh                    # Build all
#   ./script/build-wasm.sh --only-openmpt     # Build only libopenmpt
#   ./script/build-wasm.sh --clean            # Clean build artifacts
#
# Output:
#   Resources/Public/audio/orz_audio.wasm     # WASM binary
#   Resources/Public/audio/orz_audio.js       # JS glue code
# ============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/Resources/Public/audio"
BUILD_DIR="$PROJECT_DIR/.wasm-build"
CACHE_DIR="$BUILD_DIR/cache"

LIBOPENMPT_VERSION="0.7.11"
LIBOPENMPT_URL="https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-${LIBOPENMPT_VERSION}+release.autotools.tar.gz"

# Game Music Emu — 用于 NSF/SPC 格式
GME_VERSION="0.6.3"
GME_URL="https://github.com/libgme/game-music-emu/archive/refs/tags/${GME_VERSION}.tar.gz"

JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[WASM]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
err()  { echo -e "${RED}[ERR]${NC} $1" >&2; exit 1; }

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
ONLY_OPENMPT=false
CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --only-openmpt) ONLY_OPENMPT=true ;;
        --clean) CLEAN=true ;;
        *) warn "Unknown argument: $arg" ;;
    esac
done

# ------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------
if $CLEAN; then
    log "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    log "Done."
    exit 0
fi

# ------------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------------
check_prereqs() {
    if ! command -v emcmake &>/dev/null; then
        err "Emscripten SDK not found. Install it first:
  git clone https://github.com/emscripten-core/emsdk.git
  cd emsdk
  ./emsdk install latest
  ./emsdk activate latest
  source ./emsdk_env.sh"
    fi

    if ! command -v cmake &>/dev/null; then
        err "cmake is required. Install with: brew install cmake"
    fi

    if ! command -v gzip &>/dev/null && ! command -v tar &>/dev/null; then
        err "tar and gzip are required."
    fi

    log "Emscripten: $(emcc --version | head -1)"
    log "cmake:      $(cmake --version | head -1)"
}

# ------------------------------------------------------------------
# Download source
# ------------------------------------------------------------------
download_source() {
    local url="$1"
    local name="$2"
    local dest="$CACHE_DIR/${name}.tar.gz"
    local src_dir="$BUILD_DIR/src/${name}"

    if [ -d "$src_dir" ]; then
        log "Source $name already downloaded, skipping."
        echo "$src_dir"
        return
    fi

    mkdir -p "$(dirname "$dest")" "$src_dir"

    if [ ! -f "$dest" ]; then
        log "Downloading $name..."
        curl -fsSL "$url" -o "$dest" || err "Failed to download $name"
    fi

    log "Extracting $name..."
    tar xzf "$dest" -C "$src_dir" --strip-components=1 2>/dev/null || \
        tar xzf "$dest" -C "$src_dir" 2>/dev/null || \
        err "Failed to extract $name"

    echo "$src_dir"
}

# ------------------------------------------------------------------
# Build libopenmpt (module player: .xm, .mod, .it, .s3m, etc.)
# ------------------------------------------------------------------
build_libopenmpt() {
    log "Building libopenmpt ${LIBOPENMPT_VERSION}..."

    local src_dir
    src_dir=$(download_source "$LIBOPENMPT_URL" "libopenmpt" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/configure" ]; then
        warn "libopenmpt source not available at $src_dir, trying alternate..."
        # Try to download again via a different method
        src_dir="$BUILD_DIR/src/libopenmpt"
        if [ ! -f "$src_dir/configure" ]; then
            warn "Cannot build libopenmpt - source unavailable"
            echo ""
            return
        fi
    fi

    local build_dir="$BUILD_DIR/libopenmpt"
    mkdir -p "$build_dir"

    pushd "$build_dir" >/dev/null || err "Cannot enter build dir"

    # Configure with Emscripten (autotools, not CMake)
    log "Configuring libopenmpt with Emscripten..."
    emconfigure "$src_dir/configure" \
        --host=wasm32-unknown-emscripten \
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
        CC=emcc CXX=em++ \
        --prefix="$build_dir/install" \
        2>&1 || {
            warn "libopenmpt configure failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building libopenmpt..."
    emmake make -j"$JOBS" 2>&1 || {
        warn "libopenmpt make failed"
        popd >/dev/null
        echo ""
        return
    }

    popd >/dev/null
    echo "$build_dir"
}

# ------------------------------------------------------------------
# Build Game Music Emu (NSF, SPC)
# ------------------------------------------------------------------
build_libgme() {
    log "Building Game Music Emu ${GME_VERSION}..."

    local src_dir
    src_dir=$(download_source "$GME_URL" "game-music-emu" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/CMakeLists.txt" ]; then
        warn "gme source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/gme"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || { warn "Cannot enter gme build dir"; echo ""; return; }

    log "Configuring game-music-emu with Emscripten..."
    emcmake cmake "$src_dir" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DGME_ENABLE_SPC=ON \
        -DGME_ENABLE_NSF=ON \
        -DGME_ENABLE_GBS=OFF \
        -DGME_ENABLE_GYM=OFF \
        -DGME_ENABLE_HES=OFF \
        -Wno-dev \
        2>&1 || {
            warn "gme cmake failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building game-music-emu..."
    emmake make -j"$JOBS" 2>&1 || {
        warn "gme make failed"
        popd >/dev/null
        echo ""
        return
    }

    popd >/dev/null

    # 返回 gme 库和头文件路径
    local lib_path=$(find "$build_dir" -name "libgme.a" 2>/dev/null | head -1)
    if [ -z "$lib_path" ]; then
        warn "libgme.a not found in $build_dir"
        echo ""
        return
    fi

    # 找到头文件目录
    local inc_path=$(find "$src_dir" -name "gme.h" -exec dirname {} \; 2>/dev/null | head -1)
    if [ -z "$inc_path" ]; then
        inc_path="$build_dir"
    fi

    echo "$lib_path|$inc_path"
}

# ------------------------------------------------------------------
# Generate WASM wrapper
# ------------------------------------------------------------------
generate_wrapper() {
    local libopenmpt_dir="$1"
    local gme_result="$2"  # "lib_path|inc_path" or empty

    # Parse gme result
    local gme_lib=""
    local gme_inc=""
    if [ -n "$gme_result" ]; then
        gme_lib="${gme_result%%|*}"
        gme_inc="${gme_result#*|}"
    fi

    # 构建源文件和库列表
    local source_files=()
    local libs=()
    local inc_dirs=()

    # C 源文件路径（复用 Sources/OrzAudioKit/ 中的统一解码层）
    local ORZ_SRC="$PROJECT_DIR/Sources/OrzAudioKit"
    source_files=(
        "$ORZ_SRC/orz_dispatch.c"
        "$ORZ_SRC/openmpt_impl.c"
        "$ORZ_SRC/audio_engine.c"
    )
    inc_dirs+=("$ORZ_SRC/include")

    # libopenmpt
    if [ -n "$libopenmpt_dir" ]; then
        local libopenmpt_wasm=""
        for try_path in \
            "$libopenmpt_dir/libopenmpt.a" \
            "$libopenmpt_dir/.libs/libopenmpt.a" \
            "$libopenmpt_dir/src/libopenmpt/.libs/libopenmpt.a" \
            "$libopenmpt_dir/install/lib/libopenmpt.a"; do
            if [ -f "$try_path" ]; then
                libopenmpt_wasm="$try_path"
                break
            fi
        done
        if [ -z "$libopenmpt_wasm" ]; then
            libopenmpt_wasm=$(find "$libopenmpt_dir" -name "libopenmpt.a" 2>/dev/null | head -1 || echo "")
        fi
        if [ -n "$libopenmpt_wasm" ]; then
            libs+=("$libopenmpt_wasm")
        fi

        local openmpt_inc=""
        for try_inc in \
            "$libopenmpt_dir/../include" \
            "$libopenmpt_dir/install/include" \
            "$BUILD_DIR/src/libopenmpt/libopenmpt"; do
            if [ -f "$try_inc/libopenmpt/libopenmpt.h" ]; then
                openmpt_inc="$try_inc"
                break
            elif [ -f "$try_inc/libopenmpt.h" ]; then
                openmpt_inc="$(dirname "$try_inc")"
                break
            fi
        done
        if [ -n "$openmpt_inc" ]; then
            inc_dirs+=("$openmpt_inc")
        fi
    fi

    # Game Music Emu
    if [ -n "$gme_lib" ]; then
        source_files+=("$ORZ_SRC/gme_impl.c")
        libs+=("$gme_lib")
        if [ -n "$gme_inc" ]; then
            inc_dirs+=("$gme_inc")
        fi
    fi

    if [ ${#libs[@]} -eq 0 ]; then
        warn "No decoder libraries found, creating stub WASM binary."
        cat > "$BUILD_DIR/stub.c" << 'STUBC'
#include <emscripten.h>

EMSCRIPTEN_KEEPALIVE
int orz_audio_is_ready() { return 1; }

EMSCRIPTEN_KEEPALIVE
const char* orz_audio_version() { return "OrzAudioKit WASM v0.1.0 (stub)"; }
STUBC
        emcc "$BUILD_DIR/stub.c" \
            -O3 \
            -s WASM=1 \
            -s MODULARIZE=1 \
            -s EXPORT_NAME="OrzAudioKit" \
            -s EXPORTED_RUNTIME_METHODS='["ccall", "cwrap", "getValue", "setValue"]' \
            -s EXPORTED_FUNCTIONS='["_orz_audio_is_ready", "_orz_audio_version"]' \
            -s ALLOW_MEMORY_GROWTH=1 \
            -o "$OUTPUT_DIR/orz_audio.js"
        return
    fi

    # 构建包含标志
    local inc_flags=""
    for dir in "${inc_dirs[@]}"; do
        inc_flags="$inc_flags -I$dir"
    done

    log "Linking WASM with libraries: ${libs[*]}"

    emcc "${source_files[@]}" "${libs[@]}" \
        $inc_flags \
        -s WASM=1 \
        -s MODULARIZE=1 \
        -s EXPORT_NAME="OrzAudioKit" \
        -s EXPORTED_RUNTIME_METHODS='["ccall", "cwrap", "getValue", "setValue", "UTF8ToString", "stringToUTF8", "lengthBytesUTF8"]' \
        -s EXPORTED_FUNCTIONS='["_orz_load", "_orz_get_duration", "_orz_get_sample_rate", "_orz_get_channels", "_orz_render", "_orz_destroy", "_orz_audio_can_decode", "_malloc", "_free"]' \
        -s INITIAL_MEMORY=67108864 \
        --no-entry \
        -O3 \
        -o "$OUTPUT_DIR/orz_audio.js"

    log "WASM module created:"
    ls -lh "$OUTPUT_DIR/orz_audio.wasm" "$OUTPUT_DIR/orz_audio.js" 2>/dev/null || true
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
main() {
    mkdir -p "$OUTPUT_DIR" "$BUILD_DIR" "$CACHE_DIR"

    check_prereqs

    local libopenmpt_dir=""
    if ! $ONLY_OPENMPT; then
        # Try to build libopenmpt
        libopenmpt_dir=$(build_libopenmpt 2>&1)
        if [ -z "$libopenmpt_dir" ] || [ ! -f "$libopenmpt_dir/libopenmpt.a" -a ! -f "$libopenmpt_dir/.libs/libopenmpt.a" ]; then
            warn "libopenmpt build failed or library not found, creating stub..."
            libopenmpt_dir=""
        fi
    fi

    # Try to build Game Music Emu (nsf, spc)
    local gme_result=""
    gme_result=$(build_libgme 2>&1)
    if [ -z "$gme_result" ]; then
        warn "game-music-emu build failed, NSF/SPC formats will not be available"
    fi

    generate_wrapper "$libopenmpt_dir" "$gme_result"

    log "Build complete!"
    log "WASM output: $OUTPUT_DIR/orz_audio.wasm"
    log "JS glue:     $OUTPUT_DIR/orz_audio.js"
    log ""
    log "To use in the frontend, include in your HTML:"
    log '  <script src="/audio/orz_audio.js"></script>'
}

main "$@"

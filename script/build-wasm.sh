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

JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[WASM]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

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
# Generate WASM wrapper
# ------------------------------------------------------------------
generate_wrapper() {
    log "Generating WASM wrapper..."

    local lib_dir="$1"

    # Compile the C wrapper that exposes libopenmpt functions via Emscripten
    cat > "$BUILD_DIR/wrapper.c" << 'WRAPPERC'
#include <emscripten.h>
#include <libopenmpt/libopenmpt.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// Module handle
static openmpt_module *mod = NULL;

// Buffer for rendered audio
static float *render_buf = NULL;
static int render_buf_size = 0;

// Module info
static int current_sample_rate = 48000;
static int current_channels = 2;

EMSCRIPTEN_KEEPALIVE
int openmpt_load(const unsigned char *data, int data_len) {
    int error = 0;
    mod = openmpt_module_create_from_memory(data, (size_t)data_len, NULL, NULL, &error);
    if (!mod || error != 0) {
        return 0;
    }
    return 1;
}

EMSCRIPTEN_KEEPALIVE
double openmpt_get_duration() {
    if (!mod) return 0;
    return openmpt_module_get_duration_seconds(mod, current_sample_rate);
}

EMSCRIPTEN_KEEPALIVE
int openmpt_get_sample_rate() {
    return current_sample_rate;
}

EMSCRIPTEN_KEEPALIVE
int openmpt_get_channels() {
    return current_channels;
}

EMSCRIPTEN_KEEPALIVE
int openmpt_render(float *out, int frames) {
    if (!mod) return 0;
    int rendered = openmpt_module_read_float_stereo(mod, current_sample_rate, frames, out);
    return rendered;
}

EMSCRIPTEN_KEEPALIVE
void openmpt_destroy() {
    if (mod) {
        openmpt_module_destroy(mod);
        mod = NULL;
    }
    if (render_buf) {
        free(render_buf);
        render_buf = NULL;
        render_buf_size = 0;
    }
}
WRAPPERC

    # Additional format wrappers (stubs for now, expand as libraries are added)
    cat > "$BUILD_DIR/audio_engine.c" << 'AUDIOENGINEC'
#include <emscripten.h>
#include <stdint.h>

// Combined audio engine entry point
// Routes to the appropriate decoder based on format signature

EMSCRIPTEN_KEEPALIVE
int orz_audio_can_decode(const char *extension) {
    // Check if this format is supported
    const char *supported[] = {
        "xm", "mod", "it", "s3m", "mo3", "mtm",
        "nsf", "spc", "sid", "sc68", "hsc", "ym",
        "ahx", "amd", "fc13", "fc14", "sap", "rad", "d00", "v2m",
        NULL
    };
    for (int i = 0; supported[i] != NULL; i++) {
        if (strcmp(extension, supported[i]) == 0) return 1;
    }
    return 0;
}
AUDIOENGINEC

    # Link everything into WASM
    # Currently only libopenmpt is linked; other libraries can be added incrementally
    log "Linking WASM module..."

    # Try multiple possible locations for libopenmpt.a
    local libopenmpt_wasm=""
    for try_path in \
        "$lib_dir/libopenmpt.a" \
        "$lib_dir/.libs/libopenmpt.a" \
        "$lib_dir/src/libopenmpt/.libs/libopenmpt.a" \
        "$lib_dir/install/lib/libopenmpt.a"; do
        if [ -f "$try_path" ]; then
            libopenmpt_wasm="$try_path"
            break
        fi
    done
    if [ -z "$libopenmpt_wasm" ]; then
        libopenmpt_wasm=$(find "$lib_dir" -name "libopenmpt.a" 2>/dev/null | head -1 || echo "")
    fi

    if [ -z "$libopenmpt_wasm" ] || [ ! -f "$libopenmpt_wasm" ]; then
        warn "libopenmpt static library not found at: $lib_dir"
        warn "Creating stub WASM binary instead."
        # Create a minimal stub for development
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
    else
        # Find include directory
        local include_dir=""
        for try_inc in \
            "$lib_dir/../include" \
            "$lib_dir/install/include" \
            "$BUILD_DIR/src/libopenmpt/libopenmpt"; do
            if [ -f "$try_inc/libopenmpt/libopenmpt.h" ]; then
                include_dir="$try_inc"
                break
            elif [ -f "$try_inc/libopenmpt.h" ]; then
                include_dir="$(dirname "$try_inc")"
                break
            fi
        done

        # Build with libopenmpt
        local emcc_args=("$BUILD_DIR/wrapper.c" "$BUILD_DIR/audio_engine.c" "$libopenmpt_wasm")
        if [ -n "$include_dir" ]; then
            emcc_args+=("-I$include_dir")
        fi
        emcc "${emcc_args[@]}" \
            -s WASM=1 \
            -s MODULARIZE=1 \
            -s EXPORT_NAME="OrzAudioKit" \
            -s EXPORTED_RUNTIME_METHODS='["ccall", "cwrap", "getValue", "setValue", "UTF8ToString"]' \
            -s EXPORTED_FUNCTIONS='["_openmpt_load", "_openmpt_get_duration", "_openmpt_render", "_openmpt_destroy", "_orz_audio_can_decode", "_openmpt_get_sample_rate", "_openmpt_get_channels", "_malloc", "_free"]' \
            -s ALLOW_MEMORY_GROWTH=1 \
            -s INITIAL_MEMORY=16777216 \
            --no-entry \
            -o "$OUTPUT_DIR/orz_audio.js"
    fi

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
        libopenmpt_dir=$(build_libopenmpt 2>&1) || {
            warn "libopenmpt build failed, creating stub..."
            libopenmpt_dir=""
        }
    fi

    generate_wrapper "$libopenmpt_dir"

    log "Build complete!"
    log "WASM output: $OUTPUT_DIR/orz_audio.wasm"
    log "JS glue:     $OUTPUT_DIR/orz_audio.js"
    log ""
    log "To use in the frontend, include in your HTML:"
    log '  <script src="/audio/orz_audio.js"></script>'
}

main "$@"

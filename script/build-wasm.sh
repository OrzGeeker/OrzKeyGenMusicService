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

LIBOPENMPT_VERSION="0.8.0"
LIBOPENMPT_URL="https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-${LIBOPENMPT_VERSION}+release.autotools.tar.gz"

# Game Music Emu — 用于 NSF/SPC 格式
GME_VERSION="0.6.3"
GME_URL="https://github.com/libgme/game-music-emu/archive/refs/tags/${GME_VERSION}.tar.gz"

# libsidplayfp — 用于 SID (Commodore 64) 格式
SIDPLAYFP_VERSION="3.0.2"
SIDPLAYFP_URL="https://github.com/libsidplayfp/libsidplayfp/releases/download/v${SIDPLAYFP_VERSION}/libsidplayfp-${SIDPLAYFP_VERSION}.tar.gz"

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
# Decompress LHa YM archives
# ------------------------------------------------------------------
decompress_ym_files() {
    local lha_bin="/opt/homebrew/opt/lhasa/bin/lha"
    if [ ! -x "$lha_bin" ]; then
        warn "lha not installed - ym files will not be decompressed"
        return
    fi

    local raw_dir="$BUILD_DIR/ym-raw"
    local public_ym_raw="$OUTPUT_DIR/ym-raw"
    mkdir -p "$raw_dir" "$public_ym_raw"

    # 解压单个 YM 文件（如果是 LHa 归档）
    decompress_one_ym() {
        local ymfile="$1" outfile="$2"
        if [ -f "$outfile" ] && head -c 4 "$outfile" | grep -q "YM[0-9]"; then
            return 0  # 已解压
        fi
        log "Decompressing: $(basename "$ymfile")"
        local tmpdir=$(mktemp -d)
        (cd "$tmpdir" && "$lha_bin" x "$ymfile" >/dev/null 2>&1)
        local extracted=$(find "$tmpdir" -type f 2>/dev/null | head -1)
        if [ -n "$extracted" ]; then
            mkdir -p "$(dirname "$outfile")"
            cp "$extracted" "$outfile"
            log "  -> $(wc -c < "$outfile") bytes raw YM"
        else
            warn "  -> extraction failed for $(basename "$ymfile")"
        fi
        rm -rf "$tmpdir"
    }

    # 从 keygenmusic/ 解压（保留子目录结构）
    find "$PROJECT_DIR/Public/keygenmusic" -name "*.ym" -type f 2>/dev/null | while read -r ymfile; do
        if ! head -c 4 "$ymfile" | grep -q "YM[0-9]"; then
            local relpath="${ymfile#$PROJECT_DIR/Public/keygenmusic/}"
            decompress_one_ym "$ymfile" "$raw_dir/$relpath"
        fi
    done

    # 从 music/ 解压（flat 文件名直接放到 ym-raw/）
    find "$PROJECT_DIR/music" -name "*.ym" -type f 2>/dev/null | while read -r ymfile; do
        if ! head -c 4 "$ymfile" | grep -q "YM[0-9]"; then
            decompress_one_ym "$ymfile" "$raw_dir/$(basename "$ymfile")"
        fi
    done

    # 复制到公开 web 目录
    if [ -d "$raw_dir" ]; then
        rm -rf "$public_ym_raw"
        cp -R "$raw_dir" "$public_ym_raw"
        local count=$(find "$public_ym_raw" -name '*.ym' -type f 2>/dev/null | wc -l)
        log "Decompressed YM files: $count in $public_ym_raw"
    fi
}

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
        --prefix="$build_dir/install" || {
            warn "libopenmpt configure failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building libopenmpt..."
    emmake make -j"$JOBS" || {
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
        -DENABLE_UBSAN=OFF \
        -DGME_ENABLE_SPC=ON \
        -DGME_ENABLE_NSF=ON \
        -DGME_ENABLE_GBS=OFF \
        -DGME_ENABLE_GYM=OFF \
        -DGME_ENABLE_HES=OFF \
        -Wno-dev || {
            warn "gme cmake failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building game-music-emu..."
    emmake make -j"$JOBS" || {
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

    # 找到头文件目录 — gme.h 在 gme/gme.h，需父目录
    local inc_path=$(find "$src_dir" -name "gme.h" -exec dirname {} \; 2>/dev/null | head -1)
    if [ -n "$inc_path" ]; then
        inc_path="$(dirname "$inc_path")"  # 升到包含 gme/ 子目录的目录
    else
        inc_path="$build_dir"
    fi

    echo "$lib_path|$inc_path"
}

# ------------------------------------------------------------------
# Build libsc68 (Atari ST YM / Amiga formats: sc68, ym)
# ------------------------------------------------------------------
build_libsc68() {
    log "Building libsc68 (photonstorm fork)..."

    local src_dir="$BUILD_DIR/src/sc68"
    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/api68/api68.h" ]; then
        warn "sc68 source not available at $src_dir"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/sc68"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null || { warn "Cannot enter build dir"; echo ""; return; }

    # 收集所有 .c 源文件（排除 emscripten 目录下的 adapter.c）
    local C_FILES=()
    for d in api68 emu68 file68 io68 unice68 sc68; do
        for f in "$src_dir/$d"/*.c; do
            [ -f "$f" ] && C_FILES+=("$f")
        done
    done

    if [ ${#C_FILES[@]} -eq 0 ]; then
        warn "No sc68 source files found"
        popd >/dev/null
        echo ""
        return
    fi

    local inc_flags="-I$src_dir -I$src_dir/emscripten -I$src_dir/file68 -I$src_dir/api68"
    log "Compiling ${#C_FILES[@]} sc68 source files..."
    local compiled=0
    for cfile in "${C_FILES[@]}"; do
        local basename="${cfile##*/}"
        local dirpart="${cfile%/*}"
        local subdir="${dirpart##*/}"
        # 用子目录名作前缀避免同名文件冲突（如 emu68/error68.c → emu68_error68.o）
        local objname="${subdir}_${basename%.c}.o"
        emcc -c "$cfile" \
            -o "$objname" \
            $inc_flags \
            -Wno-pointer-sign \
            -Wno-incompatible-function-pointer-types \
            -O3 \
            -D EMSCRIPTEN \
            -D 'EMSCRIPTEN_KEEPALIVE=__attribute__((used))' \
            -s WASM=1 2>/dev/null || {
                warn "Failed to compile $cfile"
                continue
            }
        compiled=$((compiled + 1))
    done

    # 打包为静态库
    local objs=( *.o )
    if [ ${#objs[@]} -gt 0 ]; then
        emar cr libsc68.a "${objs[@]}"
        emranlib libsc68.a
        log "sc68 library created: libsc68.a (${#objs[@]} objects)"
    else
        warn "No object files produced"
        popd >/dev/null
        echo ""
        return
    fi

    popd >/dev/null
    echo "$build_dir/libsc68.a|$src_dir"
}

# ------------------------------------------------------------------
# Build libsidplayfp (SID format)
# ------------------------------------------------------------------
build_libsidplayfp() {
    log "Building libsidplayfp ${SIDPLAYFP_VERSION}..."

    local src_dir
    src_dir=$(download_source "$SIDPLAYFP_URL" "libsidplayfp" 2>/dev/null || echo "")

    if [ -z "$src_dir" ] || [ ! -f "$src_dir/configure" ]; then
        warn "libsidplayfp source not available"
        echo ""
        return
    fi

    local build_dir="$BUILD_DIR/sidplayfp"
    mkdir -p "$build_dir"

    log "Configuring libsidplayfp with Emscripten..."
    pushd "$build_dir" >/dev/null || { warn "Cannot enter build dir"; echo ""; return; }

    emconfigure "$src_dir/configure" \
        --host=wasm32-unknown-emscripten \
        --disable-shared \
        --enable-static \
        --disable-silent-rules \
        CC=emcc CXX=em++ \
        --prefix="$build_dir/install" || {
            warn "libsidplayfp configure failed"
            popd >/dev/null
            echo ""
            return
        }

    log "Building libsidplayfp..."
    emmake make -j"$JOBS" || {
        warn "libsidplayfp make failed"
        popd >/dev/null
        echo ""
        return
    }

    popd >/dev/null

    # 查找 lib .a 文件
    local lib_path=$(find "$build_dir" -name "libsidplayfp.a" 2>/dev/null | head -1)
    if [ -z "$lib_path" ]; then
        warn "libsidplayfp.a not found"
        echo ""
        return
    fi

    # 查找 include 目录 — sidplayfp.h 在 sidplayfp/ 子目录中
    local inc_h_path=$(find "$src_dir" -name "sidplayfp.h" -exec dirname {} \; 2>/dev/null | head -1)
    if [ -n "$inc_h_path" ]; then
        inc_path="$(dirname "$inc_h_path")"  # 升一级到包含 sidplayfp/ 的目录
    fi

    echo "$lib_path|$inc_path"
}

# ------------------------------------------------------------------
# Generate WASM wrapper
# ------------------------------------------------------------------
generate_wrapper() {
    local libopenmpt_dir="$1"
    local gme_result="$2"  # "lib_path|inc_path" or empty
    local sidplayfp_result="$3"  # "lib_path|inc_path" or empty

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
        "$ORZ_SRC/gme_impl.c"
        "$ORZ_SRC/asap_impl.c"
        "$ORZ_SRC/audio_engine.c"
        "$ORZ_SRC/cxx_helpers.cpp"
        # adplug (AdLib OPL2/3)
        "$ORZ_SRC/adplug_impl.c"
        "$ORZ_SRC/adplug_wrap.cpp"
        # sc68 (Atari ST YM / Amiga)
        "$ORZ_SRC/sc68_impl.c"
        # ym6 (Atari ST YM2149 raw frames)
        "$ORZ_SRC/ym6_impl.c"
        # v2m-player (V2M format)
        "$ORZ_SRC/v2m_wasm.cpp"
        "$ORZ_SRC/v2mplayer_wasm.cpp"
    )

    # v2m synth_core.cpp（在 v2m 源码目录中）
    local v2m_synth_core="$BUILD_DIR/src/v2m/synth_core.cpp"
    if [ -f "$v2m_synth_core" ]; then
        source_files+=("$v2m_synth_core")
    fi
    inc_dirs+=("$ORZ_SRC/include")
    inc_dirs+=("$BUILD_DIR")       # ASAP 头文件 (asap.h)
    # libopenmpt 头文件（0.8.0 头文件在 libopenmpt/libopenmpt.h）
    if [ -d "$BUILD_DIR/src/libopenmpt/libopenmpt" ]; then
        inc_dirs+=("$BUILD_DIR/src/libopenmpt")
    fi
    # v2m-player 头文件
    # adplug 头文件
    # libbinio 头文件
    if [ -d "$BUILD_DIR/libbinio-install/include" ]; then
        inc_dirs+=("$BUILD_DIR/libbinio-install/include")
    fi
    if [ -d "$BUILD_DIR/src/adplug/src" ]; then
        inc_dirs+=("$BUILD_DIR/src/adplug/src")
    fi
    if [ -d "$BUILD_DIR/src/v2m" ]; then
        inc_dirs+=("$BUILD_DIR/src")           # v2m/types.h, v2m/synth.h 等
        inc_dirs+=("$BUILD_DIR/src/v2m")       # types.h, synth.h, v2mplayer.h (短名引用)
    fi
    # sc68 头文件
    if [ -d "$BUILD_DIR/src/sc68" ]; then
        inc_dirs+=("$BUILD_DIR/src/sc68")           # api68/api68.h
        inc_dirs+=("$BUILD_DIR/src/sc68/api68")     # api68.h (fallback)
        inc_dirs+=("$BUILD_DIR/src/sc68/file68")    # file68/*.h
        inc_dirs+=("$BUILD_DIR/src/sc68")           # config68.h etc
    fi

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
        libs+=("$gme_lib")
        if [ -n "$gme_inc" ]; then
            inc_dirs+=("$gme_inc")
        fi
    fi

    # libsc68 (Atari ST YM / Amiga)
    local sc68_result=""
    local sc68_a=$(find "$BUILD_DIR/sc68" -name "libsc68.a" 2>/dev/null | head -1)
    if [ -n "$sc68_a" ]; then
        local sc68_src_dir=$(find "$BUILD_DIR/src/sc68" -maxdepth 0 -type d 2>/dev/null)
        sc68_result="${sc68_a}|${sc68_src_dir}"
        log "Using cached libsc68: $sc68_a"
    else
        sc68_result=$(build_libsc68)
    fi

    local sc68_lib=""
    local sc68_inc=""
    if [ -n "$sc68_result" ]; then
        sc68_lib="${sc68_result%%|*}"
        sc68_inc="${sc68_result#*|}"
        libs+=("$sc68_lib")
        if [ -n "$sc68_inc" ]; then
            inc_dirs+=("$sc68_inc")
            inc_dirs+=("$sc68_inc/api68")
            inc_dirs+=("$sc68_inc/file68")
            inc_dirs+=("$sc68_inc/emscripten")
        fi
    else
        warn "libsc68 build failed, sc68/ym formats will not be available"
    fi

    # ASAP (Atari POKEY)
    local asap_lib="$BUILD_DIR/libasap_wasm.a"
    if [ -f "$asap_lib" ]; then
        libs+=("$asap_lib")
        log "ASAP library found: $asap_lib"
    else
        warn "ASAP library not found at $asap_lib, sap format will not be available"
    fi

    # libsidplayfp (C++ wrapper)
    local sidplayfp_lib=""
    local sidplayfp_inc_raw=""
    if [ -n "$sidplayfp_result" ]; then
        sidplayfp_lib="${sidplayfp_result%%|*}"
        sidplayfp_inc_raw="${sidplayfp_result#*|}"
        source_files+=("$ORZ_SRC/sidplayfp_impl.cpp")
        libs+=("$sidplayfp_lib")
        if [ -n "$sidplayfp_inc_raw" ]; then
            # 支持多个 include 路径 (用 | 分隔)
            IFS='|' read -ra inc_parts <<< "$sidplayfp_inc_raw"
            for part in "${inc_parts[@]}"; do
                if [ -n "$part" ] && [ -d "$part" ]; then
                    inc_dirs+=("$part")
                fi
            done
        fi
    fi

    # adplug (AdLib OPL2/3)
    local adplug_lib="$BUILD_DIR/adplug/src/libadplug.a"
    local binio_lib="$BUILD_DIR/libbinio/src/liblibbinio.a"
    if [ -f "$adplug_lib" ]; then
        libs+=("$adplug_lib")
        log "AdPlug library found: $adplug_lib"
        if [ -f "$binio_lib" ]; then
            libs+=("$binio_lib")
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
        -s EXPORTED_RUNTIME_METHODS='["ccall", "cwrap", "getValue", "setValue", "UTF8ToString", "stringToUTF8", "lengthBytesUTF8", "HEAPU8", "HEAP32"]' \
        -s EXPORTED_FUNCTIONS='["_orz_load", "_orz_get_duration", "_orz_get_sample_rate", "_orz_get_channels", "_orz_render", "_orz_destroy", "_orz_audio_can_decode", "_malloc", "_free"]' \
        -s INITIAL_MEMORY=268435456 \
        -s ALLOW_MEMORY_GROWTH=1 \
        -s DISABLE_EXCEPTION_CATCHING=0 \
        -D __stdcall= \
        -D '__int64=long long' \
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

    # Decompress LHa YM archives to raw YM6
    decompress_ym_files

    # ── libopenmpt ──
    local libopenmpt_dir=""
    local libopenmpt_a=""
    local -a openmpt_candidates=(
        "$BUILD_DIR/libopenmpt/.libs/libopenmpt.a"
        "$BUILD_DIR/libopenmpt/libopenmpt.a"
        "$BUILD_DIR/libopenmpt/src/libopenmpt/.libs/libopenmpt.a"
    )
    for f in "${openmpt_candidates[@]}"; do
        if [ -f "$f" ]; then
            libopenmpt_a="$f"
            libopenmpt_dir="$(dirname "$f")"
            # 如果 .libs 下找到，目录同级
            if [[ "$f" == *"/.libs/"* ]]; then
                libopenmpt_dir="$(dirname "$(dirname "$f")")"
            elif [[ "$f" == */install/lib/* ]]; then
                libopenmpt_dir="$(dirname "$(dirname "$(dirname "$f")")")"
            fi
            break
        fi
    done
    if [ -z "$libopenmpt_a" ]; then
        log "libopenmpt .a not cached, building from source..."
        libopenmpt_dir=$(build_libopenmpt)
        if [ -z "$libopenmpt_dir" ] || [ ! -f "$libopenmpt_dir/.libs/libopenmpt.a" -a ! -f "$libopenmpt_dir/libopenmpt.a" ]; then
            warn "libopenmpt build failed, stub only"
            libopenmpt_dir=""
        fi
    else
        log "Using cached libopenmpt: $libopenmpt_a"
    fi

    # ── Game Music Emu ──
    local gme_result=""
    local gme_lib_path=$(find "$BUILD_DIR/gme" -name "libgme.a" 2>/dev/null | head -1)
    # gme 头文件以 #include <gme/gme.h> 引用 → -I 需指向含 gme/ 子目录的父目录
    local gme_inc_path=""
    # 从可能的源目录中查找正确的 include 父目录
    for d in "$BUILD_DIR/src/game-music-emu" "$BUILD_DIR/src/gme"; do
        if [ -f "$d/gme/gme.h" ]; then
            gme_inc_path="$d"
            break
        fi
    done
    if [ -n "$gme_lib_path" ]; then
        gme_result="${gme_lib_path}|${gme_inc_path}"
        log "Using cached game-music-emu: $gme_lib_path"
        log "  gme include path: $gme_inc_path"
    else
        gme_result=$(build_libgme)
    fi
    if [ -z "$gme_result" ]; then
        warn "game-music-emu build failed, NSF/SPC formats will not be available"
    fi

    # ── libsidplayfp ──
    local sidplayfp_result=""
    local sid_a=$(find "$BUILD_DIR/sidplayfp" -name "libsidplayfp.a" 2>/dev/null | head -1)
    local sid_inc_src=""
    local sid_h_path=$(find "$BUILD_DIR/src/libsidplayfp" -name "sidplayfp.h" 2>/dev/null | head -1)
    if [ -n "$sid_h_path" ]; then
        sid_inc_src="$(dirname "$(dirname "$sid_h_path")")"
    fi
    # 生成的头文件（如 sidversion.h）在 build 输出中
    local sid_inc_build="$BUILD_DIR/sidplayfp/src"
    # sidlite builder 头文件
    local sid_inc_sidlite="$BUILD_DIR/src/libsidplayfp/src/builders/sidlite-builder"
    # 合并多个 include 路径，用 | 分隔用于 generate_wrapper 解析
    local sid_inc=""
    for inc in "$sid_inc_src" "$sid_inc_build" "$sid_inc_sidlite"; do
        if [ -n "$inc" ] && [ -d "$inc" ]; then
            if [ -z "$sid_inc" ]; then
                sid_inc="$inc"
            else
                sid_inc="$sid_inc|$inc"
            fi
        fi
    done

    if [ -n "$sid_a" ]; then
        sidplayfp_result="${sid_a}|${sid_inc}"
        log "Using cached libsidplayfp: $sid_a"
    else
        sidplayfp_result=$(build_libsidplayfp)
    fi
    if [ -z "$sidplayfp_result" ]; then
        warn "libsidplayfp build failed, SID format will not be available"
    fi

    generate_wrapper "$libopenmpt_dir" "$gme_result" "$sidplayfp_result"

    log "Build complete!"
    log "WASM output: $OUTPUT_DIR/orz_audio.wasm"
    log "JS glue:     $OUTPUT_DIR/orz_audio.js"
    log ""
    log "To use in the frontend, include in your HTML:"
    log '  <script src="/audio/orz_audio.js"></script>'
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ORZ_AUDIO_CORE_SERVER_DIR:-$ROOT/.audio-core-sdk/server}"
LOCK="$ROOT/audio-core-sdk.lock.json"
HEADER="$SDK/native/include/orz_audio_core.h"
case "$(uname -s)" in
  Darwin) LIB="$SDK/native/lib/libOrzAudioCore.dylib" ;;
  Linux) LIB="$SDK/native/lib/libOrzAudioCore.so" ;;
  *) echo "Unsupported native SDK verification platform: $(uname -s)" >&2; exit 1 ;;
esac
MANIFEST="$SDK/metadata/decoder-manifest.json"
BUILD_INFO="$SDK/metadata/build-info.json"

for required in "$HEADER" "$LIB" "$MANIFEST" "$BUILD_INFO"; do
  test -s "$required" || { echo "Missing server SDK file: $required" >&2; exit 1; }
done

expected_version="$(node -p "require('$LOCK').version")"
manifest_version="$(node -p "require('$MANIFEST').sdkVersion")"
build_version="$(node -p "require('$BUILD_INFO').sdkVersion")"
test "$manifest_version" = "$expected_version"
test "$build_version" = "$expected_version"

grep -q '#define ORZ_ABI_VERSION_MAJOR 1u' "$HEADER"
grep -q 'orz_decoder_create_memory' "$HEADER"
grep -q 'orz_decoder_render_f32' "$HEADER"

if [[ "$(uname -s)" = Linux ]]; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/orz-audio-core-consumer.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  cc -std=c11 -Wall -Wextra -Werror \
    -I"$SDK/native/include" "$ROOT/Tests/SDK/abi_consumer.c" \
    -L"$SDK/native/lib" -Wl,-rpath,"$SDK/native/lib" -lOrzAudioCore -lz \
    -o "$work/abi-consumer"
  "$work/abi-consumer"

  exports="$(nm -D --defined-only "$LIB" | awk '{print $3}' | sed 's/@@.*//' | grep '^orz_' | sort)"
  expected="$(printf '%s\n' \
    orz_abi_version orz_build_info orz_decoder_cancel orz_decoder_create_memory \
    orz_decoder_destroy_v1 orz_decoder_get_stream_info orz_decoder_render_f32 \
    orz_decoder_reset orz_decoder_seek orz_decoder_select_subsong_v1 \
    orz_get_format_count orz_get_format_info orz_probe orz_status_message | sort)"
  if [[ "$exports" != "$expected" ]]; then
    echo "Server SDK does not export exactly the ABI v1 symbol set" >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$exports") >&2 || true
    exit 1
  fi
  unexpected="$(nm -D --defined-only "$LIB" | awk '{print $3}' | grep -vE '^(ORZ_AUDIO_CORE_|orz_)' || true)"
  if [[ -n "$unexpected" ]]; then
    echo "Server SDK publicly exports third-party symbols" >&2
    printf '%s\n' "$unexpected" >&2
    exit 1
  fi
fi

if [[ "$(uname -s)" = Darwin ]]; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/orz-audio-core-consumer.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  cc -std=c11 -Wall -Wextra -Werror \
    -I"$SDK/native/include" "$ROOT/Tests/SDK/abi_consumer.c" \
    -L"$SDK/native/lib" -Wl,-rpath,"$SDK/native/lib" -lOrzAudioCore -lz \
    -o "$work/abi-consumer"
  "$work/abi-consumer"

  exports="$(nm -gjU "$LIB" | sed 's/^_//' | grep '^orz_' | sort)"
  expected="$(printf '%s\n' \
    orz_abi_version orz_build_info orz_decoder_cancel orz_decoder_create_memory \
    orz_decoder_destroy_v1 orz_decoder_get_stream_info orz_decoder_render_f32 \
    orz_decoder_reset orz_decoder_seek orz_decoder_select_subsong_v1 \
    orz_get_format_count orz_get_format_info orz_probe orz_status_message | sort)"
  test "$exports" = "$expected" || {
    echo "Native SDK does not export exactly the ABI v1 symbol set" >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$exports") >&2 || true
    exit 1
  }
fi

printf 'Verified OrzAudioCore %s %s native SDK metadata, ABI and exports\n' "$expected_version" "$(uname -s)"

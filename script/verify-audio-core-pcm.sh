#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ORZ_AUDIO_CORE_SERVER_DIR:-$ROOT/.audio-core-sdk/server}"
BUILD="${ORZ_AUDIO_CORE_EMBEDDED_BUILD:-$ROOT/.cmake-build/linux-x86_64}"
REPORT="${ORZ_AUDIO_CORE_PCM_REPORT:-$ROOT/.audio-core-sdk/pcm-conformance.json}"
PROBE="${TMPDIR:-/tmp}/orz-audio-core-pcm-probe"

test "$(uname -s)" = Linux || { echo "PCM dual-track verification requires Linux" >&2; exit 2; }
test -s "$SDK/native/lib/libOrzAudioCore.so"
test -s "$BUILD/libOrzAudioCore.so"

cc -std=c11 -Wall -Wextra -Werror \
  -I"$SDK/native/include" "$ROOT/Tests/SDK/pcm_probe.c" \
  -L"$SDK/native/lib" -Wl,-rpath,"$SDK/native/lib" -lOrzAudioCore -lz \
  -o "$PROBE"

node "$ROOT/script/compare-audio-core-pcm.mjs" \
  "$PROBE" "$BUILD" "$SDK/native/lib" Tests/SDK/pcm-fixtures.json "$REPORT"
printf 'Wrote OrzAudioCore PCM conformance report to %s\n' "$REPORT"

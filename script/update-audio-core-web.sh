#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/audio-core-sdk.lock.json"
OUT="$ROOT/Resources/Public/audio"

read_lock() { node -p "require('$LOCK').$1"; }
repo="$(read_lock repository)"
tag="$(read_lock tag)"
asset="$(read_lock webAsset)"
expected="$(read_lock webAssetSha256)"
work="$(mktemp -d "${TMPDIR:-/tmp}/orz-audio-core.XXXXXX")"
archive="$work/$asset"

curl -fsSL "$repo/releases/download/$tag/$asset" -o "$archive"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo "OrzAudioCore asset checksum mismatch: expected $expected, got $actual" >&2
  exit 1
fi

tar -xzf "$archive" -C "$work"
test -s "$work/package/wasm/orz_audio_builtin.js"
test -s "$work/package/wasm/orz_audio_builtin.wasm"
test -s "$work/package/wasm/orz_audio.js"
test -s "$work/package/wasm/orz_audio.wasm"
cp "$work/package/wasm/orz_audio_builtin.js" "$OUT/orz_audio_builtin.js"
cp "$work/package/wasm/orz_audio_builtin.wasm" "$OUT/orz_audio_builtin.wasm"
cp "$work/package/wasm/orz_audio.js" "$OUT/orz_audio.js"
cp "$work/package/wasm/orz_audio.wasm" "$OUT/orz_audio.wasm"

echo "Installed OrzAudioCore $(read_lock version) web assets ($expected)"

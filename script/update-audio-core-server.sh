#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/audio-core-sdk.lock.json"
DEST="${ORZ_AUDIO_CORE_SERVER_DIR:-$ROOT/.audio-core-sdk/server}"

read_json_string() {
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}
read_lock() { read_json_string "$LOCK" "$1"; }
repo="$(read_lock repository)"
tag="$(read_lock tag)"
version="$(read_lock version)"

machine="${ORZ_AUDIO_CORE_ARCH:-$(uname -m)}"
case "$machine" in
  x86_64|amd64)
    arch="x86_64"
    asset="$(read_lock serverAssetX86_64)"
    expected="$(read_lock serverAssetSha256X86_64)"
    ;;
  arm64|aarch64)
    arch="arm64"
    asset="$(read_lock serverAssetArm64)"
    expected="$(read_lock serverAssetSha256Arm64)"
    ;;
  *)
    echo "Unsupported OrzAudioCore server architecture: $machine" >&2
    exit 1
    ;;
esac

if [[ -z "$asset" || -z "$expected" ]]; then
  echo "Missing OrzAudioCore server asset lock for architecture: $arch" >&2
  exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/orz-audio-core-server.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/$asset"

curl -fsSL --retry 4 --retry-all-errors "$repo/releases/download/$tag/$asset" -o "$archive"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo "OrzAudioCore server asset checksum mismatch: expected $expected, got $actual" >&2
  exit 1
fi

mkdir -p "$work/unpacked"
tar -xzf "$archive" -C "$work/unpacked"
stage="$work/unpacked/OrzAudioCore-$version-linux-$arch"
test -s "$stage/native/lib/libOrzAudioCore.so"
test -s "$stage/native/include/orz_audio_core.h"
test -s "$stage/metadata/decoder-manifest.json"
test "$(read_json_string "$stage/metadata/decoder-manifest.json" sdkVersion)" = "$version"

rm -rf "$DEST.new"
mkdir -p "$(dirname "$DEST")"
mv "$stage" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
printf 'Installed OrzAudioCore %s Linux %s server SDK (%s)\n' "$version" "$arch" "$expected"

#!/bin/sh
# Build the pinned OpenMLS client library; no server component links this code.
set -eu
cd "$(dirname "$0")/.."
export CARGO_HOME="$PWD/.build/cargo-home"
export CARGO_TARGET_DIR="$PWD/.build/mls-native"
manifest="$PWD/Client/apple/MLS/native/Cargo.toml"
headers="$PWD/Client/apple/MLS/native/include"
targets="aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim"
case "${1:-}" in --host-only) targets=aarch64-apple-darwin ;; "") ;; *) echo 'Usage: prepare-mls.sh [--host-only]' >&2; exit 1 ;; esac
set --
for target in $targets; do
    cargo build --locked --release --manifest-path "$manifest" --target "$target"
    set -- "$@" -library "$CARGO_TARGET_DIR/$target/release/libchirp_mls_native.a" -headers "$headers"
done
# Notices include development dependencies, which release builds do not fetch.
cargo fetch --locked --manifest-path "$manifest" --target aarch64-apple-darwin
python3 scripts/prepare-mls-notices.py
mkdir -p "$PWD/.build/mls-framework" "$PWD/Client/apple/MLS/Artifacts"
staging=$(mktemp -d "$PWD/.build/mls-framework/build.XXXXXX")
xcodebuild -create-xcframework "$@" -output "$staging/ChirpMLSNative.xcframework"
python3 - "$staging/ChirpMLSNative.xcframework" "$PWD/Client/apple/MLS/Artifacts/ChirpMLSNative.xcframework" <<'PY'
from pathlib import Path
import shutil
import sys
source, target = map(Path, sys.argv[1:])
if target.exists():
    shutil.rmtree(target)
source.rename(target)
source.parent.rmdir()
PY

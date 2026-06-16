#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

MARTA_APP="${MARTA_APP:-/Applications/Marta.app}"
LUAKIT_PATH="$MARTA_APP/Contents/Frameworks/LuaKit.framework/Versions/Current"

if [[ ! -d "$MARTA_APP" ]]; then
    echo "Marta.app was not found at: $MARTA_APP" >&2
    echo "Install Marta with: brew install --cask marta" >&2
    exit 1
fi

if [[ ! -d "$LUAKIT_PATH" ]]; then
    echo "LuaKit.framework was not found at: $LUAKIT_PATH" >&2
    echo "This plugin currently expects Marta 0.8.2-style app layout." >&2
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "clang was not found. Install Xcode Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

ARCH_FLAGS=()
for arch in ${ARCHS:-arm64 x86_64}; do
    ARCH_FLAGS+=("-arch" "$arch")
done

clang \
    -shared \
    -fobjc-arc \
    -o libmartathumbs.so \
    -I"$LUAKIT_PATH/Resources/include" \
    -L"$LUAKIT_PATH/Frameworks" \
    -Wl,-rpath,"$LUAKIT_PATH/Frameworks" \
    -llua \
    -framework Cocoa \
    -framework QuickLookThumbnailing \
    -framework Quartz \
    -framework UniformTypeIdentifiers \
    -mmacosx-version-min=11.0 \
    "${ARCH_FLAGS[@]}" \
    martathumbs.m

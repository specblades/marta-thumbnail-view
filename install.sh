#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$SCRIPT_DIR/thumbnail-viewer"
MARTA_SUPPORT_DIR="${MARTA_SUPPORT_DIR:-$HOME/Library/Application Support/org.yanex.marta}"
PLUGIN_PARENT="$MARTA_SUPPORT_DIR/Plugins"
PLUGIN_DIR="$PLUGIN_PARENT/thumbnail-viewer"

if [[ ! -d "$PLUGIN_SRC" ]]; then
    echo "Cannot find plugin source: $PLUGIN_SRC" >&2
    exit 1
fi

mkdir -p "$PLUGIN_PARENT"

if [[ -e "$PLUGIN_DIR" ]]; then
    STAMP="$(date +%Y%m%d%H%M%S)"
    BACKUP_DIR="$PLUGIN_DIR.backup.$STAMP"
    echo "Backing up existing plugin to:"
    echo "  $BACKUP_DIR"
    cp -a "$PLUGIN_DIR" "$BACKUP_DIR"
fi

echo "Installing plugin to:"
echo "  $PLUGIN_DIR"
rsync -a --delete --exclude 'libmartathumbs.so' "$PLUGIN_SRC/" "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/build.bash"

echo "Building native library..."
"$PLUGIN_DIR/build.bash"

if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$PLUGIN_DIR" 2>/dev/null || true
fi

cat <<'TEXT'

Installed.

Next steps:
  1. Merge config.snippet.marco into:
     ~/Library/Application Support/org.yanex.marta/conf.marco
  2. Quit and reopen Marta.
TEXT

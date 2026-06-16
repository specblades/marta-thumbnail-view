#!/usr/bin/env bash
set -euo pipefail

MARTA_SUPPORT_DIR="${MARTA_SUPPORT_DIR:-$HOME/Library/Application Support/org.yanex.marta}"
PLUGIN_DIR="$MARTA_SUPPORT_DIR/Plugins/thumbnail-viewer"

if [[ -d "$PLUGIN_DIR" ]]; then
    echo "Removing plugin:"
    echo "  $PLUGIN_DIR"
    rm -rf "$PLUGIN_DIR"
else
    echo "Plugin is not installed:"
    echo "  $PLUGIN_DIR"
fi

if [[ "${1:-}" == "--prefs" ]]; then
    /usr/bin/defaults delete org.yanex.marta com.csaturnus.marta.thumbnailviewer.folderModes.v1 2>/dev/null || true
    /usr/bin/defaults delete org.yanex.marta com.csaturnus.marta.thumbnailviewer.cellWidth.v2 2>/dev/null || true
    echo "Removed saved Thumbnail View preferences."
fi

cat <<'TEXT'

Done.

Remove the Thumbnail View action, key bindings, and Extension column from
conf.marco manually if you added them.
TEXT

#!/usr/bin/env bash
# Install the plugin as a standalone copy in OpenCode's plugin directory (decoupled from this repo).
# Typechecks first, copies, verifies the copy by hash, and reminds you to restart OpenCode.
#
# Usage: install-plugin.sh            copy model-stats.ts into ~/.config/opencode/plugins/
#        install-plugin.sh --link     write a re-export shim pointing at this repo instead (dev mode)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${OPENCODE_PLUGIN_DIR:-$HOME/.config/opencode/plugins}"
DEST="$DEST_DIR/model-stats.ts"
SRC="$REPO/model-stats.ts"

(cd "$REPO" && npm run --silent typecheck)
mkdir -p "$DEST_DIR"
if [[ "${1:-}" == --link ]]; then
  printf 'export { ModelStats } from "%s"\n' "$SRC" > "$DEST"
  echo "wrote shim $DEST -> $SRC"
else
  cp "$SRC" "$DEST"
  [[ "$(shasum -a 256 < "$SRC")" == "$(shasum -a 256 < "$DEST")" ]] || { echo "copy verification failed" >&2; exit 1; }
  echo "installed $DEST ($(wc -c < "$DEST") bytes, sha256 ${SRC:+$(shasum -a 256 < "$SRC" | cut -c1-12)})"
fi
if [[ -f "$HOME/.config/opencode/package.json" ]]; then
  want=$(node -p "require('$REPO/package.json').devDependencies['@opencode-ai/plugin']")
  have=$(node -p "require('$HOME/.config/opencode/package.json').dependencies?.['@opencode-ai/plugin'] ?? 'none'")
  [[ "$want" == "$have" ]] || echo "note: @opencode-ai/plugin is $want here but $have in ~/.config/opencode/package.json (imports are type-only, so harmless today)"
fi
echo "restart OpenCode to load the new plugin code"

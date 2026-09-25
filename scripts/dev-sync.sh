#!/usr/bin/env bash
# Copy this working tree into the Omarchy plugin directory and reload the
# shell. Omarchy refuses to load a plugin folder containing symlinks, so
# development is a copy rather than a link.
#
#   scripts/dev-sync.sh               copy, validate, restart the shell
#   scripts/dev-sync.sh --no-restart  copy and validate only

set -euo pipefail

cd "$(dirname "$0")/.."

plugin_id=$(jq -r '.id // empty' manifest.json)
[ -n "$plugin_id" ] || { echo "could not read plugin id from manifest.json" >&2; exit 1; }

target="$HOME/.config/omarchy/plugins/$plugin_id"
mkdir -p "$target"

rsync -a --delete \
  --exclude '.git' \
  --exclude '.gitignore' \
  --exclude 'scripts' \
  --exclude 'tests' \
  --exclude 'preview.*' \
  --exclude 'assets' \
  --exclude '*.md' \
  ./ "$target/"

omarchy plugin validate "$target"
echo "synced to $target"

if [ "${1:-}" != "--no-restart" ]; then
  omarchy-restart-shell
  echo "shell restarted"
fi

echo
echo "enable it with:  omarchy plugin enable $plugin_id"

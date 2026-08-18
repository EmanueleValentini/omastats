#!/usr/bin/env bash
# Copy this working tree into the Omarchy plugin directory and reload the
# shell. Omarchy refuses to load a plugin folder containing symlinks, so
# development is a copy rather than a link.
#
#   ./dev-install.sh            copy, validate, restart the shell
#   ./dev-install.sh --no-restart   copy and validate only

set -euo pipefail

plugin_id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -1)
[ -n "$plugin_id" ] || { echo "could not read plugin id from manifest.json" >&2; exit 1; }

target="$HOME/.config/omarchy/plugins/$plugin_id"
mkdir -p "$target"

rsync -a --delete \
  --exclude '.git' \
  --exclude 'tests' \
  --exclude 'dev-install.sh' \
  --exclude '*.md' \
  ./ "$target/"

omarchy plugin validate "$target"
echo "installed to $target"

if [ "${1:-}" != "--no-restart" ]; then
  omarchy-restart-shell
  echo "shell restarted"
fi

echo
echo "enable it with:  omarchy plugin enable $plugin_id"

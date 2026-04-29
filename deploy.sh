#!/bin/bash
# Deploy somewm-one config to ~/.config/somewm
# Usage: ./deploy.sh [--dry-run]
#
# This copies the somewm-one project from the repo to the active config.
# Run after editing rc.lua or themes in this repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.config/somewm"

if [[ "${1:-}" == "--dry-run" ]]; then
    echo "Dry run — would sync:"
    rsync -av --delete --exclude 'deploy.sh' --exclude 'themes/*/user-wallpapers/' --exclude 'screen_scopes.json' --exclude '.active_theme' --exclude '.default_portrait' --exclude 'rc.lua.bak' --dry-run "$SCRIPT_DIR/" "$TARGET/"
    exit 0
fi

# Backup current config timestamp
if [[ -f "$TARGET/rc.lua" ]]; then
    echo "Backing up current rc.lua -> rc.lua.bak"
    cp "$TARGET/rc.lua" "$TARGET/rc.lua.bak"
fi

# Pre-deploy snapshot — optional, lives in the somewm fork checkout.
# Override SOMEWM_FORK_PATH to point at a different fork location;
# script is silently skipped if not present.
SNAPSHOT_SCRIPT="${SOMEWM_FORK_PATH:-$HOME/git/github/somewm}/plans/scripts/somewm-snapshot.sh"
if [[ -x "$SNAPSHOT_SCRIPT" ]]; then
    "$SNAPSHOT_SCRIPT" && echo "Pre-deploy snapshot saved" || true
fi

# Sync (exclude deploy.sh itself)
rsync -av --delete --exclude 'deploy.sh' --exclude 'themes/*/user-wallpapers/' --exclude 'screen_scopes.json' --exclude '.active_theme' --exclude '.default_portrait' --exclude 'rc.lua.bak' "$SCRIPT_DIR/" "$TARGET/"

echo ""
echo "Deployed somewm-one to $TARGET"
echo "Reload: somewm-client reload"
echo "   or:  Super+Ctrl+r (if bound)"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?Usage: scripts/sync_to_website.sh /path/to/aethernative-site}"
test -d "$TARGET/src/content/apps"
mkdir -p "$TARGET/src/content/apps/aethertransfer"
cp -R website_content/apps/aethertransfer/. "$TARGET/src/content/apps/aethertransfer/"
echo "Synced only aethertransfer product content. Run website checks before committing."

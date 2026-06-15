#!/usr/bin/env bash
# bp-init.sh — ensure the ccpraxis local data root exists and self-gitignores.
# Usage: bp-init.sh
#
# DUPLICATION NOTE: This file is deliberately duplicated across the blueprint
# and butler plugins (each must be self-contained under its own
# ${CLAUDE_PLUGIN_ROOT}). Keep this file byte-identical with its twin in the
# other plugin's scripts/ directory.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"

DATA=$(bp_data_dir)
mkdir -p "$DATA/blueprints"

# Self-gitignore: a .gitignore containing '*' makes git ignore the entire
# subtree (including this file) without touching the project's own .gitignore.
if [ ! -f "$DATA/.gitignore" ]; then
  printf '*\n' > "$DATA/.gitignore"
fi

echo "ccpraxis data root: $DATA"

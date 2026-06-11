#!/usr/bin/env bash
# bp-init.sh — ensure the ccpraxis local data root exists and self-gitignores.
# Usage: bp-init.sh
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

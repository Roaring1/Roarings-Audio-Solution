#!/usr/bin/env bash
set -euo pipefail

SRC="$HOME/Desktop/CarlaProject_Roaring.carxp"
DEST_DIR="$HOME/.local/share/roaring/carla-backups"
KEEP=20

[[ -f "$SRC" ]] || { echo "carxp not found: $SRC"; exit 1; }

mkdir -p "$DEST_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
cp "$SRC" "$DEST_DIR/CarlaProject_Roaring_${STAMP}.carxp"
echo "backed up: CarlaProject_Roaring_${STAMP}.carxp"

# Prune oldest, keep last $KEEP
ls -1t "$DEST_DIR"/*.carxp 2>/dev/null | tail -n +$(( KEEP + 1 )) | xargs -r rm --

#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="/home/caleb/.minecraft/resourcepacks/shader_mc"
TARGET_PARENT="/home/caleb/.minecraft/resourcepacks"

mkdir -p "$TARGET_PARENT"

if [ -e "$DEST_DIR" ] || [ -L "$DEST_DIR" ]; then
  rm -rf "$DEST_DIR"
fi

cp -a "$SRC_DIR" "$DEST_DIR"

echo "Installed shader pack to: $DEST_DIR"

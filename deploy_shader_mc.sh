#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_NAME="shader_mc"
TARGET_PARENT="${MINECRAFT_DIR:-$HOME/.minecraft}/resourcepacks"
DEST_DIR="$TARGET_PARENT/$PACK_NAME"

if [ ! -d "${MINECRAFT_DIR:-$HOME/.minecraft}" ]; then
  echo "No Minecraft directory at ${MINECRAFT_DIR:-$HOME/.minecraft}" >&2
  echo "Set MINECRAFT_DIR to override." >&2
  exit 1
fi

mkdir -p "$TARGET_PARENT"

if [ -e "$DEST_DIR" ] || [ -L "$DEST_DIR" ]; then
  rm -rf "$DEST_DIR"
fi
mkdir -p "$DEST_DIR"

# Copy only the pack itself -- not .git, not this script.
cp -a "$SRC_DIR/pack.mcmeta" "$DEST_DIR/"
cp -a "$SRC_DIR/assets" "$DEST_DIR/"

echo "Installed shader pack to: $DEST_DIR"

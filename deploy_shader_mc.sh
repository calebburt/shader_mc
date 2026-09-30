#!/usr/bin/env bash
# Installs the pack into a Minecraft installation's resourcepacks directory.
set -euo pipefail

PACK_NAME="vibrant-java"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# An explicit MINECRAFT_DIR wins, then a native install, then the Windows one when
# running under WSL.
resolve_mc_dir() {
  if [ -n "${MINECRAFT_DIR:-}" ]; then
    printf '%s\n' "$MINECRAFT_DIR"
    return
  fi
  if [ -d "$HOME/.minecraft" ]; then
    printf '%s\n' "$HOME/.minecraft"
    return
  fi
  for candidate in /mnt/*/Users/*/AppData/Roaming/.minecraft; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf '%s\n' "$HOME/.minecraft"
}

MC_DIR="$(resolve_mc_dir)"
if [ ! -d "$MC_DIR" ]; then
  echo "No Minecraft directory at $MC_DIR" >&2
  echo "Set MINECRAFT_DIR to point at it and try again." >&2
  exit 1
fi

DEST_DIR="$MC_DIR/resourcepacks/$PACK_NAME"
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

# Only the pack itself. The validation script stays behind.
cp -a "$SRC_DIR/pack.mcmeta" "$DEST_DIR/"
cp -a "$SRC_DIR/assets" "$DEST_DIR/"

echo "Installed $PACK_NAME to $DEST_DIR"
echo "Enable it in Options > Video Settings > Shader Packs."

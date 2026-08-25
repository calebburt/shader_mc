#!/usr/bin/env bash
set -euo pipefail

# Resolve the Minecraft directory: an explicit MINECRAFT_DIR wins, then a native
# install, then the Windows one when running under WSL -- there $HOME/.minecraft
# does not exist but the game's does, and hardcoding $HOME silently targets a
# directory the game never reads.
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
  printf '%s\n' "$HOME/.minecraft"  # nothing found; callers report this path
}

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_NAME="shader_mc"
MC_DIR="$(resolve_mc_dir)"
TARGET_PARENT="$MC_DIR/resourcepacks"
DEST_DIR="$TARGET_PARENT/$PACK_NAME"

if [ ! -d "$MC_DIR" ]; then
  echo "No Minecraft directory at $MC_DIR" >&2
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

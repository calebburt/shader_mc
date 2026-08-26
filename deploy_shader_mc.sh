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

# With a world name, also install the companion data pack, which applies the post
# effect to each player so it does not have to be turned on by hand. The game has
# no always-on hook for a post chain, but /posteffect state is saved in the
# player's data, so the advancement behind this fires once and then never again.
#
#   ./deploy_shader_mc.sh "Shader Test"
WORLD="${1:-}"
if [ -n "$WORLD" ]; then
  WORLD_DIR="$MC_DIR/saves/$WORLD"
  if [ ! -d "$WORLD_DIR" ]; then
    echo "No world at $WORLD_DIR" >&2
    exit 1
  fi
  DATA_DEST="$WORLD_DIR/datapacks/$PACK_NAME"
  rm -rf "$DATA_DEST"
  mkdir -p "$DATA_DEST"
  cp -a "$SRC_DIR/datapack/." "$DATA_DEST/"
  echo "Installed data pack to: $DATA_DEST"
fi

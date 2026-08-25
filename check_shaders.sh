#!/usr/bin/env bash
# Compile this pack's core and post-pass shaders with the same compiler Minecraft
# uses -- shaderc, targeting SPIR-V -- and report GLSL errors. Minecraft only shows
# the first error per shader; this shows all of them for every #define permutation,
# and also checks each post_effect pass's sampler names and stage interface.
#
# The shaderc native comes from the game's own libraries/ directory. If none can be
# found, the check falls back to a desktop GL context, which is LOOSER than the game.
#
#   ./check_shaders.sh              # auto-detect game version from pack.mcmeta
#   MC_VERSION=26.2 ./check_shaders.sh
#
# Exits non-zero if any shader fails where the vanilla original succeeds.
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
MC_DIR="$(resolve_mc_dir)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/shader_mc-glslcheck"
VENV="$CACHE/venv"

# PyOpenGL only drives the fallback GL context. Kept out of the repo, built once.
if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating check venv in $CACHE ..."
  mkdir -p "$CACHE"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q PyOpenGL
fi

# Call the shared check_shaders_embedded.py script with appropriate arguments
exec "$VENV/bin/python" "$SRC_DIR/check_shaders_embedded.py" "$SRC_DIR" "$MC_DIR" "${MC_VERSION:-}"

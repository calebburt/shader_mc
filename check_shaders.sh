#!/usr/bin/env bash
# Compile this pack's core and post-pass shaders against a real OpenGL 3.3 context
# and report GLSL errors. Minecraft only shows the first error per shader; this
# shows all of them for every #define permutation.
#
#   ./check_shaders.sh              # auto-detect game version from pack.mcmeta
#   MC_VERSION=26.2 ./check_shaders.sh
#
# Exits non-zero if any shader fails where the vanilla original succeeds.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="${MINECRAFT_DIR:-$HOME/.minecraft}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/shader_mc-glslcheck"
VENV="$CACHE/venv"

# PyOpenGL drives a headless EGL context. Kept out of the repo, built once.
if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating check venv in $CACHE ..."
  mkdir -p "$CACHE"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q PyOpenGL
fi

# Call the shared check_shaders_embedded.py script with appropriate arguments
exec "$VENV/bin/python" "$SRC_DIR/check_shaders_embedded.py" "$SRC_DIR" "$MC_DIR" "${MC_VERSION:-}"

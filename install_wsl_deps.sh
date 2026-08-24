#!/usr/bin/env bash
set -euo pipefail

# Install system and Python deps needed for headless PyOpenGL/EGL shader checks
# Usage: run this from WSL in the repo root, or run via the Windows wrapper.

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required. Install it via your distro package manager." >&2
  exit 1
fi

echo "Updating package lists..."
sudo apt update

echo "Installing system packages..."
sudo apt install -y python3-venv python3-pip libegl1-mesa-dev libgl1-mesa-dev pkg-config

# Create venv in the same cache path the checker expects, and install PyOpenGL
VENV="${XDG_CACHE_HOME:-$HOME/.cache}/shader_mc-glslcheck/venv"
if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating venv at $VENV and installing PyOpenGL..."
  mkdir -p "$(dirname "$VENV")"
  python3 -m venv "$VENV"
  # Ensure pip exists inside the venv; some distros leave ensurepip/out-of-date
  if [ ! -x "$VENV/bin/pip" ]; then
    echo "Bootstrapping pip into venv..."
    "$VENV/bin/python" -m ensurepip --upgrade 2>/dev/null || true
    # If ensurepip didn't create pip, try installing system pip then upgrade inside venv
    if [ ! -x "$VENV/bin/pip" ]; then
      echo "ensurepip failed to create pip; installing system pip and retrying..."
      sudo apt install -y python3-pip
      "$VENV/bin/python" -m pip install --upgrade pip setuptools || true
    fi
  fi
  # Use the venv python -m pip to avoid relying on the pip executable path
  "$VENV/bin/python" -m pip install --disable-pip-version-check -q PyOpenGL
else
  echo "Venv already exists at $VENV; ensuring PyOpenGL is installed..."
  if [ ! -x "$VENV/bin/pip" ]; then
    echo "Venv exists but pip missing; attempting to bootstrap pip..."
    "$VENV/bin/python" -m ensurepip --upgrade 2>/dev/null || true
  fi
  "$VENV/bin/python" -m pip install --disable-pip-version-check -q --upgrade PyOpenGL
fi

echo "Done. You can now run ./check_shaders.sh (or run ../check_wsl.bat from Windows)."

#!/usr/bin/env bash

# Directory setup
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

# Detect OS
OS="$(uname -s)"

# Use custom libffi if available (significantly faster than system libffi on Linux)
if [[ -d "$HOME/.local/libffi-custom/lib" ]]; then
    export LD_LIBRARY_PATH="$HOME/.local/libffi-custom/lib:$LD_LIBRARY_PATH"
fi

# Paths
CALLSO_LIB=""
RAYLIB_BINDINGS=""

if [[ "$OS" == "Darwin" ]]; then
    # macOS
    if [[ -f "../raylib-osx/raylib.libash" ]]; then
        RAYLIB_BINDINGS="../raylib-osx/raylib.libash"
    fi
    # Check for callso in lib or raylib-osx
    if [[ -f "../../lib/callso.so" ]]; then
        CALLSO_LIB="../../lib/callso.so"
    elif [[ -f "../raylib-osx/callso.so" ]]; then
        CALLSO_LIB="../raylib-osx/callso.so"
    fi
elif [[ "$OS" == "Linux" ]]; then
    # Linux
    if [[ -f "../raylib-linux/raylib.libash" ]]; then
        RAYLIB_BINDINGS="../raylib-linux/raylib.libash"
    fi
    # Check for callso in lib or raylib-linux
    if [[ -f "../../lib/callso.so" ]]; then
        CALLSO_LIB="../../lib/callso.so"
    elif [[ -f "../raylib-linux/callso.so" ]]; then
        CALLSO_LIB="../raylib-linux/callso.so"
    fi
fi

# Fallback checks
if [[ -z "$CALLSO_LIB" ]]; then
    if [[ -f "./callso.so" ]]; then CALLSO_LIB="./callso.so"; fi
fi
if [[ -z "$RAYLIB_BINDINGS" ]]; then
    if [[ -f "./raylib.libash" ]]; then RAYLIB_BINDINGS="./raylib.libash"; fi
fi

# Validate
if [[ -z "$CALLSO_LIB" ]]; then
    echo "Error: Could not find callso.so"
    exit 1
fi
if [[ -z "$RAYLIB_BINDINGS" ]]; then
    echo "Error: Could not find raylib.libash"
    exit 1
fi

:

# Load callso
if [[ "$(type -t callso)" != "builtin" ]]; then
    enable -f "$CALLSO_LIB" callso || { echo "Error: Failed to load callso"; exit 1; }
fi

# Source bindings
source "$RAYLIB_BINDINGS" || { echo "Error: Failed to source bindings"; exit 1; }

# No C wrapper needed: callso now supports nested struct-by-value

# Generate Assets if missing
if [[ ! -f "assets/paddle.wav" ]]; then
    :
    ./generate_assets.bash
fi

# Run Game
# We source the game script so it runs in the same process context
# (inheriting the loaded builtin and sourced bindings)
source ./Bashout.bash

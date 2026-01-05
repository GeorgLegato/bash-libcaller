#!/usr/bin/env bash
set -e

# Directory setup
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

# User requested build folder: /example/raylib-osx
BUILD_DIR="$BASE_DIR/../raylib-osx-build"
mkdir -p "$BUILD_DIR"

RAYLIB_VER="5.5"
RAYLIB_TAR="raylib-${RAYLIB_VER}_macos.tar.gz"
RAYLIB_URL="https://github.com/raysan5/raylib/releases/download/${RAYLIB_VER}/${RAYLIB_TAR}"

# 1. Download
if [[ ! -f "$BUILD_DIR/$RAYLIB_TAR" ]]; then
    echo "Downloading $RAYLIB_TAR to $BUILD_DIR..."
    wget -q -O "$BUILD_DIR/$RAYLIB_TAR" "$RAYLIB_URL" || curl -L -o "$BUILD_DIR/$RAYLIB_TAR" "$RAYLIB_URL"
fi

# 2. Unpack
# The macos tarball usually contains a folder like raylib-5.5_macos
SRC_DIR="$BUILD_DIR/raylib-${RAYLIB_VER}_macos"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "Unpacking..."
    tar -xzf "$BUILD_DIR/$RAYLIB_TAR" -C "$BUILD_DIR"
fi

# 3. Identify files
# The macOS release structure is usually:
# include/raylib.h
# lib/libraylib.dylib (or .a)
INCLUDE_DIR="$SRC_DIR/include"
LIB_DIR="$SRC_DIR/lib"
HEADER="$INCLUDE_DIR/raylib.h"
LIB="$LIB_DIR/libraylib.dylib"

# Check if dylib exists, if not, try to find it
if [[ ! -f "$LIB" ]]; then
    LIB=$(find "$LIB_DIR" -name "libraylib.dylib" | head -n 1)
fi

# If still not found, maybe it's .so or .a?
if [[ ! -f "$LIB" ]]; then
    LIB=$(find "$LIB_DIR" -name "libraylib.so" | head -n 1)
fi

if [[ ! -f "$LIB" ]]; then
    echo "Error: libraylib.dylib or libraylib.so not found in $LIB_DIR."
    echo "Contents of $LIB_DIR:"
    ls -R "$LIB_DIR"
    exit 1
fi

echo "Found Header: $HEADER"
echo "Found Library: $LIB"

cd "$BASE_DIR"

# 3.5 Build Generic Callso Builtin
echo "Building generic callso builtin..."
CALLSO_SRC="../../src/callso.c"
CALLSO_SO="./callso.so"

# Try to find libffi via pkg-config or brew
FFI_CFLAGS=""
FFI_LDFLAGS=""

if command -v pkg-config >/dev/null; then
    FFI_CFLAGS=$(pkg-config --cflags libffi 2>/dev/null || true)
    FFI_LDFLAGS=$(pkg-config --libs libffi 2>/dev/null || true)
fi

if [[ -z "$FFI_CFLAGS" && -x "$(command -v brew)" ]]; then
    BREW_PREFIX=$(brew --prefix libffi)
    if [[ -d "$BREW_PREFIX" ]]; then
        FFI_CFLAGS="-I$BREW_PREFIX/include"
        FFI_LDFLAGS="-L$BREW_PREFIX/lib"
    fi
fi

# Fallback paths for standard Homebrew locations if brew command is missing but files exist
if [[ -z "$FFI_CFLAGS" ]]; then
    if [[ -d "/opt/homebrew/opt/libffi/include" ]]; then
        FFI_CFLAGS="-I/opt/homebrew/opt/libffi/include"
        FFI_LDFLAGS="-L/opt/homebrew/opt/libffi/lib"
    elif [[ -d "/usr/local/opt/libffi/include" ]]; then
        FFI_CFLAGS="-I/usr/local/opt/libffi/include"
        FFI_LDFLAGS="-L/usr/local/opt/libffi/lib"
    fi
fi

echo "Using libffi flags: $FFI_CFLAGS $FFI_LDFLAGS"

# Try to find Bash headers
BASH_CFLAGS=""
# Common Homebrew locations
POSSIBLE_BASH_DIRS=(
    "/opt/homebrew/include/bash"
    "/usr/local/include/bash"
    "/opt/homebrew/opt/bash/include/bash"
    "/usr/local/opt/bash/include/bash"
    "/usr/include/bash"
)

for d in "${POSSIBLE_BASH_DIRS[@]}"; do
    if [[ -f "$d/config.h" ]]; then
        echo "Found Bash headers in $d"
        BASH_CFLAGS="-I$d -I$d/include -I$d/builtins"
        break
    fi
done

if [[ -z "$BASH_CFLAGS" ]]; then
    echo "Warning: Bash headers not found in common locations."
    echo "Attempting to download Bash 5.2 source to build against..."
    
    BASH_VER="5.2"
    BASH_TAR="bash-${BASH_VER}.tar.gz"
    BASH_URL="https://ftp.gnu.org/gnu/bash/${BASH_TAR}"
    BASH_SRC_DIR="$BASE_DIR/../bash-${BASH_VER}"
    
    if [[ ! -d "$BASH_SRC_DIR" ]]; then
        if [[ ! -f "$BASE_DIR/../$BASH_TAR" ]]; then
            wget -q -O "$BASE_DIR/../$BASH_TAR" "$BASH_URL" || curl -L -o "$BASE_DIR/../$BASH_TAR" "$BASH_URL"
        fi
        tar -xzf "$BASE_DIR/../$BASH_TAR" -C "$BASE_DIR/../"
        
        # We need to configure bash to generate config.h
        echo "Configuring Bash source..."
        pushd "$BASH_SRC_DIR" >/dev/null
        ./configure >/dev/null
        popd >/dev/null
    fi

    # Ensure headers are generated even if directory existed
    if [[ ! -f "$BASH_SRC_DIR/pathnames.h" ]]; then
        echo "Generating Bash headers..."
        pushd "$BASH_SRC_DIR" >/dev/null
        make pathnames.h >/dev/null
        make builtins.h >/dev/null || true 
        make y.tab.h >/dev/null || true
        popd >/dev/null
    fi
    
    BASH_CFLAGS="-I$BASH_SRC_DIR -I$BASH_SRC_DIR/include -I$BASH_SRC_DIR/builtins"
fi

echo "Using Bash flags: $BASH_CFLAGS"

# We will use a best-effort compilation command for macOS
# -bundle is for loadable modules (like bash builtins)
# -undefined dynamic_lookup allows symbols to be resolved by the host (bash)
gcc -dynamiclib -undefined dynamic_lookup -o "$CALLSO_SO" "$CALLSO_SRC" \
    $FFI_CFLAGS $FFI_LDFLAGS -lffi \
    $BASH_CFLAGS || \
gcc -shared -fPIC -o "$CALLSO_SO" "$CALLSO_SRC" $FFI_CFLAGS $FFI_LDFLAGS -lffi $BASH_CFLAGS

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to build callso.so" >&2
    exit 1
fi

# 4. Transpile Header
echo "Generating raylib.bash.h..."
# We need to pass the absolute path to the library so the generated script finds it
# realpath might not be available on all macOS, use python or perl or just $LIB if absolute
if [[ "$LIB" != /* ]]; then
    LIB="$PWD/$LIB"
fi

../../tools/h2bash.sh "$HEADER" "$LIB" raylib > raylib.libash

# 5. Create Demo Script
cat <<EOF > run_raylib.sh
#!/usr/bin/env bash

# Ensure we are running in Bash 4+ (required for associative arrays)
if [[ "\${BASH_VERSINFO:-0}" -lt 4 ]]; then
    echo "Error: This script requires Bash 4.0 or newer (you are using \$BASH_VERSION)."
    echo "On macOS, please install a newer Bash via Homebrew:"
    echo "  brew install bash"
    echo "Then run this script with the new bash:"
    echo "  /opt/homebrew/bin/bash \$0"
    echo "  or"
    echo "  /usr/local/bin/bash \$0"
    
    # Try to auto-exec if found
    if [[ -x /opt/homebrew/bin/bash ]]; then
        echo "Found /opt/homebrew/bin/bash, switching..."
        exec /opt/homebrew/bin/bash "\$0" "\$@"
    elif [[ -x /usr/local/bin/bash ]]; then
        echo "Found /usr/local/bin/bash, switching..."
        exec /usr/local/bin/bash "\$0" "\$@"
    fi
    exit 1
fi

# Load the generic builtin
if [[ "\$(type -t callso)" == "builtin" ]]; then
    echo "Using existing 'callso' builtin."
else
    if [[ -f "$BASE_DIR/callso.so" ]]; then
        enable -f "$BASE_DIR/callso.so" callso
    else
        echo "Error: callso builtin not found and callso.so missing."
        exit 1
    fi
fi

# Source the generated bindings
source ./raylib.libash

# Helper to pack Color (r, g, b, a) -> u32
# Raylib Color is {r,g,b,a}
# On little endian: 0xAABBGGRR
get_color() {
    local r=\$1
    local g=\$2
    local b=\$3
    local a=\$4
    echo \$(( r | (g << 8) | (b << 16) | (a << 24) ))
}

LIGHTGRAY=\$(get_color 200 200 200 255)
RAYWHITE=\$(get_color 245 245 245 255)
RED=\$(get_color 230 41 55 255)

echo "Initializing Window..."
raylib InitWindow 800 450 "Bash LibCaller - Raylib Speedrun (macOS)"

raylib SetTargetFPS 60

echo "Starting Main Loop..."

while true; do
    # WindowShouldClose returns bool (0 or 1)
    # The builtin prints the return value to stdout
    should_close=\$(raylib WindowShouldClose)
    if [[ "\$should_close" == "1" ]]; then
        break
    fi

    raylib BeginDrawing
    raylib ClearBackground \$RAYWHITE
    raylib DrawText "Congrats! You created your first window!" 190 200 20 \$LIGHTGRAY
    raylib DrawFPS 10 10
    raylib EndDrawing
done

raylib CloseWindow
echo "Done."
EOF

chmod +x run_raylib.sh

echo "Setup complete. Run ./run_raylib.sh to start the demo."

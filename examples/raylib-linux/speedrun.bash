#!/usr/bin/env bash
set -e

# Directory setup
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

# User requested build folder: /example/raylib
# We will interpret this as ../raylib relative to this script
BUILD_DIR="$BASE_DIR/../raylib"
mkdir -p "$BUILD_DIR"

RAYLIB_VER="5.5"
RAYLIB_TAR="raylib-${RAYLIB_VER}.tar.gz"
RAYLIB_URL="https://github.com/raysan5/raylib/archive/refs/tags/${RAYLIB_VER}.tar.gz"

# 1. Download
if [[ ! -f "$BUILD_DIR/$RAYLIB_TAR" ]]; then
    echo "Downloading $RAYLIB_TAR to $BUILD_DIR..."
    wget -q -O "$BUILD_DIR/$RAYLIB_TAR" "$RAYLIB_URL"
fi

# 2. Unpack
# We expect a directory named raylib-5.5
SRC_DIR="$BUILD_DIR/raylib-${RAYLIB_VER}"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "Unpacking..."
    tar -xzf "$BUILD_DIR/$RAYLIB_TAR" -C "$BUILD_DIR"
fi

# 3. Build
echo "Building Raylib from source..."
# We use make because cmake might be missing
# We need to build a shared library
cd "$SRC_DIR/src"
make clean || true
make RAYLIB_LIBTYPE=SHARED PLATFORM=PLATFORM_DESKTOP

# 4. Identify files
INCLUDE_DIR="$SRC_DIR/src"
LIB_DIR="$SRC_DIR/src"
HEADER="$INCLUDE_DIR/raylib.h"
LIB="$LIB_DIR/libraylib.so"
# On some systems it might be libraylib.so.5.5.0 or similar, let's find it
if [[ ! -f "$LIB" ]]; then
    LIB=$(find "$LIB_DIR" -name "libraylib.so*" | head -n 1)
fi

if [[ ! -f "$LIB" ]]; then
    echo "Error: Build failed or libraylib.so not found."
    exit 1
fi

echo "Found Header: $HEADER"
echo "Found Library: $LIB"

cd "$BASE_DIR"

# 3.5 Build Generic Callso Builtin
echo "Building generic callso builtin..."
CALLSO_SRC="../../src/callso.c"
CALLSO_SO="./callso.so"
gcc -shared -fPIC -o "$CALLSO_SO" "$CALLSO_SRC" -I/usr/include/bash -I/usr/include/bash/include -I/usr/include/bash/builtins -lffi

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to build callso.so" >&2
    exit 1
fi

# 4. Transpile Header
echo "Generating raylib.libash..."
../../tools/h2bash.sh "$HEADER" "$LIB" raylib > raylib.libash

# 5. Create Demo Script
cat <<EOF > run_raylib.sh
#!/usr/bin/env bash

# Load the generic builtin
enable -f "$BASE_DIR/callso.so" callso

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
raylib InitWindow 800 450 "Bash LibCaller - Raylib Speedrun"

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


chmod +x run_raylib.sh

echo "Setup complete. Run ./run_raylib.sh to start the demo."

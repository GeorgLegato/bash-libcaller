#!/usr/bin/env bash
cd "$(dirname "$0")"

# Try to load the builtin
if ! builtin callso >/dev/null 2>&1; then
    # Check common locations
    CALLSO_LIB=""
    
    if [[ -f "../../lib/callso.so" ]]; then
        CALLSO_LIB="../../lib/callso.so"
    elif [[ -f "../bin/callso.so" ]]; then
        CALLSO_LIB="../bin/callso.so"
    elif [[ -f "./callso.so" ]]; then
        CALLSO_LIB="./callso.so"
    fi

    if [[ -n "$CALLSO_LIB" ]]; then
        echo "Loading callso from $CALLSO_LIB"
        enable -f "$CALLSO_LIB" callso
    else
        echo "Error: callso.so not found. Please build it first."
        exit 1
    fi
fi

source ./libc.bash.h

echo "--- Calling puts ---"
libc puts "Hello from Bash LibCaller!"

echo "--- Calling printf ---"
libc printf "The answer is: %d\n" 42

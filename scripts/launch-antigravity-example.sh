#!/bin/bash
# Example script to launch Antigravity using the generic X11 proot wrapper

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SCRIPT="$SCRIPT_DIR/x11-proot-app-run.sh"

if [ ! -f "$WRAPPER_SCRIPT" ]; then
    echo "Error: Wrapper script not found at $WRAPPER_SCRIPT"
    exit 1
fi

echo "Launching Antigravity via generic wrapper..."
"$WRAPPER_SCRIPT" run antigravity

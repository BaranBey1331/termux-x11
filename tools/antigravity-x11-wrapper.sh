#!/bin/bash
# Wrapper script to safely launch Termux:X11, a window manager, and an Electron/Node app (like Antigravity) inside proot-distro.

# Ensure we're running in Termux
if [ -z "$PREFIX" ]; then
    echo "This script must be run inside Termux."
    exit 1
fi

export DISPLAY=:1
X11_SOCKET_DIR="$TMPDIR/.X11-unix"
X11_SOCKET="$X11_SOCKET_DIR/X1"

# 1. Clean up stale X server instance and Android app state
echo "[*] Cleaning up stale Termux:X11 instances..."
# Try to stop Termux:X11 Android app using the standard am intent
am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
# am force-stop might not work in Termux, but let's try it anyway just in case
am force-stop com.termux.x11 >/dev/null 2>&1 || true
# Kill any remaining termux-x11 background processes in the host
pkill -f "termux-x11.*:1" >/dev/null 2>&1 || true
# Remove stale X11 sockets
rm -rf "$X11_SOCKET_DIR"
mkdir -p "$X11_SOCKET_DIR"

# 2. Launch Termux:X11 background process
echo "[*] Starting Termux:X11 display server..."
termux-x11 :1 -xstartup "true" >/dev/null 2>&1 &
X11_PID=$!

# Wait for the host X11 socket to be created
MAX_WAIT=50 # 5 seconds
WAIT_COUNT=0
echo "[*] Waiting for X11 socket at $X11_SOCKET..."
while [ ! -S "$X11_SOCKET" ]; do
    sleep 0.1
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "[!] Error: Termux:X11 socket failed to create at $X11_SOCKET."
        echo "[!] Check if termux-x11 is installed correctly."
        kill $X11_PID >/dev/null 2>&1 || true
        exit 1
    fi
done
echo "[+] X11 socket created successfully."

# 3. Setup proot-distro launch command
# Assuming Ubuntu is installed via proot-distro
DISTRO="ubuntu"
if ! proot-distro list | grep -q "\* $DISTRO" && ! proot-distro list | grep -A 2 "$DISTRO" | grep -q "installed"; then
    echo "[!] Ubuntu proot-distro not found. Please run: proot-distro install ubuntu"
    kill $X11_PID >/dev/null 2>&1 || true
    exit 1
fi

# The path to libnetstub.so inside the proot
# We will compile it on the fly if it doesn't exist
LIBNETSTUB_PROOT_PATH="/tmp/libnetstub.so"

# 4. Generate a launch script to run inside proot
# Note: we use /root/.run-antigravity.sh, adjust user as necessary.
PROOT_RUN_SCRIPT="$PREFIX/../usr/tmp/proot_launch_antigravity.sh"

cat << 'PROOT_EOF' > "$PROOT_RUN_SCRIPT"
#!/bin/bash
export DISPLAY=:1

# Check if X11 socket is visible inside proot
if [ ! -S "/tmp/.X11-unix/X1" ]; then
    echo "[!] Error: X11 socket not visible inside proot at /tmp/.X11-unix/X1"
    exit 1
fi

# Set a safe XDG_RUNTIME_DIR to avoid dbus world-writable /tmp warnings
export XDG_RUNTIME_DIR="$HOME/.run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Start D-Bus if not running
if ! pgrep -x "dbus-daemon" > /dev/null; then
    echo "[*] Starting dbus-daemon..."
    dbus-daemon --session --fork --address="unix:path=$XDG_RUNTIME_DIR/bus"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

# 5. Start a window manager to provide EWMH properties so apps actually map and surface
echo "[*] Starting Window Manager (xfwm4)..."
# We run xfwm4 --replace to take over any existing WM and background it
if command -v xfwm4 >/dev/null 2>&1; then
    xfwm4 --replace >/dev/null 2>&1 &
else
    echo "[!] Warning: xfwm4 not found. Install it for proper window management."
fi

# 6. Apply libnetstub.so to fix uv_interface_addresses ... error 13
export LD_PRELOAD="/tmp/libnetstub.so"

echo "[*] Launching Antigravity..."
# Assuming antigravity is in PATH or specify its path here
# Example: /opt/antigravity/antigravity
# We just call 'antigravity' or equivalent.
# If Antigravity is just an example name, the user can replace this line.
if command -v antigravity >/dev/null 2>&1; then
    antigravity >/dev/null 2>&1 &
else
    echo "[!] antigravity command not found. Starting xclock as a fallback test..."
    if command -v xclock >/dev/null 2>&1; then
        xclock >/dev/null 2>&1 &
    else
        echo "[!] xclock not found either. Please install an X11 app."
    fi
fi

# Keep the script running so proot doesn't exit immediately
wait
PROOT_EOF

chmod +x "$PROOT_RUN_SCRIPT"

# Compile libnetstub.so for the proot architecture
echo "[*] Setting up libnetstub.so to fix Electron/Node.js network errors..."
cat << 'C_EOF' > "$PREFIX/../usr/tmp/libnetstub.c"
#include <errno.h>
#include <ifaddrs.h>
#include <stddef.h>

// Stub getifaddrs to return 0 (success) but no interfaces,
// or a fake loopback interface to bypass Android/proot netlink restrictions
// that cause uv_interface_addresses (libuv) to fail with error 13 (EACCES)

int getifaddrs(struct ifaddrs **ifap) {
    *ifap = NULL;
    return 0; // Success, empty list
}

void freeifaddrs(struct ifaddrs *ifa) {
    // Nothing to free
}
C_EOF

# We compile it using the host gcc/clang if available, or inside proot
if command -v clang >/dev/null 2>&1; then
    clang -shared -fPIC "$PREFIX/../usr/tmp/libnetstub.c" -o "$PREFIX/../usr/tmp/libnetstub.so"
else
    echo "[!] clang not found on host. Attempting to compile libnetstub.so inside proot..."
    proot-distro login "$DISTRO" --bind "$PREFIX/../usr/tmp:/tmp" -- bash -c "gcc -shared -fPIC /tmp/libnetstub.c -o /tmp/libnetstub.so || clang -shared -fPIC /tmp/libnetstub.c -o /tmp/libnetstub.so"
fi

# Launch proot-distro, binding the X11 socket explicitly
echo "[*] Launching proot-distro with explicit X11 socket bind..."
# Also bind the tmp directory where our script and libnetstub.so are
proot-distro login "$DISTRO" \
    --bind "$X11_SOCKET_DIR:/tmp/.X11-unix" \
    --bind "$PREFIX/../usr/tmp:/tmp" \
    -- bash /tmp/proot_launch_antigravity.sh

# Cleanup when proot exits
echo "[*] Proot session ended. Cleaning up..."
kill $X11_PID >/dev/null 2>&1 || true
am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
rm -f "$PROOT_RUN_SCRIPT"
rm -f "$PREFIX/../usr/tmp/libnetstub.c" "$PREFIX/../usr/tmp/libnetstub.so"

echo "[+] Done."

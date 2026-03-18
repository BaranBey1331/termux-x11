#!/bin/bash
# Generic helper wrapper for launching arbitrary X11 apps inside proot-distro

set -e

DISPLAY_NUM=1
export DISPLAY=:$DISPLAY_NUM
TMPDIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
X11_SOCKET_DIR="$TMPDIR/.X11-unix"
X11_SOCKET="$X11_SOCKET_DIR/X$DISPLAY_NUM"

usage() {
    echo "Usage: $0 <command> [args...]"
    echo "Commands:"
    echo "  status                Verify host X11 health"
    echo "  up                    Start/recover Termux:X11"
    echo "  run <app_command>     Bind X11 socket into proot and run an arbitrary app command"
    echo "  focus <window-name>   Try to focus/map an existing window"
    echo "  down                  Stop helper-launched processes cleanly"
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    status)

        echo "[*] Checking host X11 health..."
        if pgrep -f "termux-x11.*:$DISPLAY_NUM" >/dev/null; then
            echo "[+] termux-x11 process is running."
        else
            echo "[-] termux-x11 process is not running."
        fi

        if [ -S "$X11_SOCKET" ]; then
            echo "[+] X11 socket exists at $X11_SOCKET."
        else
            echo "[-] X11 socket missing at $X11_SOCKET."
        fi

        if command -v xdpyinfo >/dev/null 2>&1; then
            if xdpyinfo -display :$DISPLAY_NUM >/dev/null 2>&1; then
                echo "[+] xdpyinfo can connect to display :$DISPLAY_NUM."
            else
                echo "[-] xdpyinfo cannot connect to display :$DISPLAY_NUM."
            fi
        else
            echo "[?] xdpyinfo not installed, skipping display connection check."
        fi

        ;;
    up)

        echo "[*] Starting/recovering Termux:X11..."
        # Clean up old states
        am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
        am force-stop com.termux.x11 >/dev/null 2>&1 || true
        pkill -f "termux-x11.*:$DISPLAY_NUM" >/dev/null 2>&1 || true

        # Remove stale X11 sockets
        rm -rf "$X11_SOCKET_DIR"
        mkdir -p "$X11_SOCKET_DIR"

        echo "[*] Launching Termux:X11 display server..."
        termux-x11 :$DISPLAY_NUM -xstartup "true" >/dev/null 2>&1 &

        MAX_WAIT=50
        WAIT_COUNT=0
        echo "[*] Waiting for X11 socket to appear..."
        while [ ! -S "$X11_SOCKET" ]; do
            sleep 0.1
            WAIT_COUNT=$((WAIT_COUNT + 1))
            if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
                echo "[!] Error: Termux:X11 socket failed to create at $X11_SOCKET."
                exit 1
            fi
        done
        echo "[+] Termux:X11 is up and socket is ready."

        ;;
    run)

        APP_CMD="$@"
        if [ -z "$APP_CMD" ]; then
            echo "[!] Error: You must specify a command to run."
            usage
            exit 1
        fi

        # Ensure Termux:X11 is up
        if [ ! -S "$X11_SOCKET" ]; then
            echo "[*] X11 socket not found. Running 'up' command first..."
            "$0" up
        fi

        DISTRO="${PROOT_DISTRO:-ubuntu}" # Default or could be customizable via args/env

        # Check if proot-distro is installed and the distro is available
        if command -v proot-distro >/dev/null 2>&1; then
            if ! proot-distro list | grep -q "\* $DISTRO" && ! proot-distro list | grep -A 2 "$DISTRO" | grep -q "installed"; then
                echo "[!] Proot distro '$DISTRO' not found. Please install it with: proot-distro install $DISTRO"
                exit 1
            fi
        else
            echo "[!] proot-distro not found. Please install it."
            exit 1
        fi

        # Generate the libnetstub.so for Electron/Node.js compatibility inside proot
        LIBNETSTUB_C="$PREFIX/../usr/tmp/libnetstub.c"
        LIBNETSTUB_SO="$PREFIX/../usr/tmp/libnetstub.so"

        echo "[*] Setting up libnetstub.so..."
        cat << 'C_EOF' > "$LIBNETSTUB_C"
#include <errno.h>
#include <ifaddrs.h>
#include <stddef.h>

int getifaddrs(struct ifaddrs **ifap) {
    *ifap = NULL;
    return 0;
}

void freeifaddrs(struct ifaddrs *ifa) {
}
C_EOF

        if command -v clang >/dev/null 2>&1; then
            clang -shared -fPIC "$LIBNETSTUB_C" -o "$LIBNETSTUB_SO"
        else
            echo "[*] Compiling libnetstub.so inside proot..."
            proot-distro login "$DISTRO" --shared-tmp --bind "$PREFIX/../usr/tmp:/tmp" -- bash -c "gcc -shared -fPIC /tmp/libnetstub.c -o /tmp/libnetstub.so || clang -shared -fPIC /tmp/libnetstub.c -o /tmp/libnetstub.so"
        fi

        PROOT_RUN_SCRIPT="$PREFIX/../usr/tmp/proot_run_app.sh"

        cat << PROOT_EOF > "$PROOT_RUN_SCRIPT"
#!/bin/bash
export DISPLAY=:$DISPLAY_NUM

if [ ! -S "/tmp/.X11-unix/X$DISPLAY_NUM" ]; then
    echo "[!] Error: X11 socket not visible inside proot."
    exit 1
fi

export XDG_RUNTIME_DIR="\$HOME/.run"
mkdir -p "\$XDG_RUNTIME_DIR"
chmod 700 "\$XDG_RUNTIME_DIR"

if ! pgrep -x "dbus-daemon" > /dev/null; then
    dbus-daemon --session --fork --address="unix:path=\$XDG_RUNTIME_DIR/bus"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
else
    # Find existing dbus address if possible, though setting it statically here is better
    export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
fi

# Try to start a window manager to provide EWMH, so electron/node apps map correctly.
if command -v xfwm4 >/dev/null 2>&1; then
    if ! pgrep -x "xfwm4" > /dev/null; then
        xfwm4 --replace >/dev/null 2>&1 &
        disown
    fi
elif command -v openbox >/dev/null 2>&1; then
    if ! pgrep -x "openbox" > /dev/null; then
        openbox >/dev/null 2>&1 &
        disown
    fi
fi

export LD_PRELOAD="/tmp/libnetstub.so"
echo "[*] Running app command inside proot: $APP_CMD"
$APP_CMD
PROOT_EOF

        chmod +x "$PROOT_RUN_SCRIPT"

        echo "[*] Launching proot session..."
        proot-distro login "$DISTRO" --shared-tmp --bind "$X11_SOCKET_DIR:/tmp/.X11-unix"             --bind "$PREFIX/../usr/tmp:/tmp"             -- bash /tmp/proot_run_app.sh

        ;;
    focus)

        WINDOW_NAME="$1"
        if [ -z "$WINDOW_NAME" ]; then
            echo "[!] Error: You must specify a window name to focus."
            usage
            exit 1
        fi

        echo "[*] Searching for window '$WINDOW_NAME'..."
        # Just use wmctrl inside proot
        DISTRO="${PROOT_DISTRO:-ubuntu}"
        PROOT_FOCUS_SCRIPT="$PREFIX/../usr/tmp/proot_focus_app.sh"

        cat << PROOT_EOF > "$PROOT_FOCUS_SCRIPT"
#!/bin/bash
export DISPLAY=:$DISPLAY_NUM
if command -v wmctrl >/dev/null 2>&1; then
    wmctrl -a "$WINDOW_NAME" || echo "[-] Could not focus '$WINDOW_NAME' (wmctrl failed or window not found)"
else
    echo "[-] wmctrl is not installed inside proot. Cannot focus window."
fi
PROOT_EOF

        chmod +x "$PROOT_FOCUS_SCRIPT"
        proot-distro login "$DISTRO" --shared-tmp --bind "$X11_SOCKET_DIR:/tmp/.X11-unix"             --bind "$PREFIX/../usr/tmp:/tmp"             -- bash /tmp/proot_focus_app.sh

        ;;
    down)

        echo "[*] Stopping helper-launched processes..."
        am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
        am force-stop com.termux.x11 >/dev/null 2>&1 || true
        pkill -f "termux-x11.*:$DISPLAY_NUM" >/dev/null 2>&1 || true
        rm -rf "$X11_SOCKET_DIR"
        rm -f "$PREFIX/../usr/tmp/libnetstub.c" "$PREFIX/../usr/tmp/libnetstub.so" "$PREFIX/../usr/tmp/proot_run_app.sh" "$PREFIX/../usr/tmp/proot_focus_app.sh"
        echo "[+] Down complete."

        ;;
    *)
        usage
        exit 1
        ;;
esac

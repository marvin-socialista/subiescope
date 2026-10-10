#!/bin/bash
# For working on the Windows app's page on a Mac: runs a debug build of the Mac app as a host for
# the page, with no window on screen, and a headless Chrome to look at it with (see cdp.mjs).
#
#   scripts/dev/page-host.sh start [port] [app arguments...]   default port 8787. Without app arguments: the demo
#                                                              car, connected. Add -pretendWindows YES for the Windows texts.
#   scripts/dev/page-host.sh stop [port]
#   scripts/dev/page-host.sh browser [debug port] [width] [height]   default debug port 9340
#   scripts/dev/page-host.sh browser-stop [debug port]
#
# The run is kept apart from the real app: a home folder of its own (in $WORK, by default under the
# temporary folder) for downloaded definitions and the like, its own log folder and recordings folder,
# and its own saved settings (it runs as a copy of the program called SubieScopePageHost, and settings
# go by the program's name: `defaults delete SubieScopePageHost` clears them).
set -euo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="${WORK:-${TMPDIR:-/tmp}/subiescope-page-host}"
cmd="${1:-}"; shift || true
case "$cmd" in
start)
  port="${1:-8787}"; shift || true
  home="$WORK/$port/home"
  mkdir -p "$home/Library/Preferences" "$WORK/$port/logs" "$WORK/$port/recordings"
  if [ "$#" -eq 0 ]; then extra=(-setupWizardDone YES -selectedPort demo -autoConnect YES); else extra=("$@"); fi
  (cd "$REPO" && swift build 2>&1 | grep -E "error|Build complete" || true)
  cp "$REPO/.build/debug/SubieScope" "$REPO/.build/debug/SubieScopePageHost"
  CFFIXED_USER_HOME="$home" SUBIESCOPE_LOG_DIR="$WORK/$port/logs" nohup "$REPO/.build/debug/SubieScopePageHost" \
    -webDev "$port" -webRoot "$REPO/Sources/SubieScope/Windows/Web" -logsFolder "$WORK/$port/recordings" \
    -autoUpdateCheck NO "${extra[@]}" > "$WORK/$port/out.txt" 2>&1 &
  echo $! > "$WORK/$port/pid"
  sleep 2
  echo "The page is at http://127.0.0.1:$port/ (output in $WORK/$port/out.txt)"
  ;;
stop)
  port="${1:-8787}"
  # A plain kill: the host takes that as a normal quit.
  if [ -f "$WORK/$port/pid" ]; then kill "$(cat "$WORK/$port/pid")" 2>/dev/null || true; rm -f "$WORK/$port/pid"; fi
  ;;
browser)
  dport="${1:-9340}"; width="${2:-1280}"; height="${3:-820}"
  mkdir -p "$WORK"
  nohup "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
    --user-data-dir="$WORK/chrome-$dport" --window-size="$width,$height" --remote-debugging-port="$dport" \
    about:blank > "$WORK/chrome-$dport.txt" 2>&1 &
  echo $! > "$WORK/chrome-$dport.pid"
  sleep 2
  echo "Headless Chrome on debug port $dport: CDP_PORT=$dport node scripts/dev/cdp.mjs nav http://127.0.0.1:8787/"
  ;;
browser-stop)
  dport="${1:-9340}"
  if [ -f "$WORK/chrome-$dport.pid" ]; then kill "$(cat "$WORK/chrome-$dport.pid")" 2>/dev/null || true; rm -f "$WORK/chrome-$dport.pid"; fi
  ;;
*) echo "usage: page-host.sh start|stop|browser|browser-stop (see the top of this file)"; exit 2;;
esac

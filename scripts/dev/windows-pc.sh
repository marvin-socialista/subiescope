#!/bin/bash
# Builds, tests and runs the Windows app on a Windows PC from a Mac, over SSH.
#
# Where the PC is comes from keys/windows-pc.env (not in git), three lines:
#   WINDOWS_PC=user@host                      the SSH login (PowerShell as the shell on the other side)
#   WINDOWS_PC_KEY=/path/to/private/key
#   WINDOWS_PC_DIR='C:\src\subiescope'        where the source goes on the PC
# The PC needs Swift for Windows and the Visual Studio Build Tools (see the README).
#
#   scripts/dev/windows-pc.sh sync                 copy this working tree's sources to the PC (a tar over scp; git is not involved)
#   scripts/dev/windows-pc.sh build [swift build arguments]    build there and print only the errors
#   scripts/dev/windows-pc.sh test [filter]        run the tests there and print failures and the summary
#   scripts/dev/windows-pc.sh package [-KeepDefinitions]       scripts\build-windows.ps1
#   scripts/dev/windows-pc.sh start [app arguments...]   start the debug build on the PC's desktop, in the background, with the
#                                                        page loaded from the source tree and its debug port (9339) open.
#                                                        Without app arguments: the demo car, connected.
#   scripts/dev/windows-pc.sh stop                 close it, as a click on its X does
#   scripts/dev/windows-pc.sh tunnel               forward the debug port to this Mac (leave it running), then:
#                                                  CDP_PORT=9339 node scripts/dev/cdp.mjs shot out.png
#   scripts/dev/windows-pc.sh run '<PowerShell>'   anything else, in the source folder on the PC
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$REPO/keys/windows-pc.env" ] || { echo "keys/windows-pc.env is missing: see the top of this script."; exit 1; }
# shellcheck disable=SC1091
source "$REPO/keys/windows-pc.env"
DIR="${WINDOWS_PC_DIR:-C:\\src\\subiescope}"
SSH=(ssh -i "$WINDOWS_PC_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ServerAliveInterval=30)
helper="powershell -NoProfile -ExecutionPolicy Bypass -File $DIR\\scripts\\dev\\windows-pc.ps1"
remote() { "${SSH[@]}" "$WINDOWS_PC" "Set-Location '$DIR'; $*"; }
cmd="${1:-}"; shift || true
case "$cmd" in
sync)
  archive="$(mktemp -t subiescope-src).tgz"
  (cd "$REPO" && COPYFILE_DISABLE=1 tar --no-xattrs -czf "$archive" --exclude='.DS_Store' \
     Package.swift VERSION LICENSE Sources Tests Assets scripts definitions docs/release-notes)
  "${SSH[@]}" "$WINDOWS_PC" "New-Item -ItemType Directory -Force '$DIR' | Out-Null"
  scp -q -i "$WINDOWS_PC_KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$archive" "$WINDOWS_PC:${DIR//\\//}/src.tgz"
  rm -f "$archive"
  # Folders are replaced whole, so a file that was deleted or renamed here is gone there too. The build folder stays.
  remote "foreach (\$d in 'Sources','Tests','scripts','definitions') { if (Test-Path \$d) { Remove-Item -Recurse -Force \$d } }; tar.exe -xzf src.tgz; if (\$LASTEXITCODE -ne 0) { exit 1 }; Remove-Item src.tgz; 'synced'"
  ;;
build)   remote "$helper build $*" ;;
test)    remote "$helper test $*" ;;
package) remote "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\build-windows.ps1 $* 2>&1 | Select-Object -Last 4" ;;
start)   remote "$helper start $*" ;;
stop)    remote "$helper stop" ;;
tunnel)  exec "${SSH[@]}" -o ExitOnForwardFailure=yes -N -L 9339:127.0.0.1:9339 "$WINDOWS_PC" ;;
run)     remote "$*" ;;
*) echo "usage: windows-pc.sh sync|build|test|package|start|stop|tunnel|run (see the top of this file)"; exit 2;;
esac

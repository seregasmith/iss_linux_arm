#!/bin/bash
# odin_profile.sh: measures the packaged port on an ARM Linux handheld (Ayn Odin 3 with ArmadaOS,
# or any Linux handheld you can SSH into), run from a Mac (Apple Silicon or Intel) or a Linux PC.
# It copies tools/odin_profile_remote.sh to the handheld, runs it there over SSH and brings the
# results back to port/out/odin-profile/<date>-<label>/ (summary.txt first).
#
# Usage:  port/tools/odin_profile.sh [options] [user@]host
#   --label NAME      name of this run, e.g. 1080p or 720p (default: run)
#   --seconds N       length of the measurement (default: 60)
#   --attach          measure the game that is already running instead of starting it
#                     (start it on the handheld yourself, or keep the one an earlier run started).
#                     The measuring switches are the game's own then: for a game started from
#                     Steam put them in its launch options (Properties > Launch options), e.g.
#                       TLG_WAIT_STATS=1 TLG_GPU_PROFILE=1 TLG_FAULT_PROFILE=1 TLG_READBACK_STATS=1 TLG_PERF_DIAG=1 ISS_VERBOSE_LOG=0 %command%
#   --appimage PATH   the AppImage on the handheld (default: the first infamous-linux-*.AppImage
#                     in your home folder there, up to three levels deep)
#   --no-trace        frame times only (TLG_PERF_FRAMES=1) instead of TLG_PERF_TRACE=1
#   --verbose         keep the detailed log on if the launcher's settings have it (default: off for
#                     the run; it writes every GPU debug line unbuffered and costs frames)
#   --out DIR         where the results go (default: port/out/odin-profile)
#   -h, --help        this text
# The host can also come from ISS_ODIN_HOST (e.g. export ISS_ODIN_HOST=armada@192.168.1.50).
#
# Starting the game (the default) runs the AppImage with --play: the launcher's saved settings,
# no launcher window, plus TLG_WAIT_STATS=1, TLG_GPU_PROFILE=1, TLG_FAULT_PROFILE=1,
# TLG_READBACK_STATS=1, TLG_PERF_DIAG=1 and TLG_PERF_TRACE=1, with the detailed log off (to compare
# a setting, change it in the launcher between runs). The game window shows up in the
# session that is logged in on the handheld (desktop or Game Mode). The script waits until you
# press Enter, so load your save and walk to the spot first; then it measures for --seconds (any
# key stops early). The game keeps running afterwards.
#
# Comparing two settings in the same place, e.g. 1080p against 720p:
#   port/tools/odin_profile.sh --label 1080p armada@odin
#   (in-game menu: Image > Render resolution 720p)
#   port/tools/odin_profile.sh --attach --label 720p armada@odin
#
# One SSH connection serves the whole run (one password prompt). Nothing is installed on the
# handheld; the script and the results stay in ~/iss-profile there.
# Written for macOS's stock bash 3.2 and any newer bash.
set -eo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^set -eo/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
PORT_DIR=$(dirname "$HERE")
REMOTE_SCRIPT=$HERE/odin_profile_remote.sh
label=run seconds=60 mode=launch appimage="" trace=1 verbose=0 out="" host=${ISS_ODIN_HOST:-}
while [ $# -gt 0 ]; do
    case $1 in
        --label) [ $# -ge 2 ] || usage 2; label=$2; shift 2 ;;
        --seconds) [ $# -ge 2 ] || usage 2; seconds=$2; shift 2 ;;
        --attach) mode=attach; shift ;;
        --appimage) [ $# -ge 2 ] || usage 2; appimage=$2; shift 2 ;;
        --no-trace) trace=0; shift ;;
        --verbose) verbose=1; shift ;;
        --out) [ $# -ge 2 ] || usage 2; out=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        -*) echo "ERROR: unknown option $1" >&2; usage 2 ;;
        *) host=$1; shift ;;
    esac
done
[ -n "$host" ] || { echo "ERROR: give the handheld's address ([user@]host) or set ISS_ODIN_HOST" >&2; usage 2; }
case $seconds in ''|*[!0-9]*|0) die "--seconds must be a positive number" ;; esac
case $label in ''|*[!A-Za-z0-9._-]*) die "--label: letters, digits, '.', '_' and '-' only" ;; esac
[ -f "$REMOTE_SCRIPT" ] || die "missing $REMOTE_SCRIPT (it belongs next to this script)"
command -v ssh >/dev/null || die "ssh not found"
[ -t 0 ] || echo "NOTE: not started from a terminal: the run measures at once, without waiting for Enter" >&2

out=${out:-$PORT_DIR/out/odin-profile}
mkdir -p "$out"
out=$(cd -- "$out" && pwd)
name="$(date +%Y%m%d-%H%M%S)-$label"
console="$out/$name.console.txt"

# One connection for every step (the socket path stays short: macOS allows 104 characters).
ssh_opts=(-o ControlMaster=auto -o "ControlPath=/tmp/iss-ssh-%C" -o ControlPersist=600)
echo "==> Copying the measuring script to $host:~/iss-profile/"
ssh "${ssh_opts[@]}" "$host" 'mkdir -p ~/iss-profile && cat > ~/iss-profile/odin_profile_remote.sh' < "$REMOTE_SCRIPT" ||
    die "cannot reach $host over SSH"

args=$(printf '%q ' "$name" "$mode" "$seconds" "$trace" "$verbose" "$appimage")
tty_flag=()
if [ -t 0 ] && [ -t 1 ]; then tty_flag=(-t); fi
status=0
# "${arr[@]+"${arr[@]}"}" keeps bash 3.2 happy with an empty array.
# shellcheck disable=SC2029  # $args: expanded here on purpose (already quoted with %q)
ssh ${tty_flag[@]+"${tty_flag[@]}"} "${ssh_opts[@]}" "$host" "bash ~/iss-profile/odin_profile_remote.sh $args" |
    tee "$console" || status=$?
result=$(tr -d '\r' < "$console" | sed -n 's/^RESULT=//p' | tail -n 1)
[ -n "$result" ] || die "the handheld side did not finish (exit $status; its output: $console)"

echo "==> Copying the results back"
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$host" "cat $(printf '%q' "$result")" > "$out/$name.tar.gz" || die "cannot copy $result"
tar -xzf "$out/$name.tar.gz" -C "$out"
rm -f "$out/$name.tar.gz"
mv "$console" "$out/$name/console.txt" 2>/dev/null || true
echo "==> Done: $out/$name (summary.txt; samples.txt, game.log, perf-trace/ for the details)"

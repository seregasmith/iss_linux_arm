#!/bin/bash
# odin_profile_remote.sh: measures the packaged port on the handheld itself. Two ways to use it:
#
# 1. From Steam, without any network link (copy this file to the handheld, e.g. over USB/MTP):
#      Properties > Launch options:  bash /path/to/odin_profile_remote.sh session %command%
#    The game starts as usual, with the measuring switches on (TLG_WAIT_STATS, TLG_GPU_PROFILE,
#    TLG_FAULT_PROFILE, TLG_READBACK_STATS, TLG_PERF_DIAG, TLG_PERF_TRACE; the detailed log off).
#    The whole game session is recorded, every 2 s, until the game exits; then
#    iss-profile/<date>-session/ appears next to this file (ISS_PROFILE_DIR=<folder> elsewhere)
#    with summary.txt: one row per minute (FPS, GPU time and idle time, the game's waits for GPU
#    data, CPU of the main threads, clocks, free memory, temperature, render resolution), so 1080p
#    and 720p minutes of one session compare directly. Copy that folder back over USB/MTP.
#    Settings to compare go in front:  ISS_READBACKS=2 bash /path/... session %command%
#    ISS_PROFILE_TRACE=0: frame times only instead of TLG_PERF_TRACE; ISS_PROFILE_VERBOSE=1 keeps
#    the detailed log as the settings have it. Each game the launcher starts gets its own folder
#    (its helper runs, such as the controller check, are not measured).
#
# 2. Over SSH, by tools/odin_profile.sh on a Mac or PC (it copies this file to ~/iss-profile/):
#   bash ~/iss-profile/odin_profile_remote.sh NAME MODE SECONDS TRACE VERBOSE [APPIMAGE]
#   NAME      this run's folder: ~/iss-profile/NAME (and NAME.tar.gz, what the Mac copies back)
#   MODE      launch: start the AppImage (--play: the launcher's saved settings) with the measuring
#             switches; attach: measure the game that is already running
#   SECONDS   length of the measurement
#   TRACE     launch only. 1: TLG_PERF_TRACE=1 (stall captures, scripts/perf_trace_report.py);
#             0: TLG_PERF_FRAMES=1 (frame times only, less overhead). Always on when launching:
#             TLG_WAIT_STATS=1 (what each thread waits for), TLG_GPU_PROFILE=1 (GPU ms per frame
#             by pass) and TLG_FAULT_PROFILE=1 (the cost of the GPU memory write tracking)
#   VERBOSE   launch only. 0: the detailed log off for this run (it writes every GPU debug line
#             unbuffered, which costs frames); 1: as the settings say
#   APPIMAGE  launch only: the AppImage (default: the first infamous-linux-*.AppImage under ~)
# Every second it records the game's threads (CPU time, core, page faults), each core's load and
# clock, the GPU's load and clock where the kernel shows them, memory and temperatures, plus the
# game's own log for the same window (frame stats, TLG_WAIT_STATS). Reads /proc and /sys only and
# writes below ~/iss-profile only. Its last line is RESULT=<archive>.
set -u
export LC_ALL=C
# Steam preloads its overlay into everything it starts, this script's own tools too (ld.so
# complained into every result file): only the game's command gets it back.
host_preload=${LD_PRELOAD-} preload_set=${LD_PRELOAD+1}
unset LD_PRELOAD
child="" next_game=0 previous_game=""
if [ "${1:-}" = session ] || [ "${1:-}" = session-next ]; then
    if [ "$1" = session-next ]; then
        # The same launcher's next game (this script starts itself again for each one).
        child=${2:?CHILD} previous_game=${3:-} next_game=1
        shift 3
    else
        shift
        [ $# -gt 0 ] || { echo "usage: $0 session COMMAND... (Steam: session %command%)" >&2; exit 2; }
    fi
    mode=session seconds=0 appimage=""
    trace=${ISS_PROFILE_TRACE:-1} verbose=${ISS_PROFILE_VERBOSE:-0}
    name="$(date +%Y%m%d-%H%M%S)-session"
    base=${ISS_PROFILE_DIR:-$(cd -- "$(dirname -- "$0")" && pwd)/iss-profile}
else
    name=${1:?NAME} mode=${2:?MODE} seconds=${3:?SECONDS} trace=${4:-1} verbose=${5:-0} appimage=${6:-}
    case $mode in launch|attach) ;; *) echo "ERROR: MODE is launch or attach" >&2; exit 2 ;; esac
    case $seconds in ''|*[!0-9]*|0) echo "ERROR: SECONDS must be a positive number" >&2; exit 2 ;; esac
    base=$HOME/iss-profile
fi
dir=$base/$name
# Started by Steam there is no terminal: everything this script says goes to console.txt. The
# next game's folder is made once that game starts (until then this goes to the last one's).
if [ "$next_game" = 0 ]; then
    mkdir -p "$dir" || exit 1
    if [ "$mode" = session ]; then exec >> "$dir/console.txt" 2>&1; fi
fi
say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
interactive=0
if [ -t 0 ] && [ -t 1 ]; then interactive=1; fi
# A process that has exited (a zombie too: after the script restarts itself the launcher is no
# longer a child bash waits for).
alive() {
    local line=""
    { read -r line < "/proc/$1/stat"; } 2>/dev/null || return 1
    line=${line##*) }
    [ "${line%% *}" != Z ]
}

# The game: the newest tlg-probe process of this user (the AppImage's loader). Its name first (a
# read, no process started), the program file for those only. The launcher also runs tlg-probe for
# quick checks (--gamepad: the controllers); those start with an option, the game with its file.
game_pid() {
    local p pid comm arg best=0
    for p in /proc/[0-9]*; do
        comm=""; { read -r comm < "$p/comm"; } 2>/dev/null
        [ "$comm" = tlg-probe ] && [ -O "$p" ] || continue
        case $(readlink "$p/exe" 2>/dev/null) in */tlg-probe) ;; *) continue ;; esac
        arg=$(tr '\0' '\n' 2>/dev/null < "$p/cmdline" | sed -n 2p)
        case $arg in -*) continue ;; esac
        pid=${p#/proc/}
        if [ "$pid" -gt "$best" ]; then best=$pid; fi
    done
    if [ "$best" -gt 0 ]; then echo "$best"; fi
}
# The measuring switches, for the game this script starts (launch, session).
measuring_env() {
    export TLG_WAIT_STATS=1 TLG_GPU_PROFILE=1 TLG_FAULT_PROFILE=1 TLG_READBACK_STATS=1 TLG_PERF_DIAG=1
    if [ "$trace" = 1 ]; then export TLG_PERF_TRACE=1; else export TLG_PERF_FRAMES=1; fi
    if [ "$verbose" != 1 ]; then export ISS_VERBOSE_LOG=0 TLG_VERBOSE_LOG=0; fi
}
# The libraries the game has loaded: the Vulkan driver and any layers (Steam adds its own).
record_libraries() {
    local found
    found=$(grep -o '/[^ ]*\.so[^ /]*$' "/proc/$pid/maps" 2>/dev/null | sort -u)
    if [ -n "$found" ]; then printf '%s\n' "$found" > "$dir/libraries.txt"; fi   # not from an exiting game
}

# Over SSH there is no display: the game borrows the graphical session's variables from a process
# of it (Steam in Game Mode, the desktop's shell or compositor otherwise). Without them SDL falls
# back to the bare screen (KMSDRM) and the game stops with "VK_KHR_surface" missing.
env_from=""
borrow_display() {
    local p comm score best=0 from="" line
    for p in /proc/[0-9]*; do
        [ -O "$p" ] && [ -r "$p/environ" ] || continue
        tr '\0' '\n' 2>/dev/null < "$p/environ" | grep -q -E '^(WAYLAND_DISPLAY|DISPLAY)=.' || continue
        { read -r comm < "$p/comm"; } 2>/dev/null || continue
        case $comm in
            steam|steamwebhelper) score=4 ;;
            gamescope*) score=3 ;;
            kwin_wayland|kwin_x11|plasmashell|gnome-shell|sway|labwc|Hyprland|weston|cage) score=2 ;;
            *) score=1 ;;
        esac
        if [ "$score" -gt "$best" ]; then best=$score; from=$p; fi
    done
    [ -n "$from" ] || return 1
    read -r comm < "$from/comm"
    env_from="$comm (pid ${from#/proc/})"
    while IFS= read -r line; do
        case ${line%%=*} in
            WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|\
            XDG_CURRENT_DESKTOP|XDG_SESSION_DESKTOP|PULSE_SERVER|PIPEWIRE_REMOTE) export "${line?}" ;;
        esac
    done < <(tr '\0' '\n' < "$from/environ")
}

# ---- the game ------------------------------------------------------------------------------
pid=$(game_pid)
if [ "$mode" = launch ]; then
    if [ -n "$pid" ]; then
        die "the game is already running (pid $pid): close it first, or measure it with --attach"
    fi
    if [ -z "$appimage" ]; then
        appimage=$(find "$HOME" -maxdepth 3 -type f -name 'infamous-linux-*.AppImage' 2>/dev/null | sort | head -n 1)
    fi
    [ -n "$appimage" ] && [ -f "$appimage" ] || die "no infamous-linux-*.AppImage under $HOME (pass --appimage PATH)"
    [ -x "$appimage" ] || die "$appimage is not executable (chmod +x it)"
    borrow_display || die "no desktop or Game Mode session found to show the game in: log in on the handheld first (or start the game there yourself and use --attach)"
    say "Display: borrowed from $env_from (WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} DISPLAY=${DISPLAY:-})"
    case $env_from in steam*|gamescope*)
        say "Game Mode: a game started outside Steam can stay hidden behind it. If it does not show up," \
            "start it from Steam or the desktop and measure it with --attach." ;;
    esac
    measuring_env
    say "Starting $appimage --play (TLG_WAIT_STATS, TLG_GPU_PROFILE, TLG_FAULT_PROFILE, TLG_READBACK_STATS, TLG_PERF_DIAG, $( [ "$trace" = 1 ] && echo TLG_PERF_TRACE || echo TLG_PERF_FRAMES )$( [ "$verbose" = 1 ] || echo '; detailed log off' ))"
    # Its own session: the game keeps running when SSH disconnects. The launcher's output (the
    # Vulkan driver it chose) goes to launcher.txt.
    setsid nohup "$appimage" --play > "$dir/launcher.txt" 2>&1 < /dev/null &
    for _ in $(seq 1 240); do
        pid=$(game_pid)
        [ -n "$pid" ] && break
        sleep 1
    done
    [ -n "$pid" ] || die "the game did not start within 4 minutes (see $dir/launcher.txt)"
elif [ "$mode" = session ]; then
    # Steam's command (the AppImage, i.e. the launcher) as a child; the game it starts is measured.
    if [ "$next_game" = 1 ]; then
        old=$previous_game
    else
        old=$pid
        measuring_env
        say "Session: $* (measuring switches on$( [ "$verbose" = 1 ] || echo ', detailed log off'))"
        if [ -n "$preload_set" ]; then LD_PRELOAD=$host_preload "$@" & else "$@" & fi
        child=$!
    fi
    pid=""
    while alive "$child"; do
        pid=$(game_pid)
        [ -n "$pid" ] && [ "$pid" != "$old" ] && break
        pid=""
        sleep 2
    done
    if [ -z "$pid" ]; then
        if [ "$next_game" = 1 ]; then say "The launcher closed."; exit 0; fi
        say "The launcher closed without starting the game: nothing measured."
        wait "$child"; exit $?
    fi
    if [ "$next_game" = 1 ]; then
        mkdir -p "$dir" || exit 1
        say "The next game: $dir"
        exec >> "$dir/console.txt" 2>&1
    fi
else
    if [ -z "$pid" ]; then
        say "Waiting for the game to start (start it on the handheld)..."
        for _ in $(seq 1 300); do
            pid=$(game_pid)
            [ -n "$pid" ] && break
            sleep 1
        done
        [ -n "$pid" ] || die "no running game found (tlg-probe) within 5 minutes"
    fi
fi
say "Game: pid $pid"

# ---- what the machine is (once) ------------------------------------------------------------
{
    echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
    uname -a
    grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release 2>/dev/null
    echo "page size: $(getconf PAGESIZE 2>/dev/null)"
    echo "--- CPU clusters (cpufreq policies)"
    for c in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$c" ] || continue
        echo "${c##*/}: cpus $(cat "$c/related_cpus" 2>/dev/null), governor $(cat "$c/scaling_governor" 2>/dev/null)," \
             "min $(cat "$c/scaling_min_freq" 2>/dev/null) max $(cat "$c/scaling_max_freq" 2>/dev/null)" \
             "hardware max $(cat "$c/cpuinfo_max_freq" 2>/dev/null) kHz"
    done
    echo "--- GPU"
    for d in /sys/class/kgsl/kgsl-3d0 /sys/class/devfreq/*; do
        [ -d "$d" ] || continue
        case ${d##*/} in kgsl-3d0|*gpu*|*kgsl*|3d00000*) ;; *) continue ;; esac
        echo "$d:"
        for f in governor min_freq max_freq available_frequencies max_gpuclk gpu_model; do
            [ -r "$d/$f" ] && echo "  $f: $(cat "$d/$f" 2>/dev/null)"
        done
    done
    # shellcheck disable=SC2012
    ls -d /sys/class/drm/card* 2>/dev/null | sed 's/^/  drm: /'
    echo "--- memory"
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    echo "--- thermal zones"
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] && echo "  ${z##*/}: $(cat "$z/type") $(cat "$z/temp" 2>/dev/null)"
    done
} > "$dir/info.txt" 2>&1
tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" |
    grep -E '^(ISS_|TLG_|VK_|SDL_|WAYLAND_DISPLAY|DISPLAY|XDG_SESSION_TYPE|MESA_|TU_|FEX_)' | sort > "$dir/game-env.txt"
game_env() { sed -n "s/^$1=//p" "$dir/game-env.txt" | head -n 1; }
# ArmadaOS's game start writes FEX settings for each run (FEX_APP_CONFIG); the port's FEX reads
# them instead of ~/.config/fex-emu/Config.json. Kept while the file exists.
fex_config=$(game_env FEX_APP_CONFIG)
if [ -n "$fex_config" ]; then cp "$fex_config" "$dir/fex-app-config.json" 2>/dev/null; fi
# The game's log is its stdout and its user folder its working directory. Through /proc they can
# point into the AppImage's own view of the files (a game started from Steam showed neither), so
# the launcher's arguments and folders are the fallback: --user <folder>, ISS_OUT_DIR/logs.
game_log=$(readlink "/proc/$pid/fd/1" 2>/dev/null || true)
game_cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
{
    echo "fd/1: ${game_log:-(unreadable)}"
    echo "cwd: ${game_cwd:-(unreadable)}"
    echo "cmdline: $(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline")"
} > "$dir/game-paths.txt"
if [ -z "$game_log" ] || [ ! -f "$game_log" ]; then
    out_dir=$(game_env ISS_OUT_DIR)
    out_dir=${out_dir:-${ISS_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/infamous-pc}/out}
    # shellcheck disable=SC2012  # the newest log: the running game's
    game_log=$(ls -t "$out_dir"/logs/run-*.log 2>/dev/null | head -n 1)
    echo "log (newest in $out_dir/logs): ${game_log:-none}" >> "$dir/game-paths.txt"
fi
user_arg=$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | sed -n '/^--user$/{n;p;q;}')
if [ -n "$user_arg" ] && [ -d "$user_arg" ]; then game_cwd=$user_arg; fi
echo "user folder: ${game_cwd:-none}" >> "$dir/game-paths.txt"

if [ "$interactive" = 1 ]; then
    say "Load your save and go to the spot to measure. Keep it the same between runs (standing still"
    say "in one place is the easiest to compare)."
    printf 'Press Enter here to start the %s s measurement... ' "$seconds"
    read -r _
fi

# ---- the measurement -----------------------------------------------------------------------
hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
cpufreq=()
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do [ -r "$f" ] && cpufreq+=("$f"); done
clusters=()
for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq; do [ -r "$f" ] && clusters+=("$f"); done
gpu=()
for f in /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage /sys/class/kgsl/kgsl-3d0/gpubusy \
         /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq /sys/class/kgsl/kgsl-3d0/gpuclk \
         /sys/class/devfreq/*/cur_freq /sys/class/devfreq/*/load /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$f" ] || continue
    case $f in /sys/class/devfreq/*) case ${f%/*} in *gpu*|*kgsl*|*3d00000*) ;; *) continue ;; esac ;; esac
    gpu+=("$f")
done
zones=()
for z in /sys/class/thermal/thermal_zone*; do [ -r "$z/temp" ] && zones+=("$z"); done
printf '%s\n' "${gpu[@]:-}" > "$dir/gpu-sources.txt"

now_ms() {
    if [ -n "${EPOCHREALTIME:-}" ]; then local t=${EPOCHREALTIME/./}; echo "${t:0:13}"; else date +%s%3N; fi
}
# One sample: forks only for the clock (old bash) and the thread list; the rest is read builtins.
sample() {
    local f v line k rest
    printf '@ %s\n' "$(now_ms)"
    while read -r line; do
        case $line in cpu*) printf '%s\n' "$line" ;; *) break ;; esac
    done < /proc/stat
    for f in "${cpufreq[@]:+${cpufreq[@]}}"; do
        v=""; { read -r v < "$f"; } 2>/dev/null
        k=${f%/cpufreq/*}; printf 'F %s %s\n' "${k##*/}" "$v"
    done
    for f in "${gpu[@]:+${gpu[@]}}"; do
        v=""; { read -r v < "$f"; } 2>/dev/null
        printf 'G %s %s\n' "$f" "$v"
    done
    local avail="" rss=""
    while read -r k v rest; do [ "$k" = MemAvailable: ] && { avail=$v; break; }; done < /proc/meminfo
    { while read -r k v rest; do [ "$k" = VmRSS: ] && { rss=$v; break; }; done < "/proc/$pid/status"; } 2>/dev/null
    printf 'M %s %s\n' "$avail" "$rss"
    sed 's/^/T /' "/proc/$pid"/task/*/stat 2>/dev/null
    line=""; { read -r line < "/proc/$pid/stat"; } 2>/dev/null; [ -n "$line" ] && printf 'P %s\n' "$line"
    for f in "${clusters[@]:+${clusters[@]}}"; do
        v=""; { read -r v < "$f"; } 2>/dev/null
        k=${f%/scaling_cur_freq}; printf 'C %s %s\n' "${k##*/}" "$v"
    done
    # The game's reports written since the last sample (frame stats, GPU time and idle time, the
    # readbacks every 5 s, and each render resolution change), for the per-minute table.
    if [ -n "$game_log" ] && [ -f "$game_log" ]; then
        local size
        size=$(wc -c < "$game_log" 2>/dev/null) || size=$log_pos
        if [ "$size" -gt "$log_pos" ]; then
            tail -c "+$((log_pos + 1))" "$game_log" 2>/dev/null | head -c "$((size - log_pos))" |
                grep -a -E '^(Frame stats: |Frame pacing: |GPU profile: [0-9]|Scene resolution: |Output resolution: |Readback stats \(5 s\): |  deferred: |  waits for a readback copy: | +[0-9.]+ ms/frame +[0-9.]+/frame +\(between submissions)' | sed 's/^/X /'
            log_pos=$size
        fi
    fi
    if [ $((tick % 5)) -eq 0 ]; then
        for f in "${zones[@]:+${zones[@]}}"; do
            k=""; v=""; { read -r k < "$f/type"; read -r v < "$f/temp"; } 2>/dev/null
            printf 'H %s %s\n' "${k// /_}" "$v"
        done
    fi
}

log_start=0
if [ -n "$game_log" ] && [ -f "$game_log" ]; then log_start=$(wc -c < "$game_log"); fi
log_pos=$log_start
stop=0
if [ "$mode" = session ]; then
    # Steam's "Exit game" ends the whole process group: write the summary first.
    trap 'stop=1' INT TERM HUP
    say "Game: pid $pid; recording every 2 s until it exits"
else
    trap 'stop=1' INT
    say "Measuring for $seconds s$( [ "$interactive" = 1 ] && echo ' (any key stops early)')..."
fi
tick=0
started=$(date +%s)
while [ "$stop" = 0 ] && [ -d "/proc/$pid" ]; do
    sample >> "$dir/samples.txt"
    tick=$((tick + 1))
    case $tick in 5|30) record_libraries ;; esac
    if [ "$mode" = session ]; then sleep 2 & wait $! 2>/dev/null; continue; fi
    [ $(( $(date +%s) - started )) -ge "$seconds" ] && break
    if [ "$interactive" = 1 ]; then
        # A key stops it; a timeout (status above 128) is the 1 s pause; end of input waits too.
        rc=0; read -r -s -n 1 -t 1 _ || rc=$?
        [ "$rc" -eq 0 ] && break
        [ "$rc" -gt 128 ] || sleep 1
    else
        sleep 1
    fi
done
trap - INT TERM HUP
running=1
if [ -d "/proc/$pid" ]; then record_libraries; else running=0; say "The game exited during the measurement."; fi

# ---- what the game wrote -------------------------------------------------------------------
if [ -n "$game_log" ] && [ -f "$game_log" ]; then
    tail -c "+$((log_start + 1))" "$game_log" > "$dir/log-window.txt"
    cp "$game_log" "$dir/game.log"
fi
if [ -n "$game_cwd" ]; then
    cp "$game_cwd/tlg.ini" "$dir/" 2>/dev/null
    # shellcheck disable=SC2012  # the newest session folder
    trace_dir=$(ls -td "$game_cwd"/perf-traces/session-* 2>/dev/null | head -n 1)
    if [ -n "$trace_dir" ]; then cp -r "$trace_dir" "$dir/perf-trace" 2>/dev/null; fi
fi

# ---- summary -------------------------------------------------------------------------------
[ -f "$dir/samples.txt" ] || : > "$dir/samples.txt"   # the game was gone before the first sample
awk -v hz="$hz" '
function pct(a, b) { return b > 0 ? 100 * a / b : 0 }
/^@ / { s++; t[s] = $2; next }
/^cpu/ {
    busy = $2 + $3 + $4 + $7 + $8 + $9; total = busy + $5 + $6
    if (!($1 in b0)) { b0[$1] = busy; a0[$1] = total; cores[++ncores] = $1 }
    b1[$1] = busy; a1[$1] = total; next
}
/^F / { fs[$2] += $3; fn[$2]++; next }
/^G / {
    if (!($2 in gn)) gsrc[++ngs] = $2
    gn[$2]++; gv[$2] += $3
    if (NF >= 4 && $4 > 0) { gr[$2] += $3 / $4; grn[$2]++ }
    next
}
/^M / { if ($2 != "" && (mmin == "" || $2 < mmin)) mmin = $2; if ($3 > rss) rss = $3; next }
/^H / { if (!($2 in hmax) || $3 > hmax[$2]) hmax[$2] = $3; next }
/^T / {
    line = substr($0, 3); lp = index(line, "("); rp = 0
    for (k = length(line); k > lp; k--) if (substr(line, k, 1) == ")") { rp = k; break }
    if (!lp || !rp) next
    tid = substr(line, 1, lp - 2); comm = substr(line, lp + 1, rp - lp - 1)
    n = split(substr(line, rp + 2), f, " ")
    ticks = f[12] + f[13]; flt = f[8]
    if (!(tid in first)) { first[tid] = ticks; fs0[tid] = s; ff[tid] = flt; tids[++ntids] = tid }
    if ((tid in last) && ls[tid] == s - 1 && t[s] > t[s - 1]) {
        d = pct((ticks - last[tid]) / hz, (t[s] - t[s - 1]) / 1000)
        if (d > peak[tid]) peak[tid] = d
    }
    name[tid] = comm; last[tid] = ticks; ls[tid] = s; lf[tid] = flt; core[tid] = f[37]
    next
}
END {
    if (s < 2) { print "Not enough samples."; exit }
    dur = (t[s] - t[1]) / 1000
    printf "Measured %.0f s, %d samples\n\n", dur, s
    total = 0
    for (i = 1; i <= ntids; i++) {
        id = tids[i]; span = (t[ls[id]] - t[fs0[id]]) / 1000
        avg[id] = span > 0 ? pct((last[id] - first[id]) / hz, span) : 0
        faults[id] = span > 0 ? (lf[id] - ff[id]) / span : 0
        total += avg[id]
    }
    printf "Game threads: %d, all together %.0f%% of one core (%.1f cores)\n", ntids, total, total / 100
    print "Busiest threads (average and highest 1-second CPU % of one core; page faults per second; last core):"
    for (r = 1; r <= 15 && r <= ntids; r++) {
        best = ""
        for (i = 1; i <= ntids; i++) { id = tids[i]; if (!(id in done) && (best == "" || avg[id] > avg[best])) best = id }
        done[best] = 1
        printf "  %-18s tid %-7s %5.1f%%  peak %5.1f%%  %8.0f faults/s  cpu %s\n", name[best], best, avg[best], peak[best], faults[best], core[best]
    }
    print ""
    print "Cores (busy %, average clock):"
    for (i = 1; i <= ncores; i++) {
        c = cores[i]; clk = fn[c] ? sprintf("%.0f MHz", fs[c] / fn[c] / 1000) : ""
        printf "  %-6s %5.1f%%  %s\n", c, pct(b1[c] - b0[c], a1[c] - a0[c]), clk
    }
    print ""
    if (ngs) {
        print "GPU (kernel counters, averages):"
        for (i = 1; i <= ngs; i++) {
            g = gsrc[i]
            if (grn[g]) printf "  %s: busy %.1f%%\n", g, 100 * gr[g] / grn[g]
            else printf "  %s: %.1f\n", g, gv[g] / gn[g]
        }
    } else print "GPU: the kernel shows no load or clock counters here (see info.txt)"
    print ""
    printf "Memory: lowest MemAvailable %.0f MB, game RSS up to %.0f MB\n", mmin / 1024, rss / 1024
    hot = ""
    for (z in hmax) if (hmax[z] > 60000) hot = hot sprintf(" %s %.0fC", z, hmax[z] / 1000)
    print "Hottest zones above 60C:" (hot == "" ? " none" : hot)
}' "$dir/samples.txt" > "$dir/summary.txt" 2>&1

if [ -f "$dir/log-window.txt" ]; then
    {
        echo ""
        awk '
            index($0, "Frame stats: ") == 1 {
                split(substr($0, 14), a, " "); fps = a[1] + 0; n++; sum += fps
                if (n == 1 || fps < low) low = fps
                p = index($0, "worst frame "); if (p) { w = substr($0, p + 12) + 0; if (w > worst) worst = w }
            }
            END {
                if (n) printf "Game frame stats: %d reports, %.1f FPS average, lowest %.1f, worst frame %.1f ms\n", n, sum / n, low, worst
                else print "Game frame stats: none in this window (ISS_FRAME_STATS off, or the game was loading)"
            }' "$dir/log-window.txt"
        last=$(grep -n '^Frame stats: ' "$dir/log-window.txt" | tail -n 1 | cut -d: -f1)
        if [ -n "$last" ]; then
            echo "The last report:"
            tail -n "+$last" "$dir/log-window.txt" | grep -v '^\[' |
                awk 'NR > 1 && /^(GPU profile|Fault profile|Runtime: wait stats)/ { exit } NR <= 12' | cut -c1-400 | sed 's/^/  /'
        fi
        waits=$(grep -n '^Runtime: wait stats' "$dir/log-window.txt" | tail -n 1 | cut -d: -f1)
        if [ -n "$waits" ]; then
            echo "Waits (TLG_WAIT_STATS, the last 5 s):"
            tail -n "+$((waits + 1))" "$dir/log-window.txt" | grep '^  ' | head -n 12 | cut -c1-300
        fi
        profile=$(grep -n '^GPU profile: [0-9]' "$dir/log-window.txt" | tail -n 1 | cut -d: -f1)
        if [ -n "$profile" ]; then
            echo "GPU time (TLG_GPU_PROFILE, the last 5 s; the busiest passes):"
            tail -n "+$profile" "$dir/log-window.txt" | awk 'NR == 1 || (/^  / && NR <= 13) { print; next } { exit }' |
                cut -c1-200 | sed 's/^/  /'
        fi
        faults=$(grep -n '^Fault profile (5 s):' "$dir/log-window.txt" | tail -n 1 | cut -d: -f1)
        if [ -n "$faults" ]; then
            echo "GPU memory write tracking (TLG_FAULT_PROFILE, the last 5 s):"
            tail -n "+$faults" "$dir/log-window.txt" | awk 'NR == 1 || (/^  / && NR <= 10) { print; next } { exit }' |
                cut -c1-250 | sed 's/^/  /'
        fi
        readbacks=$(grep -n '^Readback stats (5 s):' "$dir/log-window.txt" | tail -n 1 | cut -d: -f1)
        if [ -n "$readbacks" ]; then
            echo "The game's waits for GPU data (TLG_READBACK_STATS, the last 5 s):"
            tail -n "+$readbacks" "$dir/log-window.txt" | head -n 3 | cut -c1-300 | sed 's/^/  /'
        fi
        if [ -n "$last" ]; then
            tail -n "+$last" "$dir/log-window.txt" | grep '^Wait profile: ' | head -n 8 | cut -c1-200 > "$dir/wait-profile.tmp"
            if [ -s "$dir/wait-profile.tmp" ]; then
                echo "Where the GPU thread waits for the GPU (TLG_PERF_DIAG, the last 5 s; source file:line):"
                sed 's/^Wait profile: /  /' "$dir/wait-profile.tmp"
            fi
            rm -f "$dir/wait-profile.tmp"
        fi
        grep -m1 '^Guest CPU:' "$dir/game.log" 2>/dev/null
    } >> "$dir/summary.txt"
fi
# The stall captures (TLG_PERF_TRACE: some seconds around the slowest frames): the time each thread
# spent blocked per frame. Threads go by the trace's own numbers; the one waiting for gpu_tick is
# the GPU command thread, buffer_readback is a game thread waiting for GPU data.
if ls "$dir"/perf-trace/capture-*.jsonl > /dev/null 2>&1; then
    {
        echo ""
        echo "Blocked time per frame in the stall captures (TLG_PERF_TRACE; tN: the trace's thread numbers):"
        for f in "$dir"/perf-trace/capture-*.jsonl; do
            grep -E '"kind":(1|7|8|12|13),' "$f" | awk -v capture="${f##*/}" '
            function field(key,    p, r) {
                p = index($0, "\"" key "\":"); if (!p) return ""
                r = substr($0, p + length(key) + 3); sub(/[,}].*/, "", r); return r
            }
            BEGIN {
                # TlgPerf::Label hashes (FNV-1a) of the wait sites
                lab["6644910108373747099"] = "buffer_readback"; lab["12573352961550233186"] = "copy_threads"
                lab["2743109400169209963"] = "gpu_tick"; lab["5549476453956204289"] = "host_copies"
                lab["10230217879319746"] = "image_refresh"; lab["7272420252035033627"] = "recorder"
                lab["2291695360323361265"] = "shader_capture"; lab["7593465762468503374"] = "shader_compile"
            }
            {
                ts = field("ts_ns") + 0; kind = field("kind"); th = field("thread"); op = field("op")
                if (first == "" || ts < first) first = ts
                if (ts > final) final = ts
                frames[field("frame")] = 1
                if (kind == 1) nframe++
                else if (kind == 7) { wb[th, op] = ts; wo[th, op] = field("object") }
                else if (kind == 8 && ((th, op) in wb)) {
                    o = wo[th, op]; k = "t" th " " ((o in lab) ? lab[o] : "other")
                    if (!(k in w)) wk[++nw] = k
                    w[k] += ts - wb[th, op]; wn[k]++; delete wb[th, op]
                } else if (kind == 12) fb[th, op] = ts
                else if (kind == 13 && ((th, op) in fb)) {
                    k = "t" th
                    if (!(k in fl)) fk[++nf] = k
                    fl[k] += ts - fb[th, op]; fn[k]++; delete fb[th, op]
                }
            }
            END {
                if (!nframe) for (x in frames) nframe++
                if (nframe < 2) exit
                n = nframe - 1
                printf "  %s: %d frames, %.1f ms each\n", capture, n, (final - first) / 1e6 / n
                line = "    waits:"
                for (r = 1; r <= 5 && r <= nw; r++) {
                    best = ""
                    for (i = 1; i <= nw; i++) if (!(wk[i] in used) && (best == "" || w[wk[i]] > w[best])) best = wk[i]
                    used[best] = 1
                    line = line sprintf("  %s %.1f ms (%.1fx)", best, w[best] / 1e6 / n, wn[best] / n)
                }
                print (nw ? line : "    waits: none")
                line = "    in fault handlers:"
                for (r = 1; r <= 4 && r <= nf; r++) {
                    best = ""
                    for (i = 1; i <= nf; i++) if (!(fk[i] in used) && (best == "" || fl[fk[i]] > fl[best])) best = fk[i]
                    used[best] = 1
                    line = line sprintf("  %s %.1f ms (%.1fx)", best, fl[best] / 1e6 / n, fn[best] / n)
                }
                if (nf) print line
            }'
        done
    } >> "$dir/summary.txt"
fi
[ -f "$dir/launcher.txt" ] && grep -m2 '^Vulkan:' "$dir/launcher.txt" >> "$dir/summary.txt"
# Settings that decide the result, with what to look at.
{
    echo ""
    echo "Settings:"
    mem_mb=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
    budget=$(game_env ISS_GC_BUDGET_MB)
    budget=${budget:-$(game_env TLG_GC_BUDGET_MB)}
    if [ -n "$budget" ]; then
        # The GPU shares the RAM here: the texture cache comes out of the same memory as the game.
        # About a fifth of the RAM leaves room for the game itself (~6.5 GB) and the system.
        suggest=$(( mem_mb / 5 / 100 * 100 ))
        if [ "$budget" -gt $(( mem_mb * 3 / 10 )) ]; then
            echo "  VRAM budget ${budget} MB of ${mem_mb} MB shared RAM: too high, the game and the GPU share it (try about ${suggest} MB)"
        else
            echo "  VRAM budget ${budget} MB of ${mem_mb} MB shared RAM"
        fi
    fi
    verbose_now=$(game_env TLG_VERBOSE_LOG); verbose_now=${verbose_now:-$(game_env ISS_VERBOSE_LOG)}
    case $verbose_now in ''|0) echo "  Detailed log: off" ;;
        *) echo "  Detailed log: ON (every GPU debug line written unbuffered; it costs frames: Fixes > Detailed log)" ;; esac
    # GPU accuracy (TLG_READBACKS wins over ISS_READBACKS; 1 when neither is set).
    readbacks=$(game_env TLG_READBACKS); readbacks=${readbacks:-$(game_env ISS_READBACKS)}
    case ${readbacks:-1} in
        0) echo "  GPU accuracy: Fast (readbacks $readbacks): the game never waits for GPU data (GPU particles are missing)" ;;
        1) echo "  GPU accuracy: Relaxed (readbacks ${readbacks:-1}): each game write into GPU-written memory makes the GPU"
           echo "    thread wait until the GPU has finished all its work. Deferred readback, write merge and eager"
           echo "    readback only work with Precise (2): their switches below have no effect" ;;
        2) echo "  GPU accuracy: Precise (readbacks 2)" ;;
    esac
    for k in ISS_READBACKS ISS_EAGER_READBACK ISS_DEFERRED_READBACK ISS_WRITE_MERGE ISS_STALE_BUFFER_READS TLG_STALE_BUFFER_READS TLG_DOWNLOAD_WINDOW_KB ISS_UPSCALER TU_DEBUG TLG_GPU_PROFILE TLG_FAULT_PROFILE TLG_WAIT_STATS; do
        v=$(game_env "$k"); [ -n "$v" ] && echo "  $k=$v"
    done
    if [ -s "$dir/libraries.txt" ]; then
        icd=$(grep -o 'libvulkan_[A-Za-z0-9_]*\.so' "$dir/libraries.txt" | sort -u | tr '\n' ' ')
        layers=$(grep -i -E 'layer|valve|mangohud|fossilize' "$dir/libraries.txt" | sed 's#.*/##' | sort -u | tr '\n' ' ')
        echo "  Vulkan in the game: driver ${icd:-not found}; layers: ${layers:-none} (libraries.txt)"
    fi
    v=$(game_env VK_INSTANCE_LAYERS); [ -n "$v" ] && echo "  VK_INSTANCE_LAYERS=$v (Steam asks for these)"
    if [ -s "$dir/fex-app-config.json" ]; then
        echo "  FEX settings from ArmadaOS (FEX_APP_CONFIG, see fex-app-config.json): $(tr -d ' \n\t' < "$dir/fex-app-config.json" | cut -c1-300)"
    fi
    [ -n "$game_cwd" ] && grep -E '^(scene_res|lod_scale|mip_lod_bias|far_clip|region_lod|region_fade|fps_limit|frames_queued)=' "$game_cwd/tlg.ini" 2>/dev/null | tr '\n' ' ' | sed 's/^/  tlg.ini: /;s/ $/\n/'
    # Frame pacing: with Frame rate limit "Unlimited" (fps_limit=0, the default) a finished frame
    # waits for the next 60 Hz tick (driver.cpp PresentThread), so every frame lasts a whole number
    # of ticks: 35-49 ms frames become 50 ms (20 FPS). A limit shows each frame when it is ready.
    fps_limit=""; vsync_ini=""
    if [ -n "$game_cwd" ]; then
        fps_limit=$(sed -n 's/^fps_limit=//p' "$game_cwd/tlg.ini" 2>/dev/null | head -n 1)
        vsync_ini=$(sed -n 's/^vsync=//p' "$game_cwd/tlg.ini" 2>/dev/null | head -n 1)
    fi
    echo "  Frame rate limit: $(case ${fps_limit:-0} in 0) echo 'Unlimited (each frame waits for the next 60 Hz tick)' ;; *) echo "$fps_limit FPS (frames shown when ready)" ;; esac); VSync: $(case $vsync_ini in 1) echo on ;; 0) echo off ;; *) echo '?' ;; esac)"
    if [ -f "$dir/perf-trace/frames.csv" ]; then
        # Frames over 20 ms only (the menus run at the cap); by chance about 12% land on a tick.
        on_tick=$(awk -F, 'NR > 2 && $3 > 20000000 { x = $3 / 16666667; d = x - int(x + 0.5); if (d < 0) d = -d; n++; if (d < 0.06) q++ }
                           END { if (n >= 100) printf "%.0f", 100 * q / n }' "$dir/perf-trace/frames.csv")
        if [ -n "$on_tick" ]; then
            if [ "$on_tick" -ge 50 ]; then
                echo "  Frames lasting whole 60 Hz ticks: ${on_tick}%: frames wait for the tick (about 8 ms each on average);"
                echo "    Frame rate limit 60 with VSync off shows them when ready"
            else
                echo "  Frames lasting whole 60 Hz ticks: ${on_tick}% (frames are shown when ready)"
            fi
        fi
    fi
    for c in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -r "$c/scaling_max_freq" ] || continue
        lim=$(cat "$c/scaling_max_freq"); hw=$(cat "$c/cpuinfo_max_freq" 2>/dev/null || echo "$lim")
        note=""; [ "$lim" -lt "$hw" ] && note=" (limited to $((lim * 100 / hw))%)"
        echo "  CPU ${c##*/} (cpus $(cat "$c/related_cpus")): $(cat "$c/scaling_governor") governor, max $((lim / 1000)) of $((hw / 1000)) MHz$note"
    done
    for d in /sys/class/devfreq/*; do
        case ${d##*/} in *gpu*|*kgsl*|3d00000*) ;; *) continue ;; esac
        [ -r "$d/governor" ] && echo "  GPU ${d##*/}: $(cat "$d/governor") governor, $(( $(cat "$d/min_freq") / 1000000 ))-$(( $(cat "$d/max_freq") / 1000000 )) MHz"
    done
} >> "$dir/summary.txt" 2>/dev/null

# ---- per minute ----------------------------------------------------------------------------
# One row per minute: the game's FPS and GPU time (its own reports: idle, the GPU's time between
# submissions; data wait, the game's threads waiting for GPU data, all together, per frame), the
# whole game's CPU in cores, the main threads' CPU (main: the game's main thread under FEX; rec: tlg:DrawRec; vk:
# tlg:VkRecorder; cmd: shadPS4:GpuComm), each CPU cluster's average clock, the lowest free memory,
# the hottest sensor and the render resolution in effect (from the game's "Scene resolution" lines).
awk -v hz="$hz" -v gpid="$pid" -v bucket="${ISS_PROFILE_BUCKET_S:-60}" '
function stat_ticks(line,    lp, rp, k, f) {
    lp = index(line, "("); rp = 0
    for (k = length(line); k > lp; k--) if (substr(line, k, 1) == ")") { rp = k; break }
    if (!lp || !rp) return -1
    stid = substr(line, 1, lp - 2); scomm = substr(line, lp + 1, rp - lp - 1)
    split(substr(line, rp + 2), f, " "); return f[12] + f[13]
}
/^@ / { s++; now = $2; if (s == 1) t0 = now; m = int((now - t0) / (bucket * 1000))
        if (m > last) last = m; if (!(m in seen)) seen[m] = 1; next }
/^P / { v = stat_ticks(substr($0, 3)); if (v < 0) next
        if (!(m in pa)) { pa[m] = v; pat[m] = now } pb[m] = v; pbt[m] = now; next }
/^T / { v = stat_ticks(substr($0, 3)); if (v < 0) next
        key = stid == gpid ? "main" : scomm == "tlg:DrawRec" ? "rec" : scomm == "tlg:VkRecorder" ? "vk" : scomm == "shadPS4:GpuComm" ? "cmd" : ""
        if (key == "") next
        k = key SUBSEP stid SUBSEP m
        if (!(k in ta)) { ta[k] = v; tat[k] = now; keys[++nk] = k }
        tb[k] = v; tbt[k] = now; next }
/^C / { ck = $2 SUBSEP m; csum[ck] += $3; ccnt[ck]++
        if (!($2 in pol)) { pol[$2] = 1; pols[++np] = $2 } next }
/^M / { if ($2 != "" && (!(m in mm) || $2 < mm[m])) mm[m] = $2; next }
/^H / { if (!(m in hm) || $3 > hm[m]) hm[m] = $3; next }
/^X Frame stats: / { fsum[m] += $4; fcnt[m]++; next }
/^X GPU profile: / { gsum[m] += $4; gcnt[m]++; next }
/\(between submissions/ { isum[m] += $2; icnt[m]++; next }
/^X Readback stats / { rsum[m] += $9 + $12; rcnt[m]++; next }
/^X   deferred: / { p = index($0, "guest wait "); if (p) rsum[m] += substr($0, p + 11) + 0; next }
/^X Frame pacing: / { psum[m] += $5; pdev[m] += $8; pcnt[m]++; next }
/^X Scene resolution: / { r = $5; sub(/,$/, "", r); scene[m] = r; changed[m] = 1; next }
END {
    if (s < 2) { print "Per minute: not enough samples"; exit }
    printf "Per %s (frame ms: median time between frames +- spread, a steady 50.0 = locked to every 3rd 60 Hz vblank;\n", bucket == 60 ? "minute" : bucket " s"
    printf "GPU ms: its timeline per frame, idle included; data wait: the game threads waiting for GPU data, per frame;\n"
    printf "CPU in %% of one core; clocks in MHz; render: the 3D scene size in effect)\n"
    printf "%4s %6s %12s %7s %5s %9s %6s %5s %5s %5s %5s", "min", "FPS", "frame ms", "GPU ms", "idle", "data wait", "cores", "main", "rec", "vk", "cmd"
    for (i = 1; i <= np; i++) printf " %8s", pols[i]
    printf " %7s %5s  %s\n", "freeMB", "maxC", "render"
    cur = "1920x1080"
    for (mi = 0; mi <= last; mi++) {
        if (!(mi in seen)) continue
        if (mi in scene) cur = scene[mi]
        split("main rec vk cmd", order, " ")
        for (j = 1; j <= 4; j++) { val[order[j]] = 0; has[order[j]] = 0 }
        for (i = 1; i <= nk; i++) {
            split(keys[i], part, SUBSEP)
            if (part[3] == mi && tbt[keys[i]] > tat[keys[i]]) {
                val[part[1]] += 100 * (tb[keys[i]] - ta[keys[i]]) / hz / ((tbt[keys[i]] - tat[keys[i]]) / 1000)
                has[part[1]] = 1
            }
        }
        # The readback reports cover 5 s each: their wait over the frames of that time.
        fps = (mi in fcnt) ? fsum[mi] / fcnt[mi] : 0
        printf "%4d %6s %12s %7s %5s %9s %6s", mi, (mi in fcnt) ? sprintf("%.1f", fps) : "-",
            (mi in pcnt) ? sprintf("%.1f+-%.1f", psum[mi] / pcnt[mi], pdev[mi] / pcnt[mi]) : "-",
            (mi in gcnt) ? sprintf("%.1f", gsum[mi] / gcnt[mi]) : "-",
            (mi in icnt) ? sprintf("%.1f", isum[mi] / icnt[mi]) : "-",
            (mi in rcnt && fps > 0) ? sprintf("%.1f", rsum[mi] / (rcnt[mi] * 5 * fps)) : "-",
            (mi in pa && pbt[mi] > pat[mi]) ? sprintf("%.1f", (pb[mi] - pa[mi]) / hz / ((pbt[mi] - pat[mi]) / 1000)) : "-"
        for (j = 1; j <= 4; j++) printf " %5s", has[order[j]] ? sprintf("%.0f", val[order[j]]) : "-"
        for (i = 1; i <= np; i++) { ck = pols[i] SUBSEP mi; printf " %8s", ccnt[ck] ? sprintf("%.0f", csum[ck] / ccnt[ck] / 1000) : "-" }
        printf " %7s %5s  %s%s\n", (mi in mm) ? sprintf("%.0f", mm[mi] / 1024) : "-",
            (mi in hm) ? sprintf("%.0f", hm[mi] / 1000) : "-", cur, (mi in changed) ? " (changed here)" : ""
    }
}' "$dir/samples.txt" > "$dir/minutes.txt" 2>&1
[ "$running" = 1 ] && [ "$mode" != session ] && echo "(The game is still running; close it as usual.)" >> "$dir/summary.txt"
# The table first: it is what a session is read by.
{ cat "$dir/minutes.txt"; echo ""; cat "$dir/summary.txt"; } > "$dir/summary.new" && mv "$dir/summary.new" "$dir/summary.txt"

echo ""
cat "$dir/summary.txt"
if [ "$mode" = session ]; then
    say "Results: $dir"
    # The launcher still open (its window was not closed by the game's start): its next game gets
    # a folder of its own. Otherwise back to Steam with the launcher's exit status.
    sleep 1
    if alive "$child"; then
        say "The launcher is still open: waiting for its next game."
        exec "${BASH:-bash}" "$0" session-next "$child" "$pid"
    fi
    if [ "$next_game" = 1 ]; then exit 0; fi
    wait "$child"
    exit $?
fi
tar -czf "$dir.tar.gz" -C "$base" "$name" || die "cannot pack $dir"
echo ""
echo "RESULT=$dir.tar.gz"

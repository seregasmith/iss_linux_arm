#!/usr/bin/env bash
# pack_release_appimage.sh: packs an official Linux release of the port (the folder unpacked from
# infamous-linux-x86_64.tar.gz on the GitHub releases page: "inFAMOUS Second Son", _internal/,
# out/, scripts/, VERSION, port.env, ...) into one x86_64 AppImage, e.g. for Steam on an ARM
# handheld whose system runs x86_64 programs through FEX.
#
# Usage: port/tools/pack_release_appimage.sh RELEASE_DIR [OUTPUT.AppImage]
#   OUTPUT   default: port/dist/<release folder name>-<VERSION>.AppImage
# Tools: appimagetool and the x86_64 AppImage runtime. APPIMAGETOOL=<path> and RUNTIME_FILE=<path>
# use local copies; otherwise they are downloaded once from github.com/AppImage into
# ~/.cache/iss-appimage (appimagetool for this machine: x86_64 or aarch64). Runs on Linux.
#
# The release writes next to its executable (out/: the prepared game files and the logs; user/:
# saves and settings) and an AppImage is read-only, so the AppImage installs itself: its first
# start, and the first start of a newer version, copies the release to ISS_INSTALL_DIR (default
# ~/.local/share/infamous-pc-x86_64) and starts the launcher from there. Saves, settings and
# generated files there are kept. "--classic" as the first argument starts the classic launcher.
# A user/ folder or logs inside RELEASE_DIR are not packed.
set -euo pipefail
umask 022

die() { echo "ERROR: $*" >&2; exit 1; }
[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '2,19s/^# \{0,1\}//p' "$0"; exit 2; }
release=$(cd -- "$1" && pwd) || die "no folder $1"
[ -f "$release/VERSION" ] && [ -d "$release/_internal" ] && [ -d "$release/out" ] ||
    die "$release does not look like a release folder (VERSION, _internal/, out/)"
name=$(sed -n 's/^PORT_NAME="\([^"]*\)".*/\1/p' "$release/port.env" 2>/dev/null)
name=${name:-inFAMOUS Second Son}
icon=$(sed -n 's/^PORT_ICON="\([^"]*\)".*/\1/p' "$release/port.env" 2>/dev/null)
icon=${icon:-infamous}
[ -x "$release/$name" ] || die "no launcher \"$name\" in $release"
version=$(tr -d '\r\n' < "$release/VERSION")
here=$(cd -- "$(dirname -- "$0")" && pwd)
out=${2:-$(dirname "$here")/dist/$(basename "$release")-$version.AppImage}
mkdir -p "$(dirname "$out")"
out=$(cd -- "$(dirname "$out")" && pwd)/$(basename "$out")

# ---- tools -----------------------------------------------------------------------------------
cache=${XDG_CACHE_HOME:-$HOME/.cache}/iss-appimage
fetch() { # url file
    [ -s "$2" ] && return 0
    mkdir -p "$(dirname "$2")"
    echo "==> Downloading $(basename "$2")"
    curl -fsSL -o "$2.part" "$1" || die "cannot download $1 (set APPIMAGETOOL / RUNTIME_FILE to local copies)"
    mv "$2.part" "$2"
}
host=$(uname -m)
tool=${APPIMAGETOOL:-}
if [ -z "$tool" ]; then
    tool=$cache/appimagetool-$host.AppImage
    fetch "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$host.AppImage" "$tool"
fi
runtime=${RUNTIME_FILE:-$cache/runtime-x86_64}
[ -n "${RUNTIME_FILE:-}" ] ||
    fetch https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64 "$runtime"
chmod +x "$tool"

# ---- the AppDir ------------------------------------------------------------------------------
work=$(mktemp -d "${TMPDIR:-/tmp}/iss-appimage.XXXXXX")
trap 'rm -rf "$work"' EXIT
appdir=$work/AppDir
mkdir -p "$appdir/release"
echo "==> Copying $release ($(du -sh "$release" | cut -f1))"
tar -C "$release" --exclude=./user --exclude=./out/logs --exclude='*.AppImage' -cf - . |
    tar -C "$appdir/release" -xf -
cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
# Installs this release on its first start (and on a new version), then starts it from there:
# the release writes next to its executable, an AppImage is read-only. See pack_release_appimage.sh.
set -eu
here=$(dirname "$(readlink -f "$0")")
src=$here/release
name=$(sed -n 's/^PORT_NAME="\([^"]*\)".*/\1/p' "$src/port.env" 2>/dev/null || true)
name=${name:-inFAMOUS Second Son}
dest=${ISS_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/infamous-pc-x86_64}
version=$(cat "$src/VERSION" 2>/dev/null || echo unknown)
if [ "$(cat "$dest/.appimage-version" 2>/dev/null || true)" != "$version" ]; then
    echo "Installing $name $version into $dest (saves, settings and generated files are kept)"
    mkdir -p "$dest"
    rm -f "$dest/.appimage-version"
    cp -a -f "$src/." "$dest/"
    printf '%s\n' "$version" > "$dest/.appimage-version"
fi
launcher=$name
if [ "${1:-}" = --classic ]; then
    shift
    launcher="$name (classic)"
fi
cd "$dest"
exec "$dest/$launcher" "$@"
APPRUN
chmod 755 "$appdir/AppRun"

cat > "$appdir/$icon.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$name
Comment=$name (PC port $version)
Exec=AppRun
Icon=$icon
Terminal=false
Categories=Game;
StartupWMClass=$icon-pc
DESKTOP
if [ -f "$release/launcher/$icon.png" ]; then
    cp "$release/launcher/$icon.png" "$appdir/$icon.png"
else
    # appimagetool needs an icon: a 1x1 PNG when the release has none.
    printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89\0\0\0\rIDATx\x9cc\xf8\x0f\0\0\x01\x01\0\x05\x18\xd8N\0\0\0\0IEND\xaeB`\x82' > "$appdir/$icon.png"
fi
ln -s "$icon.png" "$appdir/.DirIcon"
# Readable by everyone inside the image (files from macOS can carry owner-only modes, and the
# image's files belong to root once mounted).
chmod -R u+rwX,go+rX,go-w "$appdir"

# ---- pack ------------------------------------------------------------------------------------
echo "==> Packing $out"
# Emptied rather than removed: the folder may allow writing but not deleting.
if [ -e "$out" ]; then : > "$out"; fi
# APPIMAGE_EXTRACT_AND_RUN: appimagetool is an AppImage itself; this way it needs no FUSE.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --no-appstream --runtime-file "$runtime" "$appdir" "$out"
chmod 755 "$out"
echo "==> Done: $out ($(du -h "$out" | cut -f1)); it installs into ~/.local/share/infamous-pc-x86_64 on first start"

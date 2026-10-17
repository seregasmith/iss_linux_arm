#!/usr/bin/env bash
# Builds dist/infamous-linux-<arch>.AppImage (x86_64, aarch64): the port's current build (run
# build.sh first), its scripts and both launchers, bundled with their Nix closure (nix-appimage:
# the AppImage mounts its /nix/store with user namespaces, available on SteamOS and most desktops).
# Based on the Bloodborne ARM port's packaging/appimage.sh; ../../build_docker.sh appimage runs it.
# Running it opens the Qt Quick launcher; `--classic` the Tk one; `--play` starts the game with the
# launcher's saved settings. Data (generated files, the default saves folder):
# ~/.local/share/infamous-pc (ISS_DATA_DIR).
# ISS_TURNIP_SRC=<Mesa tree> (aarch64): the Turnip driver from that tree (packaging/default.nix).
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
[[ -f out/tlg-probe && -f out/gpu/libtlggpu.so ]] || { echo 'Build first: bash build.sh' >&2; exit 1; }
arch=$(uname -m)
libs=(out/tlg-probe out/gpu/libtlggpu.so out/tlg-gpu-capabilities)
if [[ $arch == aarch64 ]]; then
    [[ -f out/fex/libtlgcpu.so ]] || { echo 'Build first: bash build.sh (out/fex/libtlgcpu.so is missing)' >&2; exit 1; }
    libs+=(out/fex/libtlgcpu.so)
fi
# NIX: the nix command (default nix; e.g. "nix-portable nix" without a system Nix).
# ISS_NIXPKGS: the nixpkgs the build's nix-shell used (-I nixpkgs=...), when not <nixpkgs>.
read -r -a nix <<< "${NIX:-nix}"
include=()
if [[ -n ${ISS_NIXPKGS:-} ]]; then include=(-I "nixpkgs=$ISS_NIXPKGS"); fi
root=$PWD
# The libraries' store paths: for each library a binary needs (NEEDED), the RUNPATH directory it
# is found in (their closures come along). Not every RUNPATH entry: built in nix-shell, the
# binaries list the lib directories of the whole build environment (the full GCC, Vulkan headers,
# SPIRV-Tools, ...), hundreds of MB the game never loads.
needed_dirs() {
    local elf=$1 lib dir
    local -a rpath
    mapfile -t rpath < <(readelf -d "$elf" | sed -n 's/.*R\{0,1\}U\{0,1\}N\{0,1\}PATH.*\[\(.*\)\]/\1/p' | tr ':' '\n')
    for lib in $(readelf -d "$elf" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        for dir in "${rpath[@]}"; do
            [[ $dir == /nix/store/* && -e $dir/$lib ]] && { echo "$dir"; break; }
        done
    done
}
{
    echo '['
    for elf in "${libs[@]}"; do
        needed_dirs "$elf"
    done | grep -o '^/nix/store/[^/]*' | sort -u | grep -v -- '-nix-shell$' | sed 's/.*/  "&"/'
    echo ']'
} > packaging/runtime-paths.nix
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(cd "$work" && "${nix[@]}" bundle --impure "${include[@]}" --bundler github:ralismark/nix-appimage \
    --expr "import $root/packaging {}")
shopt -s nullglob
bundled=("$work"/*.AppImage)
shopt -u nullglob
[[ ${#bundled[@]} -eq 1 ]] || { echo "nix bundle made no single AppImage in $work" >&2; ls -la "$work" >&2; exit 1; }
image=$(readlink "${bundled[0]}" || echo "${bundled[0]}")
# nix-portable: its /nix/store is ~/.nix-portable/nix/store outside its sandbox.
if [[ ! -e $image && -e ${NP_LOCATION:-$HOME}/.nix-portable$image ]]; then
    image=${NP_LOCATION:-$HOME}/.nix-portable$image
fi
mkdir -p dist
install -m755 "$image" "dist/infamous-linux-$arch.AppImage"
# A GC root for the package: nix-collect-garbage keeps it, and with it the outputs built here from
# source (PySide6 with the launcher's Qt modules; on aarch64 the patched Turnip), so the next
# AppImage does not build them again (only a nixpkgs update does).
nix-build --impure "${include[@]}" packaging -o out/nix-roots/infamous > /dev/null
ls -lh "dist/infamous-linux-$arch.AppImage"

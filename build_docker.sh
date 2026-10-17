#!/bin/bash
# build_docker.sh: build this repository (ARM_Linux_infamous_ss: the inFAMOUS Second Son port,
# HayatoG/iss_pc) in a Linux Docker container on any host, for either target architecture:
#   aarch64  ARM64 Linux devices (Snapdragon 8 Elite handhelds): the game's x86-64 code runs in
#            FEXCore (port/cpu, port/third_party/FEX), as in the Bloodborne ARM port
#            -> port/dist/infamous-linux-aarch64.AppImage
#   x86_64   x86-64 Linux PCs and the Steam Deck (the game's code runs directly on the CPU, no FEX)
#            -> port/dist/infamous-linux-x86_64.AppImage
# Hosts: macOS on Apple Silicon or Intel (Docker Desktop, OrbStack or colima), Linux on x86-64 or
# arm64 (Docker Engine). A target that matches Docker's own architecture builds natively; the
# other one runs emulated (see "Emulation" below).
# Usage:  ./build_docker.sh [--arch aarch64|x86_64] [build|test|appimage|shell|clean]
#   --arch    target architecture (or ISS_ARCH=...; arm64 and amd64 work too). Default: Docker's own
#             architecture, which needs no emulation (aarch64 on Apple Silicon, x86_64 on a PC)
#   build     (default) port/build.sh: out/tlg-probe, out/tlg-gpu-capabilities, out/gpu/libtlggpu.so,
#             and on aarch64 out/fex/libtlgcpu.so (FEXCore)
#   test      build, then the project's own unit tests (build.sh --test)
#   appimage  build, then port/dist/infamous-linux-<arch>.AppImage (port/packaging/appimage.sh with
#             port/packaging/default.nix: the game binaries, the preparation scripts, the Qt Quick
#             launcher (--classic: the Tk one), Mesa's Vulkan drivers; for aarch64 Turnip, patched
#             for the Adreno 830). The first run builds PySide6 and, on aarch64, Turnip from source.
#             Data folder of the packaged port: ~/.local/share/infamous-pc
#   shell     interactive shell in that target's build environment (port/shell.nix), in port/
#   clean     delete that target's Docker image and Nix store volume (the source tree is untouched)
# (The Windows release and the Ubuntu tar.gz are built elsewhere: .github/workflows/build.yml.)
#
# Build directories (build.sh always writes port/out/ and port/pgo/, so each target gets its own):
#   aarch64  port/out and port/pgo
#   x86_64   port/build-x86_64/out and port/build-x86_64/pgo, mounted over port/out and port/pgo in
#            the container (.gitignore's out/ and pgo/ patterns cover them)
#   Both targets share port/dist/ (the AppImage names carry the arch) and
#   port/packaging/runtime-paths.nix (rewritten by every appimage run), and patch the same
#   fsr-vulkan submodule: one build of a tree at a time.
#
# The script runs no git commands on the repository. Check out the submodules yourself first:
#   git submodule update --init --recursive
# (port/third_party/FEX is needed for aarch64 only.) build.sh applies
# port/gpu/patches/fsr-vulkan/*.patch inside the fsr-vulkan submodule (git status then shows that
# submodule as modified).
# Linux host with Docker Engine: files made in the container belong to root there, so at the end
# the script gives the root-owned files in what the build writes back to you (port/out, port/pgo,
# port/dist, port/packaging/runtime-paths.nix, the fsr-vulkan submodule and its .git/modules
# directory, which build.sh's own git commands can touch). Ownership only, never contents. Not
# with rootless Docker, Podman or Docker Desktop, which map the container's root to you already.
#
# Emulation (a target other than Docker's architecture) works, but is slower:
#   Apple Silicon -> x86_64: Rosetta. Docker Desktop: Settings > General > "Use Rosetta for
#     x86_64/amd64 emulation on Apple Silicon" (without it QEMU: much slower). OrbStack: built in.
#     colima: colima start --vm-type vz --vz-rosetta
#   Intel/AMD -> aarch64: QEMU, many times slower than native; for appimage, the Turnip (Mesa) and
#     PySide6 compiles alone can take hours. Docker Desktop and OrbStack include QEMU. Linux:
#     register it once per boot: docker run --privileged --rm tonistiigi/binfmt --install arm64
#     (or install the distribution's qemu-user-static package).
#   Some tests (test) can fail under emulation even though the build is fine.
#
# Settings (environment variables):
#   ISS_ARCH        target, as --arch (the option wins)
#   ISS_SRC         source tree to build (default: the directory this script is in)
#   ISS_LTO         ON|OFF link-time optimization of the GPU library (build.sh's TLG_LTO; default
#                   here: OFF, faster and far less RAM; build.sh's own default is ON)
#   TLG_PGO         off|generate|use, passed to build.sh (default: build.sh's own choice, "use" when
#                   the target's pgo/ holds a profile)
#   JOBS            parallel compiler processes (default: picked from Docker's RAM, about 2 GB each).
#                   If the compiler still gets "Killed" (out of memory): JOBS=2 ./build_docker.sh
#   ISS_NIX_VOLUME  Docker volume for the target's Nix store (default: iss-nix for aarch64,
#                   iss-nix-x86_64). The Bloodborne build_docker.sh pins the same nixpkgs, so its
#                   volume can be shared to skip downloading the toolchain again (and, for
#                   appimage, building the same Turnip again: the derivation is the same):
#                     ISS_NIX_VOLUME=bbport-nix ./build_docker.sh                   (aarch64)
#                     ISS_NIX_VOLUME=bbport-nix-x86_64 ./build_docker.sh --arch x86_64
#                   `clean` deletes only this script's own iss-* volumes.
#   GITHUB_TOKEN    optional GitHub token for Nix downloads (appimage), if GitHub's API rate limit hits
#   ISS_TURNIP_SRC  aarch64 appimage only (BB_TURNIP_SRC, the Bloodborne script's name, works too): a
#                   Mesa source tree on this machine for the AppImage's Turnip instead of nixpkgs'
#                   Mesa release (port/packaging/default.nix), e.g. the turnip/gen8 branch:
#                     git clone --depth 1 -b turnip/gen8 https://github.com/whitebelyash/mesa-unified
#                   Mounted read-only into the container. (x86_64 packages nixpkgs' Mesa with the
#                   radeon and intel Vulkan drivers, no Turnip.)
#   ISS_TURNIP_PATCHES  0: build that tree without the port's Turnip patches (default: applied where
#                   they apply, Adreno 830 chip IDs added where missing; BB_TURNIP_PATCHES works too)
#   ISS_PACKAGE_SELFTEST  0: make the package without its check (the Qt launcher opened offscreen
#                   with every page; it stops a package whose launcher would not start)
#
# Written for macOS's stock bash 3.2 and any newer bash.
set -eo pipefail

# nixos-unstable, 2026-10-10: the same as the Bloodborne ARM port's build_docker.sh.
NIXPKGS_REV=6510408d147d8c5e6d76043e899e9251756f6a75
ISS_LTO=${ISS_LTO:-OFF}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SRC=${ISS_SRC:-$HERE}
ARCH=${ISS_ARCH:-}
MODE=build
FEX_DIR=port/third_party/FEX

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { echo "Usage: $0 [--arch aarch64|x86_64] [build|test|appimage|shell|clean]" >&2; exit 2; }
# aarch64 | x86_64 | "" for the spellings uname, Docker and people use.
norm_arch() {
    case $1 in
        aarch64|arm64|armv8*) echo aarch64 ;;
        x86_64|amd64|x64|x86-64|x86) echo x86_64 ;;
        *) echo "" ;;
    esac
}

while [ $# -gt 0 ]; do
    case $1 in
        --arch) [ $# -ge 2 ] || usage; ARCH=$2; shift 2 ;;
        --arch=*) ARCH=${1#--arch=}; shift ;;
        -h|--help) awk 'NR > 1 && /^set -eo/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        build|test|appimage|shell|clean) MODE=$1; shift ;;
        package) MODE=appimage; shift ;;
        *) echo "ERROR: unknown argument '$1'" >&2; usage ;;
    esac
done
case $ISS_LTO in ON|OFF) ;; *) die "ISS_LTO must be ON or OFF" ;; esac
case ${TLG_PGO:-} in ''|off|generate|use) ;; *) die "TLG_PGO must be off, generate or use" ;; esac
TURNIP_SRC_IN=${ISS_TURNIP_SRC:-${BB_TURNIP_SRC:-}}
TURNIP_PATCHES=${ISS_TURNIP_PATCHES:-${BB_TURNIP_PATCHES:-}}
case $TURNIP_PATCHES in ''|0|1) ;; *) die "ISS_TURNIP_PATCHES must be 0 or 1" ;; esac
case ${ISS_PACKAGE_SELFTEST:-} in ''|0|1) ;; *) die "ISS_PACKAGE_SELFTEST must be 0 or 1" ;; esac

command -v docker >/dev/null || die "docker not found. Install Docker Desktop, OrbStack, colima or Docker Engine."
docker info >/dev/null 2>&1 || die "Docker is installed but not running (or this user may not use it)."

DOCKER_ARCH=$(norm_arch "$(docker info --format '{{.Architecture}}' 2>/dev/null)")
[ -n "$DOCKER_ARCH" ] || die "cannot tell Docker's CPU architecture (docker info --format '{{.Architecture}}')"
if [ -z "$ARCH" ]; then
    ARCH=$DOCKER_ARCH
else
    wanted=$(norm_arch "$ARCH")
    [ -n "$wanted" ] || die "unknown target architecture '$ARCH' (aarch64 or x86_64)"
    ARCH=$wanted
fi
case $ARCH in
    aarch64) PLATFORM=linux/arm64 ;;
    x86_64)  PLATFORM=linux/amd64 ;;
esac
DOCKER_PLATFORM_ARCH=${PLATFORM#linux/}   # arm64 | amd64, as `docker image inspect` reports it

# Per target: Docker image, Nix store volume (a store holds one architecture's Nix itself, so they
# can't share one), and build directory under port/.
if [ "$ARCH" = aarch64 ]; then
    IMAGE="iss-builder:${NIXPKGS_REV:0:8}"
    OWN_VOLUME=iss-nix
    BUILD_DIR=""
else
    IMAGE="iss-builder:${NIXPKGS_REV:0:8}-$ARCH"
    OWN_VOLUME=iss-nix-$ARCH
    BUILD_DIR=build-$ARCH
fi
NIX_VOLUME=${ISS_NIX_VOLUME:-$OWN_VOLUME}
OUT_DESC=port/${BUILD_DIR:+$BUILD_DIR/}out

if [ "$MODE" = clean ]; then
    docker image rm "$IMAGE" 2>/dev/null || true
    echo "Removed the $ARCH build image $IMAGE."
    if [ "$NIX_VOLUME" = "$OWN_VOLUME" ]; then
        docker volume rm "$NIX_VOLUME" 2>/dev/null || true
        echo "Removed the $ARCH Nix store volume $NIX_VOLUME (the next build downloads it again)."
    else
        echo "Kept the Nix store volume $NIX_VOLUME: it is not this script's own ($OWN_VOLUME)."
    fi
    echo "The source tree was not touched (this target's build outputs: $OUT_DESC/, port/dist/)."
    exit 0
fi

# The source tree: the project's own files must be there, and the submodules checked out.
SRC=$(cd -- "$SRC" 2>/dev/null && pwd) || die "ISS_SRC directory not found"
[ -f "$SRC/port/build.sh" ] && [ -f "$SRC/port/shell.nix" ] && [ -d "$SRC/port/gpu" ] ||
    die "$SRC is not the iss_pc source tree (no port/build.sh, port/shell.nix, port/gpu). Put this script in its root or set ISS_SRC."
is_empty() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
submodule_paths() { # paths from a .gitmodules file, without git
    while read -r key _ value; do
        if [ "$key" = path ]; then echo "$value"; fi
    done < "$1"
}
missing=""
for p in $(submodule_paths "$SRC/.gitmodules"); do
    if [ "$ARCH" != aarch64 ] && [ "$p" = "$FEX_DIR" ]; then continue; fi   # FEX: aarch64 only
    if is_empty "$SRC/$p"; then missing="$missing $p"; fi
done
if [ "$ARCH" = aarch64 ] && [ -f "$SRC/$FEX_DIR/.gitmodules" ]; then
    for p in $(submodule_paths "$SRC/$FEX_DIR/.gitmodules"); do
        case $p in *fex-*-bins) continue ;; esac   # FEX's test data: not needed to build
        if is_empty "$SRC/$FEX_DIR/$p"; then missing="$missing $FEX_DIR/$p"; fi
    done
fi
if [ -n "$missing" ]; then
    echo "ERROR: submodules are not checked out in $SRC:" >&2
    for p in $missing; do echo "  $p" >&2; done
    echo "This script runs no git commands on your repository. Check them out yourself:" >&2
    echo "  cd \"$SRC\" && git submodule update --init --recursive" >&2
    exit 1
fi
if [ "$ARCH" = aarch64 ] && [ ! -f "$SRC/$FEX_DIR/External/vixl/CMakeLists.txt" ]; then
    echo "ERROR: FEX (FEXCore runs the game's x86-64 code on aarch64) is not checked out in $SRC/$FEX_DIR." >&2
    echo "This script runs no git commands on your repository. Add it yourself, e.g. at FEX-2609.1:" >&2
    echo "  cd \"$SRC\" && git submodule add https://github.com/FEX-Emu/FEX.git $FEX_DIR" >&2
    echo "  git -C $FEX_DIR checkout FEX-2609.1 && git submodule update --init --recursive $FEX_DIR" >&2
    echo "(already a submodule: cd \"$SRC\" && git submodule update --init --recursive $FEX_DIR)" >&2
    exit 1
fi

emulation_help() {
    echo "How to enable it:" >&2
    if [ "$(uname -s)" = Darwin ]; then
        echo "  Docker Desktop: Settings > General > \"Use Rosetta for x86_64/amd64 emulation on Apple Silicon\"" >&2
        echo "                  (arm64 containers on an Intel Mac: built in, QEMU)" >&2
        echo "  OrbStack:       built in" >&2
        echo "  colima:         colima start --vm-type vz --vz-rosetta   (Apple Silicon, x86_64 target)" >&2
    else
        echo "  Register QEMU for $PLATFORM (lasts until reboot):" >&2
        echo "    docker run --privileged --rm tonistiigi/binfmt --install $DOCKER_PLATFORM_ARCH" >&2
        echo "  or install your distribution's qemu-user-static package (binfmt support included)." >&2
    fi
}

echo "==> Target: $ARCH ($PLATFORM); Docker runs on $DOCKER_ARCH"
if [ "$ARCH" != "$DOCKER_ARCH" ]; then
    echo "==> Emulated build (Rosetta or QEMU): slower than a native $ARCH build. Checking that $PLATFORM containers run"
    got=$(docker run --rm --platform "$PLATFORM" nixos/nix:latest uname -m 2>&1 | tail -n 1) || true
    if [ "$(norm_arch "$got")" != "$ARCH" ]; then
        echo "ERROR: this Docker can't run $PLATFORM containers (test output: ${got:-nothing})." >&2
        emulation_help
        exit 1
    fi
    if [ "$ARCH" = aarch64 ]; then
        echo "    aarch64 under QEMU is many times slower than native; the appimage step's Turnip and PySide6 compiles can take hours." >&2
    fi
fi

mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
ncpu=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
case $mem in ''|*[!0-9]*) mem=0 ;; esac
case $ncpu in ''|*[!0-9]*) ncpu=0 ;; esac
mem_mib=$((mem / 1048576))
# Heavy C++ files (shadPS4 core, GCC 16, -g) take up to ~2 GB each; ninja's default
# (cores + 2 jobs) runs a 10-core Mac out of memory.
if [ -z "${JOBS:-}" ]; then
    JOBS=$((mem_mib / 2048))
    if [ "$ncpu" -gt 0 ] && [ "$JOBS" -gt "$ncpu" ]; then JOBS=$ncpu; fi
    if [ "$JOBS" -lt 1 ]; then JOBS=1; fi
fi
case $JOBS in ''|*[!0-9]*|0) die "JOBS must be a positive number" ;; esac
echo "==> Source tree: $SRC (build directory: $OUT_DESC/)"
if [ "$NIX_VOLUME" != "$OWN_VOLUME" ]; then
    echo "==> Nix store: shared volume $NIX_VOLUME"
fi
# A Mesa tree for Turnip (aarch64 appimage step): mounted read-only at /turnip-src in the container.
turnip_flags=()
if [ -n "$TURNIP_SRC_IN" ]; then
    if [ "$ARCH" != aarch64 ]; then
        echo "WARNING: ISS_TURNIP_SRC is for aarch64 builds only (Turnip is the Adreno driver); ignored for $ARCH." >&2
    else
        TURNIP_SRC=$(cd -- "$TURNIP_SRC_IN" 2>/dev/null && pwd) || die "Turnip source directory not found: $TURNIP_SRC_IN"
        [ -f "$TURNIP_SRC/VERSION" ] && [ -d "$TURNIP_SRC/src/freedreno/vulkan" ] ||
            die "not a Mesa source tree (no VERSION or src/freedreno/vulkan): $TURNIP_SRC"
        turnip_flags=(-v "$TURNIP_SRC":/turnip-src:ro -e ISS_TURNIP_SRC=/turnip-src -e ISS_TURNIP_PATCHES="$TURNIP_PATCHES")
        echo "==> Turnip: Mesa $(cat "$TURNIP_SRC/VERSION") from $TURNIP_SRC" \
             "(port's patches: $([ "$TURNIP_PATCHES" = 0 ] && echo off || echo where they apply))"
        [ "$MODE" = appimage ] || echo "    (used by the appimage step only)"
    fi
fi
echo "==> Docker VM: ${ncpu} CPUs, ${mem_mib} MiB RAM; compiling with JOBS=${JOBS}"
if [ "$mem_mib" -lt 7500 ]; then
    echo "WARNING: little RAM for this build. Give Docker 8 GB or more" \
         "(Docker Desktop: Settings > Resources > Memory), or expect a slow build." >&2
fi

# Linux host, rootful Docker Engine: the build's files belong to root on the host; the container
# gives them back to this user at the end (ISS_OWNER). sudo ./build_docker.sh: to the sudo user.
OWNER=""
if [ "$(uname -s)" = Linux ]; then
    case "$(docker --version 2>/dev/null) $(docker info --format '{{.OperatingSystem}} {{.SecurityOptions}}' 2>/dev/null)" in
        # Podman, rootless Docker, Docker Desktop for Linux: they map the container's root to this
        # user already (a chown in the container would give the files to a subordinate ID).
        *odman*|*rootless*|*"Docker Desktop"*) ;;
        *) OWNER="${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" ;;
    esac
fi

# Mount points that exist before Docker needs them (Docker Engine would create missing ones as
# root). x86_64: its own out/ and pgo/ go over the tree's.
mkdir -p "$SRC/port/out" "$SRC/port/pgo"
build_mounts=()
if [ -n "$BUILD_DIR" ]; then
    mkdir -p "$SRC/port/$BUILD_DIR/out" "$SRC/port/$BUILD_DIR/pgo"
    build_mounts=(-v "$SRC/port/$BUILD_DIR/out":/src/port/out -v "$SRC/port/$BUILD_DIR/pgo":/src/port/pgo)
fi

# Image: the official Nix image plus a pinned nixpkgs tree (NIX_PATH), so shell.nix's
# `import <nixpkgs>` always resolves to the same package set. git is there for build.sh's own
# `git rev-parse` and `git apply` of the FSR-Vulkan patches; safe.directory lets it work on the
# mounted tree.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$IMAGE" 2>/dev/null || true)
if [ "$image_arch" != "$DOCKER_PLATFORM_ARCH" ]; then
    if [ -n "$image_arch" ]; then echo "==> $IMAGE is a $image_arch image: building it again for $DOCKER_PLATFORM_ARCH"; fi
    echo "==> Building image $IMAGE ($PLATFORM)"
    docker build --platform "$PLATFORM" -t "$IMAGE" --build-arg NIXPKGS_REV="$NIXPKGS_REV" - <<'DOCKERFILE'
FROM nixos/nix:latest
ARG NIXPKGS_REV
RUN mkdir -p /opt/nixpkgs \
 && curl -fsSL "https://github.com/NixOS/nixpkgs/archive/${NIXPKGS_REV}.tar.gz" \
    | tar -xz --strip-components=1 -C /opt/nixpkgs \
 && (command -v git >/dev/null \
     || nix-env --option sandbox false --option filter-syscalls false --option build-users-group '' \
            -f /opt/nixpkgs -iA git) \
 && git config --global --add safe.directory '*'
ENV NIX_PATH=nixpkgs=/opt/nixpkgs
WORKDIR /src
DOCKERFILE
fi

# Runs inside the container, in /src/port (the mounted tree's port/). $1 = mode.
# Only the Nix image's own tools here (bash, coreutils, findutils, grep, curl, tar, git): no sed
# outside nix-shell.
read -r -d '' INNER <<'INNER_SCRIPT' || true
set -euo pipefail
mode=$1; shift
cd /src/port
# Linux host with Docker Engine: root-owned files in what the build writes go back to the host
# user, also when the build fails. Ownership only.
if [ -n "${ISS_OWNER:-}" ]; then
    give_back() {
        local p
        for p in out pgo dist packaging/runtime-paths.nix gpu/third_party/fsr-vulkan \
                 ../.git/modules/port/gpu/third_party/fsr-vulkan; do
            if [ -e "$p" ] || [ -L "$p" ]; then
                find "$p" -user 0 -exec chown -h "$ISS_OWNER" {} + 2>/dev/null || true
            fi
        done
    }
    trap give_back EXIT
fi
# For every nix command here: flakes for `nix bundle` (AppImage), no build sandbox inside Docker,
# no separate build users (root in a throwaway container: builds do not depend on the image's
# nixbld group, which a rebuilt or pruned image may lack), no seccomp filter (unsupported under
# Rosetta and QEMU), and derivations built from source limited to $ISS_JOBS cores, like the compiler.
# Without the sandbox every build runs with HOME=/homeless-shelter on the container's real file
# system, and Nix refuses to start a build while that directory exists ("home directory
# /homeless-shelter exists; please remove it"). Anything that writes to that home creates it and
# stops every build after it. Three guards:
# - HOME is /root and XDG_CACHE_HOME a folder on the Nix store volume for every command here,
#   nix-shell commands included (Nix itself keeps caches in $XDG_CACHE_HOME/nix, else ~/.cache/nix:
#   run with HOME=/homeless-shelter, it creates the directory);
# - a post-build hook removes it after each build (max-jobs = 1: builds run one at a time, and Nix
#   waits for the hook before it starts the next one);
# - each step here removes it before it starts and after it ends, and names what was in it.
# The cache on the volume: Nix keeps the flake inputs it downloaded there (the AppImage bundler and
# its own nixpkgs, ~40 MB from GitHub), and in the container's /root every appimage run downloaded
# them again (and one cut short stopped the run: "Truncated tar archive").
export HOME=/root XDG_CACHE_HOME=/nix/var/cache/build-docker
mkdir -p /tmp/nixhooks "$XDG_CACHE_HOME"
printf '#!/bin/sh\nrm -rf /homeless-shelter\n' > /tmp/nixhooks/post-build
chmod +x /tmp/nixhooks/post-build
clear_homeless() { # $1: what left it (for the message)
    if [ -e /homeless-shelter ]; then
        echo "==> Removing /homeless-shelter left by $1 (contents: $(ls -A /homeless-shelter /homeless-shelter/.cache 2>/dev/null | tr '\n' ' '))"
        rm -rf /homeless-shelter
    fi
}
clear_homeless "the image"
# in_shell LABEL COMMAND: COMMAND in the build environment (shell.nix), with the home above.
in_shell() {
    local status=0
    clear_homeless "an earlier step"
    nix-shell shell.nix --run "export HOME=/root XDG_CACHE_HOME=$XDG_CACHE_HOME; $2" || status=$?
    clear_homeless "$1"
    return "$status"
}
export NIX_CONFIG="experimental-features = nix-command flakes
sandbox = false
build-users-group =
filter-syscalls = false
max-jobs = 1
cores = ${ISS_JOBS:-2}
post-build-hook = /tmp/nixhooks/post-build"
# Optional GitHub token (any classic token, no scopes): 5000 API requests/hour instead of 60.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    NIX_CONFIG="$NIX_CONFIG
access-tokens = github.com=${GITHUB_TOKEN}"
fi
echo "==> Container: $(uname -m)"
if [ "$ISS_ARCH" = aarch64 ]; then
    echo "==> Kernel page size: $(grep -m1 KernelPageSize /proc/self/smaps | tr -s ' ' | cut -d' ' -f2-) (FEXCore assumes 4 kB)"
fi
if [ "$mode" = shell ]; then
    # exec would skip the EXIT trap: run the shell, then give the files back.
    nix-shell shell.nix --command "export HOME=/root XDG_CACHE_HOME=$XDG_CACHE_HOME; return"
    exit $?
fi
# build.sh calls plain `ninja` (cores + 2 jobs). This wrapper, first in PATH, adds -j $ISS_JOBS.
mkdir -p /tmp/isswrap
cat > /tmp/isswrap/ninja <<'WRAPPER'
#!/bin/sh
real=$(PATH=${PATH#/tmp/isswrap:}; export PATH; command -v ninja)
exec "$real" -j "${ISS_JOBS:-2}" "$@"
WRAPPER
chmod +x /tmp/isswrap/ninja
if [ "$ISS_ARCH" = aarch64 ]; then
    # FEX turns LTO on by default, which needs llvm-ar and LLVM's linker plugin; shell.nix's clang
    # has neither ("CMAKE_C_COMPILER_AR-NOTFOUND: command not found"). build.sh configures FEX only
    # when out/fex/build.ninja is missing, and CMake keeps existing cache entries, so a pre-seeded
    # ENABLE_LTO=OFF turns it off without touching build.sh.
    if [ -f out/fex/CMakeCache.txt ] && ! grep -q '^ENABLE_LTO:BOOL=OFF$' out/fex/CMakeCache.txt; then
        echo "==> FEX was configured with LTO: starting its build directory (out/fex) over without it"
        rm -rf out/fex
    fi
    if [ ! -f out/fex/CMakeCache.txt ]; then
        mkdir -p out/fex && echo 'ENABLE_LTO:BOOL=OFF' > out/fex/CMakeCache.txt
    fi
fi
echo "==> Building for ${ISS_ARCH} (TLG_LTO=${TLG_LTO}, TLG_PGO=${TLG_PGO:-build.sh default}, ${ISS_JOBS} parallel jobs); logs: port/out/gpu-build.log$([ "$ISS_ARCH" = aarch64 ] && echo ', port/out/fex-build.log')"
in_shell "the build" 'PATH=/tmp/isswrap:$PATH bash build.sh'
echo "==> Built:"
in_shell "the build summary" \
    'for f in out/tlg-probe out/tlg-gpu-capabilities out/gpu/libtlggpu.so out/fex/*.so; do [ -f "$f" ] && printf "  %-28s %s\n" "$f" "$(readelf -h "$f" | sed -n "s/ *Machine: *//p")"; done; true'
if [ "$mode" = test ]; then
    # No GPU, display or gamepad in the container, and maybe emulation: some tests may fail.
    echo "==> Running the project's tests (build.sh --test)"
    in_shell "the tests" 'PATH=/tmp/isswrap:$PATH bash build.sh --test' || { echo "==> Some tests failed (see above)"; exit 3; }
    echo "==> Tests passed"
fi
if [ "$mode" = appimage ]; then
    # appimage.sh names the bundler without a commit (github:ralismark/nix-appimage), so Nix asks
    # GitHub's API for its latest commit: 60 anonymous requests per hour per IP, often used up on
    # shared IPs. A copy of the script with the bundler pinned to a commit skips that API call
    # (pinned inputs download as plain archives). The copy lives in /tmp, not in the tree; it runs
    # from packaging/ as "appimage.sh" so its `cd "$(dirname "$0")/.."` still lands in /src/port.
    bundler_rev=7946addbc0d97e358a6d7aefe5e82310f0fe6b18   # ralismark/nix-appimage, 2025-09-15
    original=$(cat packaging/appimage.sh)
    pinned=${original//github:ralismark\/nix-appimage /github:ralismark/nix-appimage/${bundler_rev} }
    printf '%s\n' "$pinned" > /tmp/appimage-pinned.sh
    if [ "$pinned" = "$original" ]; then
        echo "WARNING: appimage.sh changed upstream; running it unpinned" >&2
    fi
    if [ "$ISS_ARCH" = aarch64 ]; then
        echo "==> Packaging the AppImage (nix bundle). The first run builds PySide6 (the launcher's Qt modules only)" \
             "and the patched Turnip (Mesa) driver from source$([ -n "${ISS_TURNIP_SRC:-}" ] && echo ', from the mounted Mesa tree')"
    else
        echo "==> Packaging the AppImage (nix bundle). The first run builds PySide6 (the launcher's Qt modules only) from source"
    fi
    if [ "${ISS_PACKAGE_SELFTEST:-}" = 0 ]; then
        echo "    ISS_PACKAGE_SELFTEST=0: without the launcher's selftest"
    fi
    # A download cut short or refused (GitHub) is not the package's fault: up to three tries.
    for attempt in 1 2 3; do
        if in_shell "the packaging" 'set -o pipefail; cd packaging && ISS_NIXPKGS=/opt/nixpkgs bash -c "$(cat /tmp/appimage-pinned.sh)" appimage.sh 2>&1 | tee /tmp/appimage.log'; then
            exit 0
        fi
        grep -q -E 'Truncated tar archive|unable to download|Failure when receiving data|Connection reset|Could not resolve host' \
            /tmp/appimage.log || break
        [ "$attempt" -lt 3 ] || break
        echo "==> A download failed (see above): trying again in 10 s (try $((attempt + 1)) of 3)"
        sleep 10
    done
    # The bundler's last step packs the package's closure with `mksquashfs <each store path> ...
    # -no-strip`. Under emulation (an x86_64 build on Apple Silicon: Rosetta or QEMU) mksquashfs
    # 4.6.1 fails there with any two sources ("Can't have two different sources with same
    # pathname"), natively it works. Everything that step needs is built by then, so it is done
    # here instead with the bundler's own commands, its one -no-strip call given the closure as a
    # single staged directory (hard links next to the store: no copies). Then the rest of
    # appimage.sh: the AppImage into dist/, the package's GC root. (As in the Bloodborne port.)
    drv=$(grep -o "/nix/store/[a-z0-9]\{32\}-[^ '\"]*\.AppImage\.drv" /tmp/appimage.log | head -n 1 || true)
    if ! grep -q "two different sources with same pathname" /tmp/appimage.log || [ -z "$drv" ]; then
        exit 1
    fi
    echo "==> mksquashfs can't pack the closure list under emulation; packing the AppImage here from $drv"
    cat > /tmp/assemble-appimage.sh <<'ASSEMBLE'
# $1: the bundler's AppImage derivation, $2: where to write the AppImage.
set -euo pipefail
drv=$1 result=$2
text=$(cat "$drv")
# Its build command: the "buildCommand" string of the derivation's environment, unescaped.
cmd=${text#*\(\"buildCommand\",\"}
cmd=${cmd%%\"\),\(*}
p=$'\x01'
cmd=${cmd//\\\\/$p}; cmd=${cmd//\\n/$'\n'}; cmd=${cmd//\\t/$'\t'}; cmd=${cmd//\\r/$'\r'}
cmd=${cmd//\\\"/\"}; cmd=${cmd//$p/\\}
inputs=${text#*\(\"nativeBuildInputs\",\"}
inputs=${inputs%%\"*}
squashfs=""
for w in $inputs; do if [ -x "$w/bin/mksquashfs" ]; then squashfs=$w; fi; done
[ -n "$squashfs" ] || { echo "ERROR: no mksquashfs among the derivation's inputs ($inputs)" >&2; exit 1; }
case $cmd in *mksquashfs*-no-strip*) ;; *) echo "ERROR: unexpected build command in $drv" >&2; exit 1 ;; esac
export PATH="$squashfs/bin:$PATH"
stage=/nix/.iss-appimage-root   # in the store's file system, so cp -l makes hard links
# mksquashfs SOURCES... DEST OPTIONS...: with -no-strip, the sources become one directory tree.
mksquashfs() {
    case " $* " in *" -no-strip "*) ;; *) command mksquashfs "$@"; return ;; esac
    local args=("$@") i=0 a opts=()
    while [ "$i" -lt "${#args[@]}" ] && [[ ${args[i]} != -* ]]; do i=$((i + 1)); done
    local dest=${args[i - 1]} sources=("${args[@]:0:i-1}")
    for a in "${args[@]:i}"; do [ "$a" = -no-strip ] || opts+=("$a"); done
    rm -rf "$stage"
    for a in "${sources[@]}"; do
        mkdir -p "$stage$(dirname "$a")"
        cp -al "$a" "$stage$a" 2>/dev/null || cp -a "$a" "$stage$a"
    done
    echo "  mksquashfs: ${#sources[@]} store paths as one directory"
    command mksquashfs "$stage" "$dest" "${opts[@]}"
    rm -rf "$stage"
}
work=$(mktemp -d)
trap 'rm -rf "$work" "$stage"' EXIT
cd "$work"
export out=$work/infamous.AppImage
eval "$cmd"
install -m755 "$out" "$result"
ASSEMBLE
    mkdir -p dist
    in_shell "the AppImage assembly" "bash /tmp/assemble-appimage.sh '$drv' /src/port/dist/infamous-linux-$ISS_ARCH.AppImage"
    # appimage.sh's last steps: a GC root for the package (keeps what was built from source).
    in_shell "the GC root" 'nix-build --impure packaging -o out/nix-roots/infamous > /dev/null'
    ls -lh "dist/infamous-linux-$ISS_ARCH.AppImage"
fi
INNER_SCRIPT

tty_flags=()
if [ -t 0 ] && [ -t 1 ]; then tty_flags=(-it); fi

# "${arr[@]+"${arr[@]}"}" keeps bash 3.2 happy with an empty array.
docker run --rm ${tty_flags[@]+"${tty_flags[@]}"} \
    --platform "$PLATFORM" \
    -v "$NIX_VOLUME":/nix -v "$SRC":/src \
    ${build_mounts[@]+"${build_mounts[@]}"} \
    -e ISS_ARCH="$ARCH" -e ISS_OWNER="$OWNER" -e ISS_JOBS="$JOBS" \
    -e TLG_LTO="$ISS_LTO" -e TLG_PGO="${TLG_PGO:-}" \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" -e ISS_PACKAGE_SELFTEST="${ISS_PACKAGE_SELFTEST:-}" \
    -e SDL_VIDEO_DRIVER=dummy -e SDL_AUDIO_DRIVER=dummy \
    ${turnip_flags[@]+"${turnip_flags[@]}"} \
    "$IMAGE" bash -c "$INNER" inner "$MODE"

case $MODE in
    shell) ;;
    appimage) echo "==> Done. $SRC/port/dist/infamous-linux-$ARCH.AppImage (for $ARCH Linux; run it to open the launcher)." ;;
    *) echo "==> Done. Linux $ARCH build in $SRC/$OUT_DESC (runs inside the container, or packaged with: $0 --arch $ARCH appimage)." ;;
esac

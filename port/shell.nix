# Build environment for build.sh on Linux: `nix-shell shell.nix --run 'bash build.sh'` (build.sh
# enters it by itself when its dependencies are missing; ../build_docker.sh runs it in Docker).
# The packaged builds use Ubuntu 24.04 with packaging/linux/build_deps.sh instead (.github/workflows).
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell ({
  packages = with pkgs; [
    gcc gnumake cmake ninja pkg-config python3 binutils
    vulkan-headers vulkan-loader sdl3
    # GPU library (gpu/): shadPS4 video core dependencies
    ffmpeg-headless boost fmt magic-enum robin-map xxhash vulkan-memory-allocator glslang spirv-cross xbyak zydis spirv-headers miniz libx11 libxcb xorgproto wayland
    # FreeType: font rendering in the runtime (runtime_gr2_font.c) and the GPU library (freetype2)
    freetype
  ];
} // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isAarch64 {
  # Guest CPU library (cpu/: FEXCore, aarch64 only) builds with Clang only (build.sh); the rest with GCC.
  FEX_CC = "${pkgs.clang}/bin/clang";
  FEX_CXX = "${pkgs.clang}/bin/clang++";
})

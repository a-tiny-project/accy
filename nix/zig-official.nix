{ pkgs, version }:
let
  lib = pkgs.lib;
  # The official binaries; nix/zig-bootstrap.nix pins the same archives.
  sources = {
    x86_64-linux = {
      platform = "x86_64-linux";
      hash = "sha256-HL6d+fJ+a3jRTMvKQ7ZwOkBO957xxGPekB1/CI1OICY=";
    };
    aarch64-linux = {
      platform = "aarch64-linux";
      hash = "sha256-no0RZh1K471XcCo4MngeI60VHd5XmOFqXM1QP2UjT/g=";
    };
    x86_64-darwin = {
      platform = "x86_64-macos";
      hash = "sha256-T5ocUmmqF+vaXm08K4nWy/NvfSsioDBumrmPJflVKcY=";
    };
    aarch64-darwin = {
      platform = "aarch64-macos";
      hash = "sha256-tgfpuSNHkKAIEWrlvbccYkO4S5+0KlOp5w/eQcBsU2o=";
    };
  };
  system = pkgs.stdenv.hostPlatform.system;
  source = sources.${system} or (throw "unsupported official Zig host system: ${system}");
in
# The official Zig release, unpatched: the compiler a library's consumers
# build it with.
pkgs.stdenvNoCC.mkDerivation {
  pname = "zig";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://ziglang.org/download/${version}/zig-${source.platform}-${version}.tar.xz";
    inherit (source) hash;
  };
  sourceRoot = "zig-${source.platform}-${version}";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/lib/zig" "$out/share/licenses/zig"
    install -Dm755 zig "$out/bin/zig"
    cp -R lib/. "$out/lib/zig/"
    install -Dm644 LICENSE "$out/share/licenses/zig/LICENSE"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    test "$("$out/bin/zig" version)" = "${version}"
    test -f "$out/lib/zig/std/Build.zig"
  '';
  passthru = {
    # The sandbox has no xcrun, and the official compiler then takes its native
    # paths only from these Nix variables, so a Darwin build names the SDK the
    # way zig.nix's wrapper does.
    buildRunnerEnvironment = lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      NIX_CFLAGS_COMPILE = "-isystem ${pkgs.apple-sdk.sdkroot}/usr/include -iframework ${pkgs.apple-sdk.sdkroot}/System/Library/Frameworks";
      NIX_LDFLAGS = "-L${pkgs.apple-sdk.sdkroot}/usr/lib";
    };
    # Static musl on Linux, since the sandbox runs no executable that names a
    # dynamic linker this compiler can set; see nix/product.nix.
    hostTarget =
      {
        x86_64-linux = "x86_64-linux-musl";
        aarch64-linux = "aarch64-linux-musl";
        x86_64-darwin = "x86_64-macos";
        aarch64-darwin = "aarch64-macos";
      }
      .${system};
  };
  meta = {
    description = "The official Zig release";
    homepage = "https://ziglang.org";
    license = lib.licenses.mit;
    mainProgram = "zig";
  };
}

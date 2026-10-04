{ pkgs, version }:
let
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
  source = sources.${system} or (throw "unsupported Zig bootstrap host system: ${system}");
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "zig-bootstrap";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://ziglang.org/download/${version}/zig-${source.platform}-${version}.tar.xz";
    inherit (source) hash;
  };
  sourceRoot = "zig-${source.platform}-${version}";
  patches = [ ./zig-target-options.patch ];
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
}

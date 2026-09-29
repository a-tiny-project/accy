{ pkgs, version }:
let
  sources = {
    x86_64-linux = {
      platform = "x86_64-linux";
      hash = "sha256-Khlt1D7FHmS23j7Q5fnyF6rIitGH465ds/4Df+3e8Rg=";
    };
    aarch64-linux = {
      platform = "aarch64-linux";
      hash = "sha256-JIcV5Tzcb8CrIAg3QnSPfiYpN5ifmh8nonnCpfm1KaA=";
    };
    x86_64-darwin = {
      platform = "x86_64-macos";
      hash = "sha256-Hdc6N0yagseVvVfGTHo/MzdbGAGpJW17hLNKV5I2Iko=";
    };
    aarch64-darwin = {
      platform = "aarch64-macos";
      hash = "sha256-IVxxRW4MyJlODFZDjZOkpRLTeAqeajpIqJF9t/TP6tk=";
    };
  };
  system = pkgs.stdenv.hostPlatform.system;
  source = sources.${system} or (throw "unsupported Zig bootstrap host system: ${system}");
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "zig-bootstrap";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://github.com/cataggar/zig/releases/download/v${version}/zig-${source.platform}-${version}.tar.xz";
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

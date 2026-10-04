{
  pkgs,
  version,
  consumer ? false,
}:
let
  lib = pkgs.lib;
  # Build metadata follows "+" in a semantic version. A development version
  # carries a prefix of its source commit there, and a release carries none.
  versionMetadata = builtins.match "[^+]*\\+(.*)" version;
  # The consumer compiler appends one build metadata identifier.
  compilerVersion =
    if !consumer then
      version
    else if versionMetadata == null then
      "${version}+tiny-consumer"
    else
      "${version}.tiny-consumer";
  sourceCommit = "7647adab80dd088f4de3610fd245915a912eb6ad";
  buildRunnerEnvironment = {
    ZIG_DEBUG_CMD = "1";
  };
  # Zig detects native SDK paths only for a native target query, so an explicit
  # same-Darwin target such as aarch64-macos would miss them.
  darwinNativePathsBefore = lib.concatStringsSep "\n" [
    "        // Trigger native system library path detection if necessary."
    "        if (create_module.sysroot == null and"
    "            resolved_target.is_native_os and resolved_target.is_native_abi and"
    "            create_module.want_native_include_dirs)"
    "        {"
  ];
  darwinNativePathsAfter = lib.removeSuffix "\n" (
    builtins.readFile ./zig-darwin-native-paths-after.txt
  );
  zigPatchSeries = lib.filter (line: line != "") (
    lib.splitString "\n" (builtins.readFile ./zig-patches.list)
  );
  zigPatchPaths = map (line: ../. + ("/" + line)) zigPatchSeries;
  consumerPatchSeries = lib.filter (line: line != "") (
    lib.splitString "\n" (builtins.readFile ./zig-consumer-patches.list)
  );
  consumerPatchPaths = map (line: ../. + ("/" + line)) consumerPatchSeries;
  forkIdentity = builtins.hashString "sha256" (
    lib.concatStrings (map builtins.readFile zigPatchPaths)
    + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ("\n" + darwinNativePathsAfter)
  );
  hostTarget =
    {
      x86_64-linux = "x86_64-linux-gnu.${lib.versions.majorMinor pkgs.glibc.version}";
      aarch64-linux = "aarch64-linux-gnu.${lib.versions.majorMinor pkgs.glibc.version}";
      x86_64-darwin = "x86_64-macos";
      aarch64-darwin = "aarch64-macos";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "unsupported Zig source-build host system: ${pkgs.stdenv.hostPlatform.system}");
  buildBudget = builtins.fromTOML (builtins.readFile ../build/api/src/capacity.workloads);
  darwinMemoryBytes = buildBudget.toolchain_memory_claim_mib * 1024 * 1024;
  darwinGuard =
    phase:
    lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "${pkgs.python3}/bin/python3 ${./zig-darwin-memory.py} ${toString darwinMemoryBytes} ${phase} ";
  makerCheckTargetArgument =
    " -Dtarget=${hostTarget}"
    + lib.optionalString pkgs.stdenv.hostPlatform.isLinux " -Ddynamic-linker=${pkgs.stdenv.cc.bintools.dynamicLinker}";
  bootstrapSource = import ./zig-bootstrap.nix {
    inherit pkgs version;
  };
  bootstrap =
    if pkgs.stdenv.hostPlatform.isDarwin then
      bootstrapSource.overrideAttrs (_previous: {
        installCheckPhase = ''
          runHook preInstallCheck
          ${pkgs.python3}/bin/python3 ${./zig-darwin-memory.py} --self-test
          test "$(${darwinGuard "bootstrap-version"}"$out/bin/zig" version)" = "${version}"
          test -f "$out/lib/zig/std/Build.zig"
          runHook postInstallCheck
        '';
      })
    else
      bootstrapSource;
  makerCheck = pkgs.linkFarm "zig-maker-check" [
    {
      name = "build.zig";
      path = pkgs.writeText "zig-maker-check-build.zig" (
        ''
          const std = @import("std");

          pub fn build(b: *std.Build) void {
              const executable = b.addExecutable(.{
                  .name = "zig-maker-check",
                  .root_module = b.createModule(.{
                      .root_source_file = b.path("main.zig"),
                      .target = ${
                        if pkgs.stdenv.hostPlatform.isDarwin then "b.standardTargetOptions(.{})" else "b.graph.host"
                      },
                      .optimize = .debug,
                  }),
              });
              b.installArtifact(executable);
        ''
        + lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          const foreign = b.addExecutable(.{
              .name = "zig-maker-libc-check",
              .root_module = b.createModule(.{
                  .target = b.standardTargetOptions(.{}),
                  .optimize = .debug,
                  .link_libc = true,
              }),
              .use_llvm = true,
          });
          foreign.root_module.addCSourceFile(.{
              .file = b.path("main.c"),
              .flags = &.{"-std=c11"},
          });
          b.getInstallStep().dependOn(&b.addRunArtifact(foreign).step);
        ''
        + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
          executable.root_module.linkFramework("AudioToolbox", .{});
          executable.root_module.linkFramework("CoreAudio", .{});
          executable.root_module.linkFramework("GameController", .{});
          executable.root_module.linkFramework("Foundation", .{});
          const environment = b.addSystemCommand(&.{
              "node",
              "-e",
              "const fs=require('fs');" ++
                  "const c=process.env.NIX_CFLAGS_COMPILE||String();" ++
                  "const l=process.env.NIX_LDFLAGS||String();" ++
                  "const p=(process.env.PATH||String()).split(':')[0];" ++
                  "if(process.env.SDKROOT!=='${pkgs.apple-sdk.sdkroot}'||" ++
                  "!c.startsWith('-isystem ${pkgs.apple-sdk.sdkroot}/usr/include " ++
                  "-iframework ${pkgs.apple-sdk.sdkroot}/System/Library/Frameworks')||" ++
                  "!l.startsWith('-L${pkgs.apple-sdk.sdkroot}/usr/lib')||" ++
                  "p!=='${pkgs.nodejs}/bin'||" ++
                  "fs.realpathSync(process.execPath)!==" ++
                  "fs.realpathSync('${pkgs.nodejs}/bin/node'))process.exit(1);",
          });
          environment.setName("check declared Darwin Zig environment");
          b.getInstallStep().dependOn(&environment.step);
        ''
        + ''
          }
        ''
      );
    }
    {
      name = "main.zig";
      path = pkgs.writeText "zig-maker-check-main.zig" ''
        pub fn main() void {}
      '';
    }
    {
      name = "main.c";
      path = pkgs.writeText "zig-maker-check-main.c" ''
        int main(void) { return 0; }
      '';
    }
  ];
  makerRssCheck = pkgs.writeTextDir "build.zig" ''
    const std = @import("std");

    // Steps share one lock directory, so overlapping steps fail. Steps that
    // each claim the whole --maxrss budget must run one at a time.
    pub fn build(b: *std.Build) void {
        const lock = b.option([]const u8, "lock", "Directory a running step holds").?;
        const claim = b.option(usize, "claim", "Memory claim of every step").?;
        const steps = b.step("steps", "Run four steps that share one lock");
        for (0..4) |index| {
            const run = b.addSystemCommand(&.{
                "sh",
                "-c",
                "mkdir \"$1\" || exit 3; sleep 1; rmdir \"$1\"",
                b.fmt("step-{d}", .{index}),
                lock,
            });
            run.has_side_effects = true;
            run.expectExitCode(0);
            run.step.max_rss = claim;
            steps.dependOn(&run.step);
        }
    }
  '';
  llvm = pkgs.llvmPackages_22;
  zstdStatic = pkgs.zstd.override {
    enableStatic = true;
  };
  llvmPrefix = pkgs.symlinkJoin {
    name = "zig-llvm-22-prefix";
    paths = [
      (lib.getDev llvm.llvm)
      (lib.getLib llvm.llvm)
      (lib.getDev llvm.libclang)
      (lib.getLib llvm.libclang)
      (lib.getDev llvm.lld)
      (lib.getLib llvm.lld)
      (lib.getDev pkgs.libxml2)
      (lib.getLib pkgs.libxml2)
      (lib.getDev pkgs.zlib)
      (lib.getLib pkgs.zlib)
      pkgs.zlib.static
      (lib.getDev zstdStatic)
      (lib.getLib zstdStatic)
    ];
  };
in
assert lib.assertMsg (
  if versionMetadata == null then
    builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" version != null
  else
    lib.hasPrefix (builtins.head versionMetadata) sourceCommit
) "Zig version ${version} must be a release or carry a prefix of source commit ${sourceCommit}";
assert lib.assertMsg (zigPatchSeries != [ ]) "nix/zig-patches.list must name at least one patch";
assert lib.assertMsg (
  consumerPatchSeries != [ ]
) "nix/zig-consumer-patches.list must name at least one patch";
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = if consumer then "zig-consumer" else "zig";
  version = compilerVersion;
  inherit (buildRunnerEnvironment) ZIG_DEBUG_CMD;

  src = pkgs.fetchgit {
    url = "https://codeberg.org/ziglang/zig.git";
    rev = sourceCommit;
    hash = "sha256-dXy3DrGQHDpXCnr+Wi/1tPEktPm9bBDJQiQ/0VyiMaM=";
  };

  patches = if consumer then consumerPatchPaths else zigPatchPaths;

  nativeBuildInputs = [
    bootstrap
    pkgs.cmake
    pkgs.ninja
    llvm.llvm.dev
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.patchelf ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.makeWrapper
    pkgs.xcbuild
  ];

  buildInputs = [
    pkgs.libxml2
    pkgs.zlib
    pkgs.zlib.static
    zstdStatic
    llvm.libclang
    llvm.lld
    llvm.llvm
  ];

  strictDeps = true;
  dontConfigure = true;
  dontStrip = true;

  __impureHostDeps = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    "/System/Library/CoreServices/.SystemVersionPlatform.plist"
  ];

  postPatch = ''
    substituteInPlace lib/std/zig/system.zig \
      --replace-fail "/usr/bin/env" "${lib.getExe' pkgs.coreutils "env"}"
  ''
  + lib.optionalString (!consumer) ''
    for identity_file in src/stardust_api.zig lib/compiler/Maker.zig; do
      substituteInPlace "$identity_file" \
        --replace-fail \
          '"tiny.zig.source.identity"' \
          '"${sourceCommit}"' \
        --replace-fail \
          '"tiny.zig.fork.identity"' \
          '"${forkIdentity}"'
    done
  ''
  + lib.optionalString (pkgs.stdenv.hostPlatform.isDarwin && !consumer) ''
    substituteInPlace src/main.zig \
      --replace-fail \
        ${lib.escapeShellArg darwinNativePathsBefore} \
        ${lib.escapeShellArg darwinNativePathsAfter}
  '';

  buildPhase = ''
    runHook preBuild

    ${darwinGuard "configure"}cmake -S . -B cmake-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=${llvmPrefix} \
      -DZIG_STATIC_LLVM=ON \
      -DZIG_STATIC_ZLIB=ON \
      -DZIG_STATIC_ZSTD=ON \
      -DZIG_TARGET_MCPU=baseline \
      -DZIG_VERSION=${version}
    ${darwinGuard "compiler-support"}cmake --build cmake-build --target zigcpp -j "$NIX_BUILD_CORES"

    export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    ${darwinGuard "bootstrap"}${bootstrap}/bin/zig build -j"$NIX_BUILD_CORES" \
      --release=fast \
      -Dtarget=${hostTarget} \
      -Dcpu=baseline \
      -Dstrip=true \
      -Dno-langref=true \
      -Denable-llvm=true \
      -Dconfig_h="$PWD/cmake-build/config.h" \
      -Dversion-string=${compilerVersion} \
      -p "$PWD/stage3"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R stage3/. "$out/"
    install -Dm644 LICENSE "$out/share/licenses/zig/LICENSE"

    runHook postInstall
  '';

  postFixup =
    lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      patchelf --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} \
        "$out/bin/zig"
      patchelf --set-rpath ${lib.getLib pkgs.libxml2}/lib \
        "$out/bin/zig"
    ''
    + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      wrapProgram "$out/bin/zig" \
        --set SDKROOT "${pkgs.apple-sdk.sdkroot}" \
        --prefix NIX_CFLAGS_COMPILE ' ' \
          "-isystem ${pkgs.apple-sdk.sdkroot}/usr/include -iframework ${pkgs.apple-sdk.sdkroot}/System/Library/Frameworks" \
        --prefix NIX_LDFLAGS ' ' \
          "-L${pkgs.apple-sdk.sdkroot}/usr/lib" \
        --prefix PATH : "${lib.makeBinPath [ pkgs.nodejs ]}"
    '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test "$(${darwinGuard "version"}"$out/bin/zig" version)" = "${compilerVersion}"
    test -f "$out/lib/zig/std/Build.zig"
  ''
  + lib.optionalString (!consumer) ''
    test -f "$out/lib/zig/compiler-api/src/compiler_api.zig"
    test -f "$out/lib/zig/compiler-api/build_options.zig"
    grep -Fqx \
      'pub const source_identity = "${sourceCommit}";' \
      "$out/lib/zig/compiler-api/src/stardust_api.zig"
    grep -Fqx \
      'pub const fork_identity = "${forkIdentity}";' \
      "$out/lib/zig/compiler-api/src/stardust_api.zig"
    grep -Fqx \
      'const compiler_source_identity = "${sourceCommit}";' \
      "$out/lib/zig/compiler/Maker.zig"
    grep -Fqx \
      'const compiler_fork_identity = "${forkIdentity}";' \
      "$out/lib/zig/compiler/Maker.zig"
    grep -Fqx \
      '    graph.cache.hash.addBytes(compiler_source_identity);' \
      "$out/lib/zig/compiler/Maker.zig"
    grep -Fqx \
      '    graph.cache.hash.addBytes(compiler_fork_identity);' \
      "$out/lib/zig/compiler/Maker.zig"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/maker-check-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/maker-check-global-cache"
    ${darwinGuard "maker-check"}"$out/bin/zig" build \
      --build-file "${makerCheck}/build.zig" \
      --prefix "$TMPDIR/maker-check-prefix"${makerCheckTargetArgument} \
      --summary all
    test -x "$TMPDIR/maker-check-prefix/bin/zig-maker-check"
    ${darwinGuard "generation-check"}"$out/bin/zig" test "$out/lib/zig/compiler/Maker/Generation.zig" ${
      if pkgs.stdenv.hostPlatform.isx86_64 then "-fno-llvm" else "-fllvm"
    }
    ${darwinGuard "generation-events"}${pkgs.python3}/bin/python3 ${./zig-generation-events-test.py} \
      "$out/bin/zig" "$TMPDIR/generation-events-check"
    # The unclaimed control must fail because its steps overlap. The claimed
    # build must pass. Without Maker's RSS accounting, its steps overlap too.
    if ${darwinGuard "maker-rss-control"}"$out/bin/zig" build \
      --build-file "${makerRssCheck}/build.zig" \
      --prefix "$TMPDIR/maker-rss-prefix" steps --maxrss 67108864 -j4 \
      -Dlock="$TMPDIR/maker-rss-control-lock" -Dclaim=0 \
      >"$TMPDIR/maker-rss-control.log" 2>&1; then
      echo "unclaimed steps never overlapped, so this check cannot observe Maker's memory gate" >&2
      exit 1
    fi
    ${darwinGuard "maker-rss-claims"}"$out/bin/zig" build \
      --build-file "${makerRssCheck}/build.zig" \
      --prefix "$TMPDIR/maker-rss-prefix" steps --maxrss 67108864 -j4 \
      -Dlock="$TMPDIR/maker-rss-claims-lock" -Dclaim=67108864
  ''
  + ''
    runHook postInstallCheck
  '';

  passthru = {
    inherit
      bootstrap
      buildRunnerEnvironment
      consumerPatchPaths
      consumerPatchSeries
      forkIdentity
      hostTarget
      sourceCommit
      zigPatchPaths
      zigPatchSeries
      ;
    fetchDeps = pkgs.callPackage "${pkgs.path}/pkgs/development/compilers/zig/fetcher.nix" {
      zig = finalAttrs.finalPackage;
    };
  };

  meta = {
    description =
      if consumer then
        "Zig at Tiny's upstream pin with the consumer patch list"
      else
        "Zig compiler with Tiny's Stardust AIR observer";
    homepage = "https://codeberg.org/ziglang/zig";
    license = lib.licenses.mit;
    mainProgram = "zig";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
})

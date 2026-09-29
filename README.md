<p align="center">
  <img src="logo.svg" alt="Accy" width="360" />
</p>

# Accy v26.9.0

Accy is a compiler, written in Zig, for programs over multidimensional arrays
(_tensors_). It compiles one program for the host CPU and for GPUs, and it
catches shape errors before any device runs. A program is an ordinary Zig
function, which Accy calls once on traced values to record the array operations
it performs. Each axis of an array carries a name and a length, so operands line
up by name rather than by position, and a missing name or an unequal length
fails during that recording. Accy then lowers the recorded program through
Choir, an MLIR-style compiler library, into functions that a device runs across
many threads at once (_kernels_): x86-64 machine code for the host CPU, PTX for
NVIDIA GPUs, SPIR-V for Vulkan, MSL for Metal and WGSL for WebGPU. Matrix
products, factorizations, sorts and other families come from a library of
hand-written kernels, and Accy picks each one's schedule from tables measured
per device and problem size.

## Install

The source archive is private to members of the organization, who can download
it with `gh`:

```sh
gh release download v26.9.0 --repo a-tiny-project/accy --pattern 'accy-v26.9.0.tar.gz'
tar -xzf accy-v26.9.0.tar.gz
```

Accy builds with a development release of Zig, `0.17.0-dev.1465+8b2d0ce21`, plus
two patches listed in
[nix/zig-consumer-patches.list](nix/zig-consumer-patches.list). One forwards the
target's object format and dynamic linker to the build scripts of dependencies.
The other keeps the LLVM backend from giving under-aligned structs and unions a
larger alignment than Zig declares for them. The extracted directory is a Nix
flake, and its default development shell supplies this compiler on Linux and
macOS. A project that depends on Accy enters that shell and fetches the archive:

```sh
nix develop /path/to/accy-v26.9.0
zig fetch --save=accy /path/to/accy-v26.9.0.tar.gz
```

## Use

The project's `build.zig` then imports the `accy` module:

```zig
const accy = b.dependency("accy", .{ .target = target, .optimize = optimize });
const root = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "accy", .module = accy.module("accy") }},
});
```

A program is a Zig function over traced values. `define` records it once for
inputs of the given types. Here each input is four `f32` values along one axis
named `lane`, and the program computes `2x + y`. `runCpu` compiles the recorded
program for the host CPU and runs it on the caller's memory:

```zig
const std = @import("std");
const accy = @import("accy");

fn scaleShift(_: *accy.tensor.Builder, args: []const accy.tensor.Value) !accy.tensor.Value {
    const doubled = try args[0].add(args[0]);
    return doubled.add(args[1]);
}

pub fn main() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    const allocator = heap.allocator();

    var program = try accy.tensor.define(allocator, "scale_shift", &.{
        accy.tensor.spec(.f32, .{ .lane = 4 }),
        accy.tensor.spec(.f32, .{ .lane = 4 }),
    }, scaleShift);
    defer program.deinit();

    const x = [_]f32{ 1, 2, 3, 4 };
    const y = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var out: [4]f32 = @splat(0);
    try accy.tensor.runCpu(allocator, &program, &.{
        std.mem.sliceAsBytes(&x),
        std.mem.sliceAsBytes(&y),
    }, &.{std.mem.sliceAsBytes(&out)});
    // out is { 2.5, 4.5, 6.5, 8.5 }
}
```

The CPU backend emits x86-64 code, so `runCpu` runs only on an x86-64 host. On
an Apple silicon Mac, Accy records, checks and lowers programs, and
`accy.target.native_cpu_artifacts_supported` is false. Tests that need a GPU run
only when a build enables them with `-Dgpu-tests`, `-Dvulkan-tests` or
`-Dmetal-tests`. On a Mac, `-Dmetal-tests` compiles Accy's test programs to MSL
and runs them on the GPU.

A long-running process can keep the compiled stages of a program and reuse the
unchanged ones when the program changes
(`accy.tensor.lower.FragmentCompilerCache`). This release does not support that
reuse: the cache returns `error.UnrecordedCompilerBuild`. A one-shot compile
such as `runCpu` keeps no stages and works in any build.

The archive holds the `accy` module and its unit and integration tests. It
leaves out Accy's examples, benchmarks, profiling, browser WebAssembly build and
ahead-of-time kernel registries.

Inside the development shell, `zig build test` at the archive root runs Accy's
unit and integration tests. Tests that need a GPU, an x86-64 host or stage reuse
report as skipped.

## Code

- [Public namespace](src/root.zig)
- [Recorded programs](src/tensor/root.zig)
- [Compile stages](src/preparation/root.zig)
- [Kernel library](src/kernel/root.zig)
- [Device targets](src/target/root.zig)
- [Compiled artifacts](src/artifact/root.zig)
- [Loaded programs](src/executable/root.zig)
- [Device-free reference evaluator](src/eval/root.zig)
- [Device test selection and PTX checks](src/validation/root.zig)
- [Unit and integration tests](src/test.zig)
- [Build and test steps](build.zig)

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).

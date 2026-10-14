# Accy changelog

## v26.10.2

- The README teaches Accy through one program that recovers a tone's frequency
  from sixteen samples. It differentiates a recorded mismatch function with
  `valueAndGrad` and improves eight guesses at once with `vmap` along a named
  `guess` axis. `examples/consumer` holds that program.
- Accy's mark is an archerfish.
- The Choir release this archive carries corrects x86-64 code that computed
  wrong answers:
  - a parallel move that swaps two frame slots, or that moves reals in a cycle
    through frame slots
  - a call whose setup overwrote an argument before reading it
  - a value reloaded before a loop and read inside it
  - a 32-bit memory index, which carried the upper half of its register into the
    address
  - signed and unsigned comparisons of 8-bit and 16-bit integers
  - negation of float vector lanes, which now flips each lane's sign bit
- That Choir release refuses x86-64 programs it compiled wrongly before: a frame
  too large to address, a memref whose byte size overflows, a `func.return`
  inside an `scf.while`, and an `scf.for` over a counter narrower than 32 bits.
  Its emitted code stops at `ud2` at an allocation whose byte count overflows or
  whose `malloc` returns null.
- The GPU library this archive carries, `deps/lib/compiler/gpu`, draws into and
  samples `rgba16_float` textures on Vulkan, Metal and the CPU backend.
- A sampled texture in that library holds a mip chain the caller writes level by
  level, and a sampler takes a mip filter, an anisotropy and a level bias. A
  backend that lacks one of the three refuses it with `CapabilityMismatch`: the
  CPU backend refuses all three, and Metal refuses a level bias.
- A buffer allocated with `BufferAllocation.memory = .upload` is written by the
  host in place on Vulkan.
- A build no longer stops with `CompilerInputSymlinkDepthExceeded` when an
  include directory links to itself, as the one ncurses installs does.
- The Choir source this archive carries compiles larger aarch64 functions: up to
  4,096 operations and 4,096 values, up from 256 values, and a frame of 510
  slots, up from 64. A function past a bound is refused before any code is
  emitted, and the refusal names the bound and what the function asked for.
- The Vulkan runtime no longer reports every program to drivers and layers as an
  application named `tiny`. It opens an unnamed instance by default, and a
  program names itself through `application_name` in `Runtime.InitOptions`,
  passed to `Runtime.initWith` or to the Vulkan backend's
  `State.initDeviceWith`.
- The tldr linker this archive carries no longer reads
  `TINY_BUILD_EFFECTIVE_CPU_COUNT`. Its `tldr-link` command takes a worker count
  as `--threads=N` and otherwise uses every CPU the host reports.
  `parallel.settleBudget` takes that optional count and the host's CPU count and
  cannot fail, and `parallel.parseThreads` reads the flag's value.
- Source-link build helpers take the source URL from explicit configuration or
  GitHub repository variables. Revision-only helpers resolve commits without a
  source URL.
- Build provenance preserves revision and version outputs when no source URL is
  configured. Consumers that read a source link receive the configuration
  diagnostic during compilation.
- The TLDR LLVM collector accepts a quoted Nix command prefix with
  `--nix-command`; standalone collection defaults to `nix`.
- `tldr-link` without `--threads=N` runs no more workers than the process's
  cgroup v2 `cpu.max` quota allows, rounded up to whole CPUs, so a container
  limited to 2 of 16 CPUs links with 2. Choir's parallel calls without a pool
  follow the same limit.

Earlier releases are described at https://github.com/a-tiny-project/accy/releases.

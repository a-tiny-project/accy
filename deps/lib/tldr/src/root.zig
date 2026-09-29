//! The package is an experimental linker: it takes compiled object files and
//! static archives, resolves each reference to a symbol against the object that
//! defines it, applies the relocations each target architecture defines, and
//! writes one executable. On an x86-64 host it can also link objects straight
//! into the calling process's memory and return the entry point as a function
//! to call, and it inspects object files. Linux x86-64 ELF is the default
//! target, and COFF and Mach-O each have their own link path.
//!
//! Linking should keep pace with editing: a link after a small edit should cost
//! little more than the edit. A link's output bytes should depend on its inputs
//! and options alone, so a test can pin a whole executable by its hash. On
//! request, the output should keep one copy of machine code that two or more
//! functions share byte for byte, so the executable is smaller.
//!
//! The design follows a few constraints from existing linkers: full links still
//! need to be fast because symbol resolution can have global effects,
//! incremental linking needs an explicit database of input hashes and
//! output-section layout, and determinism is a correctness property where
//! inputs are processed in command-line order and output sections have stable
//! ordering. Patching an edited section in place needs room after it, since a
//! section that grows past its space would move everything that follows. Two
//! functions that share one copy of code share one address, so distinct
//! functions can have equal pointer values and a program that compares function
//! pointers can see the merge.
//!
//! The package names the modern linkers [mold](https://github.com/rui314/mold)
//! and [LLD](https://lld.llvm.org/) as its predecessors, and from them it takes
//! parallel linking: once a link holds 50,000 or more relocations, it checks
//! them across worker threads. From them it also takes the merging of read-only
//! executable sections whose bytes and relocations match, which both offer
//! under the flag `--icf=all`. Its external benchmark links the same workloads
//! through a ReleaseFast `tldr-link` and through each of wild, mold, lld, gold
//! and GNU ld found on `PATH`.
//!
//! A link in prepare mode writes a record beside its output (an *incremental
//! manifest*), with each input's name, size, content hash and file identity,
//! the output section layout, and where each input section landed. Prepare mode
//! is the default of `LinkOptions`, and `tldr-link` prepares only when given
//! `--incremental=prepare`. A prepared link also leaves slack after each output
//! section (a *reserve*), the larger of the section's alignment and 24 percent
//! of its size by default, so an edited section can grow in place. A later link
//! in relink mode (a *relink*) compares its inputs with that record, then
//! reuses the output, patches the changed sections in place, or falls back to a
//! full link and names the reason, such as an input added, removed or
//! reordered, or a section grown past its slack. Folding identical code
//! (*identical code folding*, or ICF for short, the name LLD and mold use) runs
//! only on request, with `--icf=all`, because of that shared address. Patching
//! the incremental metadata inside an output exists for ELF, and COFF and
//! Mach-O links skip that step.
//!
//! - *contribution*: one input section or common symbol placed in the output,
//!   with its address, file offset, size and reserved size.

pub const model = @import("model.zig");
pub const object = @import("object.zig");
pub const archive = @import("archive.zig");
pub const library = @import("library.zig");
pub const incremental = @import("incremental/root.zig");
pub const trace = @import("trace.zig");
pub const parallel = @import("parallel.zig");
pub const formats = @import("formats/root.zig");
const linker = @import("link.zig");
const loader = @import("load.zig");

pub const Input = model.Input;
pub const InputIdentity = model.InputIdentity;
pub const LinkCommitObserver = model.LinkCommitObserver;
pub const LinkOptions = model.LinkOptions;
pub const Target = model.Target;
pub const Diagnostics = model.Diagnostics;
pub const Error = model.Error;
pub const LinkedImage = object.LinkedImage;
pub const LoadError = loader.LoadError;
pub const LoadedImage = loader.LoadedImage;
pub const Object = object.Object;
pub const ObjectSection = object.ObjectSection;
pub const ObjectSymbol = object.ObjectSymbol;
pub const parseObject = formats.parseObject;
pub const detectObjectFormat = formats.detectObjectFormat;
pub const link = linker.link;
pub const loadExecutable = loader.loadExecutable;
pub const applyIncrementalMetadataPatch = linker.applyIncrementalMetadataPatch;
pub const finishDirectIncrementalMetadataPatch = linker.finishDirectIncrementalMetadataPatch;
pub const directIncrementalEvidenceAlloc = linker.directIncrementalEvidenceAlloc;
pub const incrementalBuildIdNoteRange = linker.incrementalBuildIdNoteRange;
pub const incrementalMetadataPatchRange = linker.incrementalMetadataPatchRange;
pub const MetadataPatchRange = linker.MetadataPatchRange;

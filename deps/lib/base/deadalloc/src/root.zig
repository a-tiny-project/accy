//! The heap places each allocation at a block drawn at random from its size
//! class, a *randomized heap*, over an allocator the caller supplies. The heap
//! follows one of three published designs as its *mode*: `diehard`,
//! `dieharder`, or `exterminator`. A caller puts this heap under a program that
//! is corrupting its own memory, either to survive the corruption or to find
//! out where it comes from. The heap stores that `std.mem.Allocator` at init
//! and asks it for the memory it carves up, the *backing allocator*.
//!
//! A request up to 1 MiB takes the first block size at least as large as itself
//! from a fixed list of powers of two from 16 bytes upward, the *size class*,
//! and a larger request goes to the backing allocator on its own. Each class
//! holds more blocks than the live count needs, because the heap grows the
//! class once eight times the live count plus one reaches seven times its
//! capacity. A request takes a block drawn at random from the whole capacity of
//! its class, so which allocation sits next to which is unpredictable from one
//! run to the next.
//!
//! The mode sets a count of allocation epochs a freed block stays unusable, a
//! *quarantine epoch*: zero for `diehard`, at least eight for `dieharder`, and
//! at least one for `exterminator`, so a write through a freed pointer still
//! lands in the block that pointer had.
//!
//! With diagnostics on, the heap places canary bytes around each block whose
//! pattern a later check reads, a *red zone*. When that pattern changed, a
//! later check records the memory-safety fault with its kind, its address, its
//! offset, its sizes, and the return addresses of the allocation and the free,
//! an *issue*. `report` answers with live counts, live bytes, per-kind
//! counters, and the bounded array of issues a run keeps, the *issue log*. This
//! log holds up to 32 issues and counts the ones past that bound as dropped. An
//! issue's kind is one of invalid free, double free, buffer overflow, use after
//! free, leak, and size mismatch.
//!
//! `Config.repaired` reads a report into per-call-site padding and quarantine
//! extensions, forming a *repair table*: padding for a call site whose
//! allocations overflowed, and longer quarantine for a site whose memory was
//! used after the free, returned as a config in `exterminator` mode. A later
//! run under that config pads the allocations of the named site and extends the
//! quarantine of the named free, so the program can keep running while the bug
//! is fixed.

const allocator_mod = @import("allocator.zig");
const exterminator_mod = @import("exterminator.zig");
const report_mod = @import("report.zig");

pub const Config = allocator_mod.Config;
pub const DeadAllocator = allocator_mod.DeadAllocator;
pub const DiagnosticConfig = allocator_mod.DiagnosticConfig;
pub const Issue = allocator_mod.Issue;
pub const IssueKind = allocator_mod.IssueKind;
pub const IssueLog = report_mod.IssueLog;
pub const Mode = allocator_mod.Mode;
pub const Report = allocator_mod.Report;
pub const RepairPolicy = exterminator_mod.RepairPolicy;
pub const RepairTable = exterminator_mod.RepairTable;
pub const class_sizes = allocator_mod.class_sizes;
pub const max_issues = report_mod.max_issues;
pub const max_repair_entries = exterminator_mod.max_repair_entries;
pub const max_small_size = allocator_mod.max_small_size;
pub const min_alignment = allocator_mod.min_alignment;
pub const page_size = allocator_mod.page_size;

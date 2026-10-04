//! The package decides which allocator a program's long-lived storage comes
//! from, and it holds the byte ceiling a caller can put in front of an
//! allocator. The single allocator a program's long-lived storage comes from,
//! chosen when the program is compiled, is the *process allocator*. The parts
//! of a program that live as long as the process take the storage they need
//! while it starts up.
//!
//! The process sits in one stage of its life at a time, its *phase*, one of
//! initialization, steady state, or teardown. The startup stage, in which
//! allocation is expected, is *initialization*. The call that ends
//! initialization and moves the process to steady state is the *seal*, executed
//! by `sealProcessAllocatorPhase`. The stage after the seal, in which an
//! allocation counts as a violation, is *steady state*. One allocator operation
//! that arrived in a phase which forbids it is a *violation*.
//!
//! The build setting that decides what happens to a violation, one of `off`,
//! `observe`, or `seal`, is the *process phase mode*. Under the `seal` build
//! setting, an allocation, a resize, or a remap that arrives after the seal
//! panics and is refused, and a free is refused the same way. Under the
//! `observe` setting, the same operation is counted, the return address of the
//! call that violated is kept as the *violation site*, and the operation goes
//! through. A free during teardown counts as no violation, so a program can
//! release its startup storage.
//!
//! The allocator that checks a byte ceiling of its own before asking the
//! allocator behind it for anything is the *limit allocator*, implemented as
//! `LimitAllocator`. That ceiling bounds how far the memory behind it can grow.
//! `LimitAllocator` reports its own refusal, `AllocationLimitExceeded`, apart
//! from the backing allocator's `OutOfMemory`, so a caller can tell a
//! configured ceiling from a machine running out of memory.

const boundary = @import("boundary.zig");
const diagnostics = @import("diagnostics.zig");
const limit = @import("alloc_limit");
const locked = @import("alloc_locked");
const owner = @import("owner.zig");
const policy = @import("policy.zig");
const process = @import("process.zig");

pub const phase = @import("alloc_phase");

pub const TestAllocatorMode = policy.TestAllocatorMode;
pub const test_allocator_mode = policy.test_allocator_mode;
pub const allocator_diagnostics_mode = diagnostics.mode;
pub const ProcessPhaseMode = process.ProcessPhaseMode;
pub const process_phase_mode = process.mode;

pub const longLivedProcessAllocator = policy.longLivedProcessAllocator;
pub const interactiveSessionAllocator = policy.interactiveSessionAllocator;
pub const standaloneProcessAllocator = policy.standaloneProcessAllocator;
pub const workerAllocator = policy.workerAllocator;
pub const threadedIoAllocator = policy.threadedIoAllocator;
pub const temporaryScratchAllocator = policy.temporaryScratchAllocator;
pub const testIntegrationAllocator = policy.testIntegrationAllocator;

pub const diagnosticAllocatorConfig = diagnostics.config;
pub const diagnosticAllocatorReport = diagnostics.report;

pub const sealProcessAllocatorPhase = policy.sealProcessAllocatorPhase;
pub const beginProcessAllocatorTeardown = policy.beginProcessAllocatorTeardown;
pub const processAllocatorPhase = process.currentPhase;
pub const processAllocatorPhaseViolations = process.violations;
pub const processAllocatorPhaseViolationSites = process.violationSites;

pub const ProcessAllocatorOwner = owner.ProcessAllocatorOwner;
pub const ProcessAllocatorFinish = owner.ProcessAllocatorFinish;
pub const LimitAllocator = limit.LimitAllocator;
pub const LockedAllocator = locked.LockedAllocator;
pub const RegionAllocator = @import("region.zig").RegionAllocator;

pub const PhaseBoundary = boundary.PhaseBoundary;
pub const PhaseBoundaryState = boundary.PhaseBoundaryState;
pub const writePhaseReport = boundary.writePhaseReport;

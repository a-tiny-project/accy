//! ## Package overview
//!
//! When we ingest external input from streams or files, we want to accept
//! bounded payloads using a single reusable byte allocation without allocating
//! on every message or resizing buffers on the fly. We configure an explicit
//! upper bound on accepted length, allocate storage once, and reuse that
//! storage across successive operations while detecting oversized inputs before
//! admitting them.
//!
//! ## One buffer and lookahead
//!
//! The core challenge in bounded ingestion sits at the boundary of the limit.
//! If we configure our system to accept at most `n` bytes and allocate an
//! `n`-byte buffer, filling that buffer completely leaves an ambiguity: did the
//! input stream end precisely at `n` bytes, or does more data remain waiting in
//! the channel? To resolve whether the input fits or exceeds our boundary, this
//! implementation reserves space for one extra byte. For an accepted limit of
//! `n` bytes, the backing buffer holds `n + 1` bytes. When we read from the
//! source into the buffer:
//!
//! - If the source yields between 0 and `n` bytes before reaching end-of-file,
//!   the input fits within our configured boundary and we admit it.
//! - If the source yields `n + 1` bytes, the input exceeds our limit and we
//!   reject it immediately, without allocating a second buffer.
//!
//! We term this calculation *capacity derivation*. The standard helper
//! `deriveCapacity` computes this boundary for an owner. Given a configuration
//! structure containing a byte limit field of type `usize`, it uses checked
//! integer addition to compute `n + 1`. If adding one to the limit overflows
//! `usize`, derivation fails with `error.CapacityOverflow`. When a caller
//! configures a limit of zero, derivation reserves one byte, which allows an
//! empty input to be distinguished from an input containing data.
//!
//! The `deriveCapacity` helper initializes only two fields in the resulting
//! capacity record: the configured limit and the derived `storage_bytes`. The
//! limit field name and `storage_bytes` must be distinct. Any additional fields
//! declared on the capacity type remain undefined, so a custom capacity type
//! that requires extra fields must populate them in a custom derivation
//! function.
//!
//! The generic container `OneRegion(Spec)` produces an allocator-backed owner
//! around this storage model. While `deriveCapacity` enforces the standard `n +
//! 1` sizing rule, a custom derivation function may describe larger storage
//! when required by domain constraints: derivation computes a `Capacity` value,
//! while `init` allocates the storage. The owner asserts that `storage_bytes`
//! strictly exceeds the configured input limit.
//!
//! ## A successful borrow and release
//!
//! Because a single byte buffer is reused across requests, concurrent access
//! would corrupt in-flight payloads. An outstanding borrow represents temporary
//! exclusive access granted to an admitted input. Until that borrow is
//! relinquished, the owner enforces busy protection across subsequent
//! acquisition and preflight calls.
//!
//! The lifecycle of an input owner progresses through three sequential phases:
//! initialization, steady operation, and teardown. Calling `init` enters the
//! initialization phase, calling `activate` advances to steady operation, and
//! calling `deinit` enters teardown. Calling `deinit` requires that no borrow
//! remains outstanding. If startup fails prior to activation, `deinit` can be
//! called directly from the initialization phase to free the buffer.
//!
//! During initialization, `init` derives the capacity and requests a single
//! contiguous slice of `storage_bytes` from the provided allocator. If capacity
//! derivation overflows or the allocator fails, `init` returns an error union
//! of `DeriveError` and `std.mem.Allocator.Error`. Once allocated, the owner
//! retains the byte slice but does not retain an allocator handle. In steady
//! operation, the owner methods do not call the initialization allocator. The
//! absence of a retained allocator on the owner does not prevent arbitrary
//! readers or filesystem code from allocating dynamically or performing
//! external work.
//!
//! Phase transitions are guarded by debug assertions (`std.debug.assert`),
//! which verify that `activate` is called only from the initialization phase
//! and that `deinit` is called with no active borrow. These debug assertions
//! differ from the explicit wrong-phase panics enforced by the separate phase
//! allocator.
//!
//! In steady operation, calling `read` ingests data into the buffer and admits
//! the payload if the returned length does not exceed the configured limit. A
//! successful read returns a borrowed constant slice (`[]const u8`) and sets
//! the internal `in_use` flag. Even an empty zero-byte read establishes an
//! active borrow and marks the owner busy. While `in_use` remains true, any
//! attempt to read, window, or preflight another input returns `in_use_error`.
//! This failure indicates a busy owner and does not increment the capacity
//! rejection counter.
//!
//! When the caller finishes processing the borrowed slice, it invokes
//! `release`. Calling `release` sets `in_use` to false and resets the loaded
//! byte counter to zero. It does not zero or scrub the underlying memory, nor
//! does it reset historical rejection counts or high-water marks.
//!
//! Because reads overwrite the backing buffer, a caller that needs to retain
//! admitted bytes across subsequent operations must copy them into separate
//! storage before calling `release`. A fixed stack array provides a convenient
//! target for preserving small records without allocating heap memory.
//!
//! Copies of an owner struct share the underlying byte slice while duplicating
//! internal bookkeeping. Because copies are not independent owners, callers
//! must serialize operations and ensure that cleanup occurs exactly once.
//! Calling `deinit` requires that no borrow remains outstanding, transitions
//! the phase to teardown, and frees the slice using the same allocator passed
//! during initialization. The owner provides no secondary abort or partial
//! teardown routines.
//!
//! In the Issue tool, body storage adopts this borrow discipline. Its
//! `BodySource` container pairs a borrowed slice of the input region with an
//! optional pointer to the owner. When processing finishes or an empty body
//! triggers an early exit, the consumer releases the borrow before reporting
//! results. Command-line arguments provided directly in the process invocation
//! bypass the input region entirely, leaving the buffer available for file or
//! standard-input ingestion.
//!
//! ## Failure and recovery
//!
//! When an incoming payload exceeds the configured limit, the owner rejects the
//! admission. How the owner responds to this overload depends on whether it is
//! configured with a terminal or recoverable policy:
//!
//! - A terminal owner treats an oversized input as a permanent boundary fault.
//!   Upon rejection, it increments a saturating 64-bit rejection counter, sets
//!   an internal `terminal` flag, and refuses all subsequent read attempts with
//!   `capacity_error` without incrementing the counter again.
//! - A recoverable owner increments the rejection counter but leaves `terminal`
//!   false. Storage remains immediately available to accept another input
//!   without an acknowledgement step.
//!
//! Recovery denotes the ability to reuse the owned memory buffer for a future
//! request: it does not imply stream rewinding, transaction rollback, or
//! automatic framing.
//!
//! When reading from a stream through `Reader.readSliceShort`, capacity
//! rejection under the standard derivation helper occurs after reading up to
//! `limit + 1` logical bytes into the buffer. The owner does not drain any
//! remaining bytes left in the underlying stream. If an external caller
//! attempts to read from that same stream again, the retry does not guarantee
//! alignment with the start of a logical record. User reader implementations
//! may also maintain internal buffers or perform dynamic allocations outside
//! the owner's knowledge. If a stream encounters an I/O failure such as
//! `ReadFailed`, the failure can consume source bytes and overwrite buffer
//! contents. In that situation, no borrow is admitted and the owner's capacity
//! rejection counter does not increment.
//!
//! To avoid reading unwanted bytes when an input size is known beforehand, an
//! application can call `preflight`. The `preflight` method accepts an expected
//! size as a 64-bit integer, checks that the owner is available, and verifies
//! that the size fits within `usize` and does not exceed the limit. If the
//! proposed size cannot be represented in `usize` or exceeds the limit,
//! `preflight` rejects the request, updates rejection accounting, and returns
//! `capacity_error`. A successful preflight verifies available space, but it
//! neither reserves storage nor forms an atomic transaction with a subsequent
//! read.
//!
//! Calling `status` returns a snapshot structure by value containing the
//! current phase, the `in_use` flag, the configured limit, the declared storage
//! size, the currently loaded bytes, the high-water mark of admitted bytes, the
//! cumulative rejection count, and the terminal flag for terminal owners. The
//! high-water mark records the largest admitted input, ignoring rejected
//! attempts. Following `deinit`, the historical counters and declared capacity
//! fields remain readable in the returned status snapshot, which means
//! `storage_bytes` reports declared storage size rather than live retained heap
//! memory.
//!
//! The Peek image decoding pipeline relies on a recoverable configuration. Its
//! loader reads image files into the input buffer, holds the borrow while
//! decoding pixel data into external image structures, and releases the owner
//! immediately after decoding. If an oversized image is rejected, the owner
//! remains active, enabling subsequent file reads to reuse the same memory
//! allocation.
//!
//! ## Whole files versus windows
//!
//! Reading files introduces distinct concerns regarding whole-file ingestion
//! versus positional slice inspection.
//!
//! Calling `readFile` reads an input file into the bounded buffer using the
//! standard library directory interface. When reading an ordinary file whose
//! size exceeds the limit, the reader fills the buffer prefix and the owner
//! rejects the operation. The acquisition specification provides a
//! configuration flag named `map_file_too_big`:
//!
//! - When `map_file_too_big` is enabled, an underlying `FileTooBig` error
//!   returned by the filesystem maps directly into the owner's capacity
//!   rejection, incrementing the rejection counter and setting the terminal
//!   flag if configured.
//! - When `map_file_too_big` is disabled, `FileTooBig` propagates outward as a
//!   filesystem error, bypassing rejection accounting and leaving the terminal
//!   flag unset.
//! - Other filesystem errors, such as missing files or access faults, propagate
//!   unchanged under either setting without modifying capacity counters.
//!
//! When inputs exceed the capacity of our buffer, reading the entire file at
//! once is impossible. Instead, we inspect bounded portions of the file using
//! `readFileWindow`.
//!
//! Calling `readFileWindow` requires that file acquisition is enabled, that
//! storage is available, and that the requested window length satisfies `0 <
//! window_bytes <= limit`. The method reads up to `window_bytes + 1` bytes at a
//! specified file offset, admits `min(read_count, window_bytes)`, and returns a
//! `FileWindow` structure containing the borrowed slice and a boolean
//! `complete` flag.
//!
//! If the file contains bytes beyond the requested window, the lookahead byte
//! is populated, `complete` is set to false, and the admitted slice contains
//! exactly `window_bytes`. An incomplete window read does not trigger a
//! capacity rejection, even when the owner is configured as terminal. If the
//! offset sits at end-of-file, a zero-byte read completes successfully and
//! still establishes an active borrow. The `complete` flag describes only the
//! result of this specific positional read: it does not provide an
//! instantaneous file-length snapshot or guarantee that the file will not grow
//! concurrently.
//!
//! Glom demonstrates how windowed ingestion coordinates with record framing.
//! Glom ingests structured transcript files using a terminal input owner with
//! preflight enabled. Because individual transcript records vary in length and
//! files can grow large, its parser reads a positional window from the file. If
//! `complete` is false, the window ended before the end of the file. Glom
//! inspects the admitted bytes for the last newline character, processes
//! complete lines up to that delimiter, releases the borrow, and advances its
//! file offset to resume reading. If a maximum-sized window contains no newline
//! delimiter at all, the consumer itself raises a record-framing error. Framing
//! logic remains the responsibility of the consumer, while the input region
//! guarantees only the bounded byte window.
//!
//! ## Declaration scope and interface shapes
//!
//! To integrate an input owner with verification and capacity tooling, we
//! encapsulate its configuration within a `Spec` structure. A specification
//! packages input limit and capacity types, error sets, status layout, enabled
//! acquisition capabilities, overload policy, and a formal capacity
//! `Declaration`.
//!
//! The status structure must declare exactly seven fields for recoverable
//! owners or eight fields for terminal owners. While the generic checker
//! validates the field count and types, it does not verify that custom field
//! mappings are distinct from one another. We must supply distinct field names
//! to prevent diagnostic collisions.
//!
//! The capacity `Declaration` establishes the structural contract of the owner
//! for this example:
//!
//! - Validation of `phase_static` requires valid seal and teardown bindings.
//!   The tag describes a claim and does not govern actual allocation behavior
//!   or enforce an operational lifetime. The limit source is marked as
//!   `.caller`, indicating that limits are supplied at initialization.
//! - The storage section specifies covered memory, naming the single
//!   steady-state input buffer and describing its purpose. Excluded clauses
//!   document runtime resources that sit outside the claim, such as stream
//!   reader handles and destination parsing structures.
//! - The capacity model defines an expression graph capturing the `n + 1`
//!   derivation. An input node binds the limit field, an integer constant node
//!   provides the literal 1, and an addition node sums them. An assertion
//!   declares that total retained storage matches this expression.
//! - The overload policy is declared as `.drop`, documenting that oversized
//!   input is rejected while storage remains available for a later attempt. The
//!   `.drop` policy does not preserve previously released payload bytes:
//!   subsequent reads can overwrite released bytes in the backing buffer.
//! - Transitive and foreign operational risks are marked as `.open`,
//!   acknowledging that reader streams or filesystem calls can incur effects
//!   outside the region boundaries.
//! - The declaration lists obligations for the capacity model and the overload
//!   policy.
//!
//! When `OneRegion(Spec)` generates an owner, it constructs fresh bindings
//! linking the owner type, the specification, and selectors for `activate` and
//! `deinit`. It does not reuse any bindings declared on `Spec.claim`. Claim
//! declarations and premise labels such as `.checked_semantic_fact` provide
//! structural metadata for verification tools: they do not establish proven
//! semantic facts or whole-program safety guarantees.
//!
//! We validate this generated structure at compile time using
//! `alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage)`. This
//! function performs structural reflection, checking that the owner provides
//! required lifecycle functions, exposes an exhaustion error set on receiver
//! methods, and presents a compatible claim.
//!
//! The following test illustrates a specification and recoverable input owner:
//!
//! ```zig
//! const std = @import("std");
//! const alloc_phase = @import("alloc_phase");
//!
//! pub const InputLimits = struct {
//!     max_bytes: usize,
//! };
//!
//! pub const InputCapacity = struct {
//!     max_bytes: usize,
//!     storage_bytes: usize,
//!
//!     pub fn derive(limits: InputLimits) alloc_phase.input.DeriveError!InputCapacity {
//!         return alloc_phase.input.deriveCapacity(InputLimits, InputCapacity, "max_bytes", limits);
//!     }
//! };
//!
//! pub const InputExhaustion = error{
//!     InputStorageBusy,
//!     InputCapacityExceeded,
//! };
//!
//! pub const InputStatus = struct {
//!     phase: alloc_phase.capacity.Phase,
//!     in_use: bool,
//!     max_bytes: usize,
//!     storage_bytes: usize,
//!     loaded_bytes: usize,
//!     high_water_bytes: usize,
//!     rejected_count: u64,
//! };
//!
//! pub const Spec = struct {
//!     pub const Limits = InputLimits;
//!     pub const Capacity = InputCapacity;
//!     pub const Exhaustion = InputExhaustion;
//!     pub const Status = InputStatus;
//!     pub const DeriveError = alloc_phase.input.DeriveError;
//!     pub const acquisition: alloc_phase.input.Acquisition = .{
//!         .reader = true,
//!         .preflight = true,
//!     };
//!     pub const overload: alloc_phase.input.Overload = .recoverable;
//!     pub const limit_field = "max_bytes";
//!     pub const loaded_field = "loaded_bytes";
//!     pub const high_water_field = "high_water_bytes";
//!     pub const rejected_field = "rejected_count";
//!     pub const in_use_error: Exhaustion = error.InputStorageBusy;
//!     pub const capacity_error: Exhaustion = error.InputCapacityExceeded;
//!
//!     pub const claim: alloc_phase.capacity.Declaration = .{
//!         .source = .{
//!             .id = "guide.recoverable_reader",
//!             .kind = .phase_static,
//!             .limit_source = .caller,
//!             .storage = .{
//!                 .covered = &.{
//!                     .{
//!                         .id = "reusable_input_buffer",
//!                         .lifetime = .steady,
//!                         .detail = "one reusable input and lookahead byte region",
//!                     },
//!                 },
//!                 .excluded = &.{
//!                     "stream reader buffering and allocator handles",
//!                     "caller payload storage outside the borrowed window",
//!                 },
//!             },
//!             .capacity = .{
//!                 .inputs = &.{
//!                     alloc_phase.capacity.bindInput(InputLimits, "max_bytes", "max_bytes"),
//!                 },
//!                 .type_selectors = &.{},
//!                 .nodes = &.{
//!                     .{ .input = 0 },
//!                     .{ .constant = 1 },
//!                     .{ .add = .{ .left = 0, .right = 1 } },
//!                 },
//!                 .assertions = &.{
//!                     .{
//!                         .scope = .closure_total,
//!                         .measure = .retained,
//!                         .relation = .exact,
//!                         .expression = 2,
//!                     },
//!                 },
//!             },
//!             .overload = .{
//!                 .kind = .drop,
//!                 .detail = "oversized input is rejected while storage remains available for a later attempt",
//!             },
//!             .risks = .{
//!                 .transitive = .{
//!                     .status = .open,
//!                     .detail = "stream operations may perform external allocations",
//!                 },
//!                 .foreign = .{
//!                     .status = .open,
//!                     .detail = "kernel stream handles remain unmanaged",
//!                 },
//!             },
//!             .obligations = &.{
//!                 .{ .key = "input_capacity_model", .role = .capacity_model },
//!                 .{ .key = "input_overload_policy", .role = .overload },
//!             },
//!         },
//!         .bindings = .{},
//!     };
//! };
//!
//! pub const Storage = alloc_phase.input.OneRegion(Spec);
//!
//! comptime {
//!     alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
//! }
//!
//! test "recoverable input storage lifecycle, borrow discipline, and reuse" {
//!     const allocator = std.testing.allocator;
//!     var storage = try Storage.init(allocator, .{ .max_bytes = 5 });
//!     defer storage.deinit(allocator);
//!     defer if (storage.in_use) storage.release();
//!
//!     storage.activate();
//!
//!     var first_reader: std.Io.Reader = .fixed("hello");
//!     const borrowed = try storage.read(&first_reader);
//!
//!     try std.testing.expectEqual(@as(usize, 5), borrowed.len);
//!     try std.testing.expectEqualStrings("hello", borrowed);
//!     try std.testing.expectError(error.InputStorageBusy, storage.preflight(0));
//!
//!     var preserved: [5]u8 = undefined;
//!     @memcpy(&preserved, borrowed);
//!
//!     storage.release();
//!
//!     try std.testing.expectEqualStrings("hello", &preserved);
//!
//!     const status_after_release = storage.status();
//!     try std.testing.expect(!status_after_release.in_use);
//!     try std.testing.expectEqual(@as(usize, 0), status_after_release.loaded_bytes);
//!     try std.testing.expectEqual(@as(usize, 5), status_after_release.high_water_bytes);
//!     try std.testing.expectEqual(@as(u64, 0), status_after_release.rejected_count);
//!
//!     try std.testing.expectError(error.InputCapacityExceeded, storage.preflight(6));
//!
//!     const status_after_reject = storage.status();
//!     try std.testing.expectEqual(@as(u64, 1), status_after_reject.rejected_count);
//!
//!     var second_reader: std.Io.Reader = .fixed("zig");
//!     const second_borrow = try storage.read(&second_reader);
//!
//!     try std.testing.expectEqualStrings("zig", second_borrow);
//!
//!     const status_final = storage.status();
//!     try std.testing.expect(status_final.in_use);
//!     try std.testing.expectEqual(@as(usize, 3), status_final.loaded_bytes);
//!     try std.testing.expectEqual(@as(usize, 5), status_final.high_water_bytes);
//!
//!     try std.testing.expectEqualStrings("hello", &preserved);
//!
//!     storage.release();
//! }
//! ```
//!
//! The source unit tests for `alloc_phase.input` assert capacity derivation
//! from 31 to 32 bytes, overflow detection at integer limits, initialization
//! failure under allocation faults, exact acceptance of fitting payloads, busy
//! errors during active borrows, saturating rejection counters on terminal
//! owners, and recoverable reuse following an oversized preflight check.
//! Additional property tests assert `n + 1` allocation sizing for limits up to
//! 4096 bytes, and consumer test suites exercise windowed reads alongside file
//! boundary handling.

const one = @import("one.zig");

/// Packed boolean structure that enables specific input capabilities on an
/// owner at compile time. All four fields default to `false`:
///
/// * `reader`: Enables stream acquisition through `read`.
///
/// * `file`: Enables filesystem acquisition through `readFile` and
/// `readFileWindow`.
/// * `preflight`: Enables size admission checks through `preflight`.
/// * `map_file_too_big`: Maps `error.FileTooBig` from an underlying `readFile`
/// call into a capacity rejection instead of propagating the raw I/O error.
///
/// Because an owner must support at least one input mechanism, specification
/// validation requires either `reader` or `file` to be enabled. Mapping
/// file-size errors requires filesystem support, so `map_file_too_big` can be
/// enabled only when `file` is also set to `true`. Individual acquisition
/// methods verify their corresponding flags at compile time and raise a compile
/// error when invoked without the required capability enabled.
pub const Acquisition = one.Acquisition;
/// Error set returned when capacity derivation fails.
///
/// Members:
///
/// * `CapacityOverflow`: Adding one lookahead byte to the configured byte limit
/// overflowed the range of `usize`.
pub const DeriveError = one.DeriveError;
/// Constructs an allocator-backed owner type for a single reusable input buffer
/// based on a static specification structure.
///
/// The `Spec` type parameter must satisfy several structural requirements:
///
/// * `Limits`: Structure defining input limits. It must contain the field
/// designated by `limit_field` typed as `usize`.
/// * `Capacity`: Structure defining storage requirements. It must expose a
/// `derive(limits: Limits) DeriveError!Capacity` function, the field named by
/// `limit_field` typed as `usize`, and `storage_bytes` typed as `usize`.
/// * `DeriveError`: Error set returned by `Capacity.derive`.
/// * `Exhaustion`: Error set returned when storage cannot admit an input.
/// * `Status`: Reporting structure returned by `status`. It must be a struct
/// containing exactly seven fields for recoverable owners or eight fields for
/// terminal owners: `phase: alloc_phase.capacity.Phase`, `in_use: bool`,
/// `storage_bytes: usize`, the mapped limit, loaded, and high-water fields
/// typed as `usize`, the mapped rejection field typed as `u64`, and
/// conditionally `terminal: bool` when `overload` is `terminal`.
/// * `acquisition`: An instance of `Acquisition` specifying enabled I/O
/// capabilities.
/// * `overload`: An instance of `Overload` setting either `.terminal` or
/// `.recoverable` behavior.
/// * Field mappings: `limit_field`, `loaded_field`, `high_water_field`, and
/// `rejected_field` specify field names on `Capacity` or `Status`. Callers must
/// supply distinct names for these fields. Compile-time validation verifies
/// field presence and total field counts, but this validation does not prove
/// that mapped field names are mutually distinct.
/// * Error instances: `in_use_error` and `capacity_error` must both have type
/// `Spec.Exhaustion`.
/// * `claim`: A static `alloc_phase.capacity.Declaration` metadata descriptor.
///
/// The owner asserts that `storage_bytes` strictly exceeds the configured byte
/// limit. While standard `deriveCapacity` derivation provides an exact `limit +
/// 1` layout, custom `Capacity.derive` implementations may describe larger
/// storage: derivation computes a `Capacity` value, while `init` allocates.
///
/// A successful read operation returns a borrowed `[]const u8` slice pointing
/// directly into the owned buffer and marks the owner as in use, including when
/// the input is empty. Borrowers must consume or copy these bytes elsewhere
/// before calling `release`. Slices must not be accessed after releasing the
/// owner.
///
/// A struct copy shares allocated storage but duplicates internal bookkeeping.
/// Copies are not independent owners: transferring exclusive ownership requires
/// callers to stop using the original. Callers must serialize operations and
/// ensure cleanup occurs exactly once.
///
/// The owner is not thread-safe and performs no internal synchronization.
/// Callers accessing an owner across threads must provide external mutual
/// exclusion.
///
/// Lifecycle checks across initialization, steady operation, and teardown are
/// enforced through debug assertions rather than explicit always-executed phase
/// panics.
pub const OneRegion = one.OneRegion;
/// Defines the policy applied when an input exceeds the configured capacity
/// limit.
///
/// Tags:
///
/// * `terminal`: Permanently seals the owner upon capacity rejection. Any
/// subsequent acquisition attempt returns the capacity error immediately
/// without performing I/O or incrementing rejection counters.
/// * `recoverable`: Preserves owner availability across rejections. Oversized
/// inputs increment the rejection counter but leave the underlying storage free
/// for subsequent attempts.
///
/// Recovery designates the ability to reuse the allocated storage for later
/// inputs. It does not provide source-position rollback, record framing, or
/// automatic input drainage.
pub const Overload = one.Overload;
/// Derives an instance of `Capacity` from a given `Limits` structure by adding
/// one lookahead byte to the configured input limit.
///
/// The input limit is retrieved from the field named by `limit_field` on
/// `limits`. Both the limit field on `Limits` and `Capacity` and the
/// `storage_bytes` field on `Capacity` must be typed as `usize`. When addition
/// overflows `usize`, the function returns `error.CapacityOverflow`. A limit of
/// zero derives a storage size of one byte.
///
/// The returned `Capacity` structure initializes only the field named by
/// `limit_field` and `storage_bytes`. Any additional fields present on
/// `Capacity` remain undefined. Callers must keep `limit_field` distinct from
/// `storage_bytes` so that writing `storage_bytes` does not overwrite the limit
/// field.
pub const deriveCapacity = one.deriveCapacity;

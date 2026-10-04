//! Provides bounded input admission into a single reusable byte buffer.
//!
//! Callers configure an upper limit on acceptable input size. Because
//! distinguishing an exactly full input from an oversized payload without a
//! second growing buffer requires lookahead, standard capacity derivation
//! reserves one extra byte beyond the configured limit.
//!
//! The allocation lifecycle proceeds across distinct phases. During
//! initialization, the owner derives capacity and allocates its byte slice
//! through a caller-provided allocator. Activation transitions the owner into
//! steady operation. Steady-state callers borrow byte slices during read
//! operations, consume or copy the borrowed data, and release the buffer before
//! initiating the next read. Teardown frees the backing storage through the
//! allocator used for initialization. External callers must serialize
//! operations because the owner maintains mutable internal state without
//! internal synchronization.

const std = @import("std");
const alloc_phase = @import("../root.zig");

/// Error set returned when capacity derivation fails.
///
/// Members:
///
/// * `CapacityOverflow`: Adding one lookahead byte to the configured byte limit
/// overflowed the range of `usize`.
pub const DeriveError = error{CapacityOverflow};

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
pub const Acquisition = packed struct {
    reader: bool = false,
    file: bool = false,
    preflight: bool = false,
    map_file_too_big: bool = false,
};

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
pub const Overload = enum {
    terminal,
    recoverable,
};

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
pub fn deriveCapacity(
    comptime Limits: type,
    comptime Capacity: type,
    comptime limit_field: []const u8,
    limits: Limits,
) DeriveError!Capacity {
    comptime requireCapacityTypes(Limits, Capacity, limit_field);
    const limit_bytes = @field(limits, limit_field);
    const storage_bytes = try alloc_phase.capacity.add(usize, limit_bytes, 1);
    std.debug.assert(storage_bytes > limit_bytes);
    std.debug.assert(storage_bytes != 0);
    var capacity: Capacity = undefined;
    @field(capacity, limit_field) = limit_bytes;
    capacity.storage_bytes = storage_bytes;
    return capacity;
}

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
pub fn OneRegion(comptime Spec: type) type {
    comptime requireSpec(Spec);
    return struct {
        phase: alloc_phase.capacity.Phase,
        capacity: Spec.Capacity,
        bytes: []u8,
        in_use: bool = false,
        terminal: bool = false,
        loaded_bytes: usize = 0,
        high_water_bytes: usize = 0,
        rejected_count: u64 = 0,

        const Self = @This();

        /// Result structure returned by `readFileWindow` representing a bounded
        /// slice of a file read at a positional offset.
        ///
        /// Fields:
        ///
        /// * `bytes`: Borrowed const byte slice containing admitted data. Its
        /// length is at most the requested window size.
        /// * `complete`: Boolean flag set to `true` when `read_bytes <=
        /// window_bytes`.
        ///
        /// The `complete` flag describes only this positional read and does not
        /// make an immutable snapshot against concurrent modification during or
        /// after it.
        pub const FileWindow = struct {
            bytes: []const u8,
            complete: bool,
        };

        /// Type alias for `Spec.Limits`. Defines the input limit constraints
        /// supplied by the caller.
        pub const Limits: type = Spec.Limits;
        /// Type alias for `Spec.Capacity`. Holds derived storage dimensions,
        /// including the mandatory `storage_bytes` field.
        pub const Capacity: type = Spec.Capacity;
        /// Type alias for `Spec.Exhaustion`. Represents the error set returned
        /// when input operations encounter a busy buffer or exceed configured
        /// capacity.
        pub const Exhaustion: type = Spec.Exhaustion;
        /// Error set representing failures that can occur during
        /// initialization. Combines allocator allocation errors with
        /// `Spec.DeriveError`.
        pub const InitError = std.mem.Allocator.Error || Spec.DeriveError;
        /// Static capacity declaration describing the memory allocation
        /// semantics of the generated owner.
        ///
        /// The declaration retains the complete `Spec.claim.source` envelope
        /// while establishing fresh bindings for the generated owner:
        ///
        /// * `owner`: Binds the generated owner type `Self`.
        /// * `source`: Binds the originating `Spec` configuration type.
        /// * `seal`: Binds the `activate` method selector under the
        /// `checked_semantic_fact` class with `checker` authority.
        /// * `teardown`: Binds the `deinit` method selector under the
        /// `checked_semantic_fact` class with `checker` authority.
        ///
        /// The bindings defined on `Spec.claim.bindings` are not reused.
        /// Assigning premise labels to these new bindings does not prove their
        /// truth. Local specification checks verify only that `claim` has type
        /// `alloc_phase.capacity.Declaration`. Separate structural and
        /// declaration checking verifies lifecycle declaration shape, but that
        /// check does not prove whole-program allocation freedom.
        pub const claim: alloc_phase.capacity.Declaration = .{
            .source = Spec.claim.source,
            .bindings = .{
                .owner = Self,
                .source = Spec,
                .seal = .{
                    .family = alloc_phase.capacity.selector(Self.activate),
                    .premise = .{
                        .class = .checked_semantic_fact,
                        .authority = .checker,
                    },
                },
                .teardown = .{
                    .family = alloc_phase.capacity.selector(Self.deinit),
                    .premise = .{
                        .class = .checked_semantic_fact,
                        .authority = .checker,
                    },
                },
            },
        };

        /// Initializes a new input region by deriving capacity and allocating
        /// the backing byte slice.
        ///
        /// The function derives capacity by evaluating
        /// `Capacity.derive(limits)`. When derivation succeeds, it allocates
        /// `capacity.storage_bytes` through the provided allocator. The
        /// initialized owner enters the `.initialization` phase and retains the
        /// allocated slice. The allocator handle itself is not stored on the
        /// instance, so callers must provide the same allocator during
        /// deinitialization.
        ///
        /// Initialization fails with `Spec.DeriveError` if capacity derivation
        /// fails, or with `error.OutOfMemory` if memory allocation fails.
        /// Before returning, debug assertions verify that the allocated slice
        /// length equals `storage_bytes` and strictly exceeds the configured
        /// byte limit.
        pub fn init(allocator: std.mem.Allocator, limits: Limits) InitError!Self {
            const capacity = try Capacity.derive(limits);
            const bytes = try allocator.alloc(u8, capacity.storage_bytes);
            const storage = Self{
                .phase = .initialization,
                .capacity = capacity,
                .bytes = bytes,
            };
            storage.assertRegion();
            return storage;
        }

        /// Transitions the owner from the initialization phase into steady
        /// operation.
        ///
        /// Callers must activate the owner before performing input operations.
        /// The function verifies through debug assertions that the owner
        /// resides in the `.initialization` phase and that the backing buffer
        /// satisfies region invariants. Once activated, `phase` transitions to
        /// `.steady`, permitting acquisition calls.
        pub fn activate(self: *Self) void {
            std.debug.assert(self.phase == .initialization);
            self.assertRegion();
            self.phase = .steady;
        }

        /// Performs a size admission check for an expected input length without
        /// executing I/O or modifying buffer contents.
        ///
        /// This method requires `Spec.acquisition.preflight` to be enabled at
        /// compile time. Before evaluating the size, it verifies that the owner
        /// is available in steady operation. If an operation is currently
        /// active, it returns `Spec.in_use_error`. If the owner was previously
        /// sealed in a terminal state, it returns `Spec.capacity_error`.
        ///
        /// The proposed length `input_bytes` is cast to `usize`. If the value
        /// overflows `usize` or exceeds the configured byte limit, the method
        /// invokes internal rejection, incrementing the saturating rejection
        /// counter and applying the configured overload policy before returning
        /// `Spec.capacity_error`.
        ///
        /// A successful preflight check confirms only that the proposed size
        /// fits within the configured limit. It does not reserve storage, lock
        /// the buffer, or establish an atomic guarantee between checking a size
        /// and executing a later read.
        pub fn preflight(self: *Self, input_bytes: u64) Exhaustion!void {
            comptime requireAcquisition(Spec.acquisition.preflight, "preflight");
            try self.requireAvailable();
            const bounded = std.math.cast(usize, input_bytes) orelse
                return self.reject();
            if (bounded > self.limitBytes()) return self.reject();
        }

        /// Reads data from a stream reader into the owned buffer and admits the
        /// resulting slice if its length falls within the configured limit.
        ///
        /// This method requires `Spec.acquisition.reader` to be enabled at
        /// compile time. It requires the owner to be available in steady
        /// operation, returning `Spec.in_use_error` if an active borrow exists
        /// or `Spec.capacity_error` if the owner is terminal.
        ///
        /// The method invokes `reader.readSliceShort` over the allocated
        /// storage slice. If reading from the underlying stream returns a
        /// `ShortError` such as `ReadFailed`, that error propagates directly to
        /// the caller. A read failure can occur after writing bytes into the
        /// buffer and consuming bytes from the stream, without establishing a
        /// borrow or recording a rejection. The method promises neither buffer
        /// rollback nor stream rewind nor record framing.
        ///
        /// When reading completes without stream error, the read byte count is
        /// evaluated:
        ///
        /// * If the count is at most the configured limit, the slice
        /// `self.bytes[0..input_bytes]` is admitted. The owner records the
        /// loaded length, updates the high-water mark, sets `in_use` to `true`,
        /// and returns the borrowed slice.
        /// * If the count exceeds the configured limit, the method rejects the
        /// input. It increments the rejection counter, transitions to terminal
        /// if configured, and returns `Spec.capacity_error`.
        ///
        /// When using helper-based capacity derivation through
        /// `deriveCapacity`, an oversized input fills the `limit + 1` storage
        /// bytes and triggers a capacity rejection after reading. This consumes
        /// `limit + 1` bytes from the stream without draining trailing input.
        /// Because reader implementations may buffer additional data,
        /// subsequent reads cannot assume framing alignment with a subsequent
        /// record.
        pub fn read(
            self: *Self,
            reader: *std.Io.Reader,
        ) (Exhaustion || std.Io.Reader.ShortError)![]const u8 {
            comptime requireAcquisition(Spec.acquisition.reader, "reader");
            try self.requireAvailable();
            const input_bytes = try reader.readSliceShort(self.bytes);
            return try self.admit(input_bytes);
        }

        /// Reads a file from a directory into the bounded buffer and admits the
        /// resulting slice if the read length does not exceed the configured
        /// limit.
        ///
        /// This method requires `Spec.acquisition.file` to be enabled at
        /// compile time. It checks that the owner is available in steady
        /// operation before opening the file.
        ///
        /// Reading is executed through `dir.readFile` into the allocated buffer
        /// slice. Under the pinned standard library implementation, an ordinary
        /// oversized file fills the buffer prefix before admission rejects the
        /// input. Opening errors propagate directly, while a read error can
        /// occur after partial buffer writes and no borrow is admitted.
        ///
        /// Handling of `error.FileTooBig` depends on compile-time
        /// configuration:
        ///
        /// * When `Spec.acquisition.map_file_too_big` is `true`,
        /// `error.FileTooBig` is converted into a capacity rejection. This
        /// increments the rejection counter, transitions to terminal if
        /// configured, and returns `Spec.capacity_error`.
        /// * When `Spec.acquisition.map_file_too_big` is `false`,
        /// `error.FileTooBig` propagates directly to the caller without
        /// incrementing the rejection counter or modifying terminal state.
        ///
        /// All other filesystem I/O errors propagate directly to the caller
        /// without a capacity rejection or terminal transition under either
        /// setting. On success, the method returns a borrowed slice of the
        /// admitted bytes and marks the owner as in use.
        pub fn readFile(
            self: *Self,
            dir: std.Io.Dir,
            io: std.Io,
            file_path: []const u8,
        ) ![]const u8 {
            comptime requireAcquisition(Spec.acquisition.file, "file");
            try self.requireAvailable();
            const file = if (comptime Spec.acquisition.map_file_too_big)
                dir.readFile(io, file_path, self.bytes) catch |err| switch (err) {
                    error.FileTooBig => return self.reject(),
                    else => return err,
                }
            else
                try dir.readFile(io, file_path, self.bytes);
            return try self.admit(file.len);
        }

        /// Reads a bounded positional window from a file at a specified offset
        /// without treating trailing bytes as a capacity rejection.
        ///
        /// This method requires `Spec.acquisition.file` to be enabled at
        /// compile time. Callers must supply a window size satisfying `0 <
        /// window_bytes <= limit`, which debug assertions verify. The owner
        /// must be available in steady operation before opening the target
        /// file.
        ///
        /// The method opens the file and reads up to `window_bytes + 1` bytes
        /// at the specified offset using positional I/O into `self.bytes[0 ..
        /// window_bytes + 1]`. Any filesystem I/O error during open or read
        /// propagates directly to the caller without a capacity rejection or
        /// borrow, though the buffer may be partially written.
        ///
        /// The read byte count determines completion and admission:
        ///
        /// * If the number of read bytes is less than or equal to
        /// `window_bytes`, `complete` is set to `true`.
        /// * If reading produces `window_bytes + 1` bytes, additional data
        /// exists beyond the window, setting `complete` to `false`. This
        /// condition does not trigger a capacity rejection or modify terminal
        /// status, even on terminal owners.
        ///
        /// The method admits `@min(read_bytes, window_bytes)`, which marks the
        /// owner as in use and returns a borrowed slice. An immediate EOF
        /// returning zero bytes still establishes an admitted zero-byte borrow.
        /// The `complete` flag describes only this positional read and is not
        /// an instantaneous snapshot against concurrent modifications.
        pub fn readFileWindow(
            self: *Self,
            dir: std.Io.Dir,
            io: std.Io,
            file_path: []const u8,
            offset: u64,
            window_bytes: usize,
        ) !FileWindow {
            comptime requireAcquisition(Spec.acquisition.file, "file");
            try self.requireAvailable();
            std.debug.assert(window_bytes > 0);
            std.debug.assert(window_bytes <= self.limitBytes());
            var file = try dir.openFile(io, file_path, .{});
            defer file.close(io);
            const read_bytes = try file.readPositionalAll(
                io,
                self.bytes[0 .. window_bytes + 1],
                offset,
            );
            const complete = read_bytes <= window_bytes;
            const admitted = try self.admit(@min(read_bytes, window_bytes));
            return .{ .bytes = admitted, .complete = complete };
        }

        /// Releases an active borrow, allowing the internal buffer to be reused
        /// by future input operations.
        ///
        /// Callers must call this method only when the owner is in the
        /// `.steady` phase, holds an active borrow (`in_use` is `true`), and is
        /// not in a terminal state. Debug assertions verify these
        /// preconditions.
        ///
        /// Calling release sets `in_use` to `false` and resets `loaded_bytes`
        /// to zero. It does not overwrite or sanitize existing byte values in
        /// the buffer. Historical tracking metrics, including the high-water
        /// mark and the cumulative rejection count, remain intact across
        /// release calls.
        pub fn release(self: *Self) void {
            std.debug.assert(self.phase == .steady);
            std.debug.assert(self.in_use);
            std.debug.assert(!self.terminal);
            self.in_use = false;
            self.loaded_bytes = 0;
        }

        /// Constructs and returns a snapshot of owner metrics and lifecycle
        /// state as a `Spec.Status` structure.
        ///
        /// The method copies configured status fields by value under caller
        /// serialization. Because the owner does not use atomic operations or
        /// internal synchronization, this method does not produce a coherent
        /// snapshot across concurrent unsynchronized access.
        ///
        /// The returned snapshot contains the following fields:
        ///
        /// * `phase`: Current lifecycle phase (`.initialization`, `.steady`, or
        /// `.teardown`).
        /// * `in_use`: Boolean flag indicating whether a borrowed buffer slice
        /// is currently outstanding.
        /// * `terminal`: Present on terminal owners to indicate whether
        /// capacity exhaustion permanently sealed the owner.
        /// * Configured limit field: Configured maximum byte limit derived from
        /// capacity.
        /// * `storage_bytes`: Total declared capacity of the buffer. Because
        /// this value reflects declared specification capacity, it does not
        /// represent a live allocation measurement and remains readable after
        /// teardown.
        /// * Configured loaded field: Number of admitted bytes currently held
        /// by an active borrow. This field is zero whenever the owner is not in
        /// use.
        /// * Configured high-water field: Largest admitted byte count observed
        /// across all successful reads since initialization. Oversized inputs
        /// rejected during admission do not update this value.
        /// * Configured rejected field: Cumulative saturating count of capacity
        /// rejections.
        pub fn status(self: *const Self) Spec.Status {
            var result: Spec.Status = undefined;
            result.phase = self.phase;
            result.in_use = self.in_use;
            if (comptime @hasField(Spec.Status, "terminal")) {
                result.terminal = self.terminal;
            }
            @field(result, Spec.limit_field) = self.limitBytes();
            result.storage_bytes = self.capacity.storage_bytes;
            @field(result, Spec.loaded_field) = self.loaded_bytes;
            @field(result, Spec.high_water_field) = self.high_water_bytes;
            @field(result, Spec.rejected_field) = self.rejected_count;
            return result;
        }

        /// Deinitializes the owner and frees its allocated byte buffer using
        /// the provided allocator.
        ///
        /// Callers must supply the same allocator used for `init`. The method
        /// verifies through debug assertions that the owner has not already
        /// entered teardown and that no borrowed slice is currently in use
        /// (`in_use` is `false`).
        ///
        /// Deinitialization transitions `phase` to `.teardown`, frees the
        /// allocated memory slice, clears the internal buffer slice to empty,
        /// and resets `loaded_bytes` to zero. Callers may invoke this method
        /// while the owner is still in the `.initialization` phase to clean up
        /// resources after a failed startup sequence. Cumulative metrics and
        /// capacity declarations remain stored on the instance after
        /// deinitialization completes.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.phase != .teardown);
            std.debug.assert(!self.in_use);
            self.assertRegion();
            self.phase = .teardown;
            allocator.free(self.bytes);
            self.bytes = &.{};
            self.loaded_bytes = 0;
        }

        /// Verifies that the owner is ready to accept a new input operation.
        ///
        /// Debug assertions confirm that the owner resides in the `.steady`
        /// phase, that buffer invariants hold, and that previous loaded bytes
        /// did not exceed the limit. If the owner is marked terminal, the
        /// function returns `Spec.capacity_error` without incrementing the
        /// rejection counter. If a borrow is currently active, it returns
        /// `Spec.in_use_error` without incrementing the rejection counter. When
        /// available, debug assertions verify that `loaded_bytes` is zero.
        fn requireAvailable(self: *Self) Exhaustion!void {
            std.debug.assert(self.phase == .steady);
            self.assertRegion();
            std.debug.assert(self.loaded_bytes <= self.limitBytes());
            if (self.terminal) return Spec.capacity_error;
            if (self.in_use) return Spec.in_use_error;
            std.debug.assert(self.loaded_bytes == 0);
        }

        /// Admits a specified number of bytes into the region or rejects the
        /// payload if it exceeds the configured limit.
        ///
        /// Debug assertions verify that the owner is in steady operation
        /// without an active borrow or terminal state, and that the requested
        /// byte count does not exceed allocated storage. If `input_bytes`
        /// exceeds the configured byte limit, the function invokes `reject`.
        /// Otherwise, it marks the buffer as in use, records `loaded_bytes`,
        /// updates `high_water_bytes` if the new length exceeds previous
        /// admissions, and returns a borrowed slice over the admitted bytes.
        fn admit(self: *Self, input_bytes: usize) Exhaustion![]const u8 {
            std.debug.assert(self.phase == .steady);
            std.debug.assert(!self.in_use);
            std.debug.assert(!self.terminal);
            std.debug.assert(input_bytes <= self.capacity.storage_bytes);
            if (input_bytes > self.limitBytes()) return self.reject();
            self.in_use = true;
            self.loaded_bytes = input_bytes;
            self.high_water_bytes = @max(self.high_water_bytes, input_bytes);
            return self.bytes[0..input_bytes];
        }

        /// Records an input capacity rejection and updates owner overload
        /// state.
        ///
        /// Debug assertions verify that the owner is in steady operation, is
        /// not in use, is not already terminal, and holds zero loaded bytes. If
        /// `Spec.overload` is configured as `.terminal`, the owner enters the
        /// terminal state. The cumulative rejection counter is incremented
        /// using saturating addition, and the function returns
        /// `Spec.capacity_error`.
        fn reject(self: *Self) Exhaustion {
            std.debug.assert(self.phase == .steady);
            std.debug.assert(!self.in_use);
            std.debug.assert(!self.terminal);
            std.debug.assert(self.loaded_bytes == 0);
            self.terminal = Spec.overload == .terminal;
            self.rejected_count +|= 1;
            return Spec.capacity_error;
        }

        /// Helper function returning the configured byte limit stored on
        /// `self.capacity` using the field name defined by `Spec.limit_field`.
        fn limitBytes(self: *const Self) usize {
            return @field(self.capacity, Spec.limit_field);
        }

        /// Helper function asserting that the backing byte slice length matches
        /// `storage_bytes` and strictly exceeds the configured byte limit.
        fn assertRegion(self: *const Self) void {
            std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
            std.debug.assert(self.capacity.storage_bytes > self.limitBytes());
        }
    };
}

/// Compile-time validation helper that verifies field types for capacity
/// derivation.
///
/// The function verifies that `Limits` contains the field specified by
/// `limit_field` typed as `usize`. It also verifies that `Capacity` contains
/// both the field specified by `limit_field` and `storage_bytes`, requiring
/// each to be typed as `usize`. If any requirement is not met, compilation
/// fails with an explanatory message.
fn requireCapacityTypes(
    comptime Limits: type,
    comptime Capacity: type,
    comptime limit_field: []const u8,
) void {
    if (!@hasField(Limits, limit_field)) @compileError("Limits lacks byte limit");
    if (@FieldType(Limits, limit_field) != usize) @compileError("limit must be usize");
    if (!@hasField(Capacity, limit_field)) @compileError("Capacity lacks byte limit");
    if (@FieldType(Capacity, limit_field) != usize) @compileError("limit must be usize");
    if (!@hasField(Capacity, "storage_bytes")) @compileError("Capacity lacks storage_bytes");
    if (@FieldType(Capacity, "storage_bytes") != usize) {
        @compileError("storage_bytes must be usize");
    }
}

/// Compile-time validation helper enforcing structural requirements on the
/// `Spec` configuration type.
///
/// The function validates type signatures and configuration values:
///
/// * Delegates limit and capacity layout verification to
/// `requireCapacityTypes`.
/// * Verifies that `claim` has type `alloc_phase.capacity.Declaration`.
/// * Verifies that `in_use_error` and `capacity_error` both belong to
/// `Spec.Exhaustion`.
/// * Confirms that `Status` is a struct type possessing exactly seven fields
/// for recoverable owners or eight fields for terminal owners.
/// * Verifies presence and exact typing for `phase`
/// (`alloc_phase.capacity.Phase`), `in_use` (`bool`), `storage_bytes`
/// (`usize`), the mapped limit field (`usize`), the mapped loaded field
/// (`usize`), the mapped high-water field (`usize`), the mapped rejection field
/// (`u64`), and `terminal` (`bool`) when terminal overload is enabled.
/// * Confirms that `map_file_too_big` is enabled only when `file` acquisition
/// is active.
/// * Verifies that at least one acquisition capability (`reader` or `file`) is
/// enabled.
///
/// Validating field count, named presence, and types does not establish a
/// distinct, complete semantic mapping. Because validation does not enforce
/// that mapped names are distinct, duplicate names can leave unrelated fields
/// uninitialized.
fn requireSpec(comptime Spec: type) void {
    requireCapacityTypes(Spec.Limits, Spec.Capacity, Spec.limit_field);
    if (@TypeOf(Spec.claim) != alloc_phase.capacity.Declaration) {
        @compileError("invalid claim");
    }
    if (@TypeOf(Spec.in_use_error) != Spec.Exhaustion) @compileError("invalid in-use error");
    if (@TypeOf(Spec.capacity_error) != Spec.Exhaustion) @compileError("invalid capacity error");
    if (@typeInfo(Spec.Status) != .@"struct") @compileError("Status must be a struct");
    const field_count = @typeInfo(Spec.Status).@"struct".field_names.len;
    const expected_fields: usize = if (Spec.overload == .terminal) 8 else 7;
    if (field_count != expected_fields) @compileError("Status has unexpected fields");
    if (!@hasField(Spec.Status, "phase")) @compileError("Status lacks phase");
    if (@FieldType(Spec.Status, "phase") != alloc_phase.capacity.Phase) {
        @compileError("Status phase has invalid type");
    }
    if (!@hasField(Spec.Status, "in_use")) @compileError("Status lacks in_use");
    if (@FieldType(Spec.Status, "in_use") != bool) @compileError("Status in_use has invalid type");
    if (!@hasField(Spec.Status, Spec.limit_field)) @compileError("Status lacks byte limit");
    if (@FieldType(Spec.Status, Spec.limit_field) != usize) {
        @compileError("Status byte limit has invalid type");
    }
    if (!@hasField(Spec.Status, "storage_bytes")) @compileError("Status lacks storage_bytes");
    if (@FieldType(Spec.Status, "storage_bytes") != usize) {
        @compileError("Status storage_bytes has invalid type");
    }
    if (!@hasField(Spec.Status, Spec.loaded_field)) @compileError("Status lacks loaded bytes");
    if (@FieldType(Spec.Status, Spec.loaded_field) != usize) {
        @compileError("Status loaded bytes has invalid type");
    }
    if (!@hasField(Spec.Status, Spec.high_water_field)) @compileError("Status lacks high water");
    if (@FieldType(Spec.Status, Spec.high_water_field) != usize) {
        @compileError("Status high water has invalid type");
    }
    if (!@hasField(Spec.Status, Spec.rejected_field)) @compileError("Status lacks rejection count");
    if (@FieldType(Spec.Status, Spec.rejected_field) != u64) {
        @compileError("Status rejection count has invalid type");
    }
    if (Spec.overload == .terminal and !@hasField(Spec.Status, "terminal")) {
        @compileError("terminal Status lacks terminal field");
    }
    if (Spec.overload == .terminal and @FieldType(Spec.Status, "terminal") != bool) {
        @compileError("Status terminal has invalid type");
    }
    if (Spec.acquisition.map_file_too_big and !Spec.acquisition.file) {
        @compileError("FileTooBig mapping requires file acquisition");
    }
    if (!Spec.acquisition.reader and !Spec.acquisition.file) {
        @compileError("one-region input requires reader or file acquisition");
    }
}

/// Compile-time validation helper that verifies whether a requested acquisition
/// capability is enabled on the owner. If the capability flag is `false`,
/// compilation fails with a message identifying the unsupported operation.
fn requireAcquisition(comptime enabled: bool, comptime name: []const u8) void {
    if (!enabled) @compileError("one-region input does not support " ++ name);
}

fn testCapacity(comptime Limits: type) type {
    return struct {
        input_bytes: usize,
        storage_bytes: usize,

        pub fn derive(limits: Limits) DeriveError!@This() {
            return deriveCapacity(Limits, @This(), "input_bytes", limits);
        }
    };
}

fn testSpec(
    comptime LimitsType: type,
    comptime CapacityType: type,
    comptime StatusType: type,
    comptime overload_policy: Overload,
) type {
    return struct {
        pub const Limits = LimitsType;
        pub const Capacity = CapacityType;
        pub const Status = StatusType;
        pub const Exhaustion = error{ InputStorageInUse, InputCapacityExceeded };
        pub const DeriveError = @import("one.zig").DeriveError;
        pub const acquisition: Acquisition = .{
            .reader = true,
            .preflight = true,
        };
        pub const overload: Overload = overload_policy;
        pub const limit_field = "input_bytes";
        pub const loaded_field = "loaded_input_bytes";
        pub const high_water_field = "high_water_input_bytes";
        pub const rejected_field = "rejected_input_count";
        pub const in_use_error: Exhaustion = error.InputStorageInUse;
        pub const capacity_error: Exhaustion = error.InputCapacityExceeded;
        pub const claim: alloc_phase.capacity.Declaration = undefined;
    };
}

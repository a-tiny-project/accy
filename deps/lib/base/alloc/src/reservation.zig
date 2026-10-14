//! Object reservation with an explicit first-writer policy for capacity fields.
//! This bypasses the allocator facade's whole-object undefined fill. The backing
//! allocator may still write its storage; no paging or residency is promised.
//!
//! An object's lifetime has two ends, and each end writes the same bytes: every
//! field outside the policy's unwritten list, and nothing else. `allocate` and
//! `release` are those ends for an object that owns its allocation. `begin` and
//! `end` are the same ends for an object that lives inside storage another
//! owner holds: a field of a larger reservation, or one allocation reused
//! across lifetimes. Neither allocates or frees, so storage that outlives the
//! object keeps its address and its unwritten bytes across `end` then `begin`.
//!
//! Policies compose by containment. A parent lists a nested aggregate among its
//! unwritten fields, and the nested aggregate's own initializer calls `begin`
//! under its own policy, so each level writes its header and no level writes
//! the capacity below it.

const std = @import("std");

pub const Policy = struct {
    /// Each field needs a caller-owned first-writer and admitted-reader argument.
    /// Size checks screen accidental omissions; they do not establish that argument.
    unwritten_fields: []const []const u8,
    unwritten_field_bytes_min: usize,
    poisoned_bytes_max: usize,

    pub const Problem = enum {
        unsupported_layout,
        no_unwritten_fields,
        zero_minimum,
        unknown_field,
        duplicate_field,
        small_field,
        poisoned_remainder,
    };

    pub fn check(comptime self: Policy, comptime T: type) ?Problem {
        if (@typeInfo(T) != .@"struct") return .unsupported_layout;
        if (@typeInfo(T).@"struct".layout == .@"packed") return .unsupported_layout;
        for (@typeInfo(T).@"struct".field_attrs) |attributes| {
            if (attributes.@"comptime") return .unsupported_layout;
        }
        if (self.unwritten_fields.len == 0) return .no_unwritten_fields;
        if (self.unwritten_field_bytes_min == 0) return .zero_minimum;
        var reserved: usize = 0;
        for (self.unwritten_fields, 0..) |name, index| {
            if (!@hasField(T, name)) return .unknown_field;
            for (self.unwritten_fields[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, name)) return .duplicate_field;
            }
            const bytes = @sizeOf(@FieldType(T, name));
            if (bytes < self.unwritten_field_bytes_min) return .small_field;
            reserved += bytes;
        }
        if (@sizeOf(T) - reserved > self.poisoned_bytes_max) return .poisoned_remainder;
        return null;
    }
};

/// The caller retains the allocator owner for the entire object's lifetime and
/// releases through that same owner. Exempt fields remain unspecified until their
/// own initializer writes them. Reading them before admission is a caller defect.
/// Only disjoint struct fields are supported; packed layouts are refused.
pub fn Object(comptime T: type, comptime policy: Policy) type {
    if (policy.check(T)) |problem|
        @compileError("invalid object reservation policy: " ++ @tagName(problem));
    return struct {
        pub const storage_bytes = @sizeOf(T);
        pub const reserved_field_bytes = reserved: {
            var total: usize = 0;
            for (policy.unwritten_fields) |name| total += @sizeOf(@FieldType(T, name));
            break :reserved total;
        };
        /// Conservative bound including padding, which field assignments do not
        /// initialize. Neither padding nor an undefined field is serialized state.
        pub const poisoned_bytes_bound = storage_bytes - reserved_field_bytes;

        pub fn allocate(allocator: std.mem.Allocator) std.mem.Allocator.Error!*T {
            const bytes = allocator.rawAlloc(storage_bytes, .of(T), @returnAddress()) orelse
                return error.OutOfMemory;
            const object: *T = @ptrCast(@alignCast(bytes));
            begin(object);
            return object;
        }

        /// Field poison is this policy's diagnostic at release, independent of
        /// whether the backing allocator itself poisons or unmaps the bytes.
        pub fn release(allocator: std.mem.Allocator, object: *T) void {
            end(object);
            const bytes: [*]u8 = @ptrCast(object);
            allocator.rawFree(bytes[0..storage_bytes], .of(T), @returnAddress());
        }

        /// Starts a lifetime in storage the caller already holds, aligned for `T`
        /// and `storage_bytes` long. Every field outside the unwritten list reads as
        /// undefined afterward, so the caller's initializer assigns each one it
        /// reads. The unwritten fields keep whatever bytes the storage held: fresh
        /// pages stay untouched, and a reused object keeps its previous contents
        /// until the field's own first writer admits them. Each field is assigned
        /// where it lies, and no `T`-sized temporary is formed.
        pub fn begin(object: *T) void {
            poison(object);
        }

        /// Ends a lifetime `begin` started and leaves the storage with its owner.
        /// The caller first releases whatever the fields own, since this writes over
        /// every field outside the unwritten list. The unwritten fields are neither
        /// written nor read, so pointers into them stay addressable while the
        /// storage lives, and a later `begin` on the same object finds their bytes
        /// as this lifetime left them.
        pub fn end(object: *T) void {
            poison(object);
        }

        fn poison(object: *T) void {
            inline for (comptime std.meta.fieldNames(T)) |name| {
                if (comptime !isUnwritten(name)) @field(object, name) = undefined;
            }
        }

        fn isUnwritten(comptime name: []const u8) bool {
            for (policy.unwritten_fields) |unwritten| {
                if (std.mem.eql(u8, unwritten, name)) return true;
            }
            return false;
        }
    };
}

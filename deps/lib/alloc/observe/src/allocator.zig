const std = @import("std");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// A generic adapter wrapping a supplied backing allocator, instrumenting
/// allocation, resizing, remapping, and deallocation virtual table calls while
/// returning backing allocator outcomes unchanged. The adapter emits no
/// lifecycle records and enforces no independent memory reclamation policy.
/// Callers must keep both the adapter and its backing allocator at stable
/// memory addresses throughout use, and must ensure the installed sink can
/// handle concurrent invocations when the backing allocator is accessed across
/// multiple threads.
pub const ObservedAllocator = struct {
    backing: Allocator,
    producer_id: u64,
    producer: protocol.Producer,

    /// Initializes the adapter by storing the backing allocator handle, an
    /// explicit producer identifier, and a producer kind. The constructor
    /// always asserts that the supplied producer identifier is nonzero, even in
    /// disabled builds. Callers must therefore avoid unconditionally passing
    /// `producerId`(), which evaluates to zero when observation is disabled.
    /// Initialization emits no observation events.
    pub fn init(
        backing: Allocator,
        producer_id: u64,
        producer: protocol.Producer,
    ) ObservedAllocator {
        std.debug.assert(producer_id != 0);
        return .{
            .backing = backing,
            .producer_id = producer_id,
            .producer = producer,
        };
    }

    /// Returns an allocator interface handle borrowing a pointer to this
    /// adapter and its virtual table. The adapter and its underlying backing
    /// allocator must remain alive and at stable memory addresses for the
    /// lifetime of all issued handles. Relocating the owning adapter in memory
    /// does not update existing borrowed pointers.
    pub fn allocator(self: *ObservedAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ObservedAllocator = @ptrCast(@alignCast(context));
        var span = self.begin(.alloc, 0, 0, len, alignment, return_address);
        const result = self.backing.rawAlloc(len, alignment, return_address);
        span.finish(.{
            .address = if (result) |ptr| @intFromPtr(ptr) else 0,
            .succeeded = result != null,
        });
        return result;
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *ObservedAllocator = @ptrCast(@alignCast(context));
        var span = self.begin(
            .resize,
            @intFromPtr(memory.ptr),
            memory.len,
            new_len,
            alignment,
            return_address,
        );
        const succeeded = self.backing.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
        span.finish(.{
            .address = if (succeeded) @intFromPtr(memory.ptr) else 0,
            .succeeded = succeeded,
        });
        return succeeded;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ObservedAllocator = @ptrCast(@alignCast(context));
        var span = self.begin(
            .remap,
            @intFromPtr(memory.ptr),
            memory.len,
            new_len,
            alignment,
            return_address,
        );
        const result = self.backing.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
        span.finish(.{
            .address = if (result) |ptr| @intFromPtr(ptr) else 0,
            .succeeded = result != null,
        });
        return result;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *ObservedAllocator = @ptrCast(@alignCast(context));
        var span = self.begin(
            .free,
            @intFromPtr(memory.ptr),
            memory.len,
            0,
            alignment,
            return_address,
        );
        self.backing.rawFree(memory, alignment, return_address);
        span.finish(.{
            .address = @intFromPtr(memory.ptr),
            .succeeded = true,
        });
    }

    fn begin(
        self: *ObservedAllocator,
        operation: protocol.Operation,
        old_address: usize,
        old_len: usize,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) protocol.Span {
        return protocol.begin(
            self.producer_id,
            self.producer,
            operation,
            old_address,
            old_len,
            len,
            alignment.toByteUnits(),
            return_address,
        );
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

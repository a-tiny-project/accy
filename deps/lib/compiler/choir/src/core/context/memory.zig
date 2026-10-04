const std = @import("std");
const alloc_phase = @import("alloc_phase");
const alloc_fixed = @import("alloc_fixed");

const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = alloc_fixed.FixedBuffer;

/// The smallest alignment `Capacity.derive` accepts.
///
/// Every segment is placed under the limits' `maximum_alignment`, and the
/// storage opens with the `Memory` header, so an alignment under the
/// header's own would put the header where its own type cannot be read.
/// `derive` refuses one with `error.CapacityOverflow`.
///
/// THE FLOOR IS PUBLIC BECAUSE A CALLER STATES THE ALIGNMENT. `Memory` is
/// not one of the names `Context` re-exports, so a caller that lets a person
/// state this figure has no other way to ask what the smallest legal one is,
/// and a number copied into the caller drifts the day this one moves.
pub const minimum_alignment: Alignment = .fromByteUnits(@alignOf(Memory));

pub const Limits = struct {
    maximum_alignment: Alignment,
    configuration: Configuration,
    types: Types,
    attributes: Attributes,
    operations: Operations,
    diagnostics: Diagnostics,
    transient_bytes: usize,

    pub const Configuration = struct {
        table_bytes: usize,
        name_bytes: usize,
        interface_bytes: usize,
        transaction_bytes: usize,
    };

    pub const Types = struct {
        table_bytes: usize,
        key_bytes: usize,
        payload_bytes: usize,
    };

    pub const Attributes = struct {
        table_bytes: usize,
        payload_bytes: usize,
    };

    pub const Operations = struct {
        storage_bytes: usize,
        nested_bytes: usize,
    };

    pub const Diagnostics = struct {
        handler_bytes: usize,
        payload_bytes: usize,
    };

    /// The bytes `limits` reserves for `selected`.
    ///
    /// THE GROUPING AND THE NAMES ARE TWO VIEWS OF ONE SET OF FIGURES. The
    /// fields above are grouped by the table they size, because that is how
    /// the context is built. `Segment` names the same figures flat, because
    /// that is how a caller states one of them, how `Usage` reports it, and
    /// how an exhaustion names the one that filled. This map is the seam
    /// between the two views, and it lives here so that a segment added to
    /// the enum cannot compile until this switch answers for it.
    pub fn at(self: Limits, selected: Segment) usize {
        var held = self;
        return held.field(selected).*;
    }

    /// Replaces the bytes `self` reserves for `selected`, which is how a
    /// caller states one capacity and leaves the rest as they were.
    pub fn set(self: *Limits, selected: Segment, bytes: usize) void {
        self.field(selected).* = bytes;
    }

    fn field(self: *Limits, selected: Segment) *usize {
        return switch (selected) {
            .configuration_tables => &self.configuration.table_bytes,
            .configuration_names => &self.configuration.name_bytes,
            .configuration_interfaces => &self.configuration.interface_bytes,
            .configuration_transactions => &self.configuration.transaction_bytes,
            .type_tables => &self.types.table_bytes,
            .type_keys => &self.types.key_bytes,
            .type_payloads => &self.types.payload_bytes,
            .attribute_tables => &self.attributes.table_bytes,
            .attribute_payloads => &self.attributes.payload_bytes,
            .operation_storage => &self.operations.storage_bytes,
            .operation_nested => &self.operations.nested_bytes,
            .diagnostic_handlers => &self.diagnostics.handler_bytes,
            .diagnostic_payloads => &self.diagnostics.payload_bytes,
            .transient => &self.transient_bytes,
        };
    }

    pub const testing: Limits = .{
        .maximum_alignment = .@"64",
        .configuration = .{
            .table_bytes = 512 * 1024,
            .name_bytes = 128 * 1024,
            .interface_bytes = 512 * 1024,
            .transaction_bytes = 128 * 1024,
        },
        .types = .{
            .table_bytes = 512 * 1024,
            .key_bytes = 256 * 1024,
            .payload_bytes = 512 * 1024,
        },
        .attributes = .{
            .table_bytes = 1024 * 1024,
            .payload_bytes = 1024 * 1024,
        },
        .operations = .{
            .storage_bytes = 16 * 1024 * 1024,
            .nested_bytes = 16 * 1024 * 1024,
        },
        .diagnostics = .{
            .handler_bytes = 64 * 1024,
            .payload_bytes = 256 * 1024,
        },
        .transient_bytes = 2 * 1024 * 1024,
    };

    pub const standard: Limits = .{
        .maximum_alignment = .@"64",
        .configuration = .{
            .table_bytes = 64 * 1024,
            .name_bytes = 32 * 1024,
            .interface_bytes = 512 * 1024,
            .transaction_bytes = 64 * 1024,
        },
        .types = .{
            .table_bytes = 128 * 1024,
            .key_bytes = 128 * 1024,
            .payload_bytes = 128 * 1024,
        },
        .attributes = .{
            .table_bytes = 1024 * 1024,
            .payload_bytes = 256 * 1024,
        },
        .operations = .{
            .storage_bytes = 8 * 1024 * 1024,
            .nested_bytes = 8 * 1024 * 1024,
        },
        .diagnostics = .{
            .handler_bytes = 16 * 1024,
            .payload_bytes = 128 * 1024,
        },
        .transient_bytes = 256 * 1024,
    };
};

/// The largest total a context's storage may come to.
///
/// A JUDGEMENT WITH AN ARGUMENT, NOT A MEASUREMENT OF ONE ALLOCATOR. An
/// allocator may add a header to a request, round it to a page, and count the
/// request itself more than once before it answers. `ArenaAllocator` counts it
/// twice: its fast path has already advanced the node's end index by the
/// request by the time it reaches
/// `mem.alignForward(usize, @sizeOf(Node) + aligned_index + n, 2)`, so the sum
/// it forms there is the request twice over plus what the arena already holds.
/// A quarter of the address space leaves the other three quarters for that
/// second copy, for everything the allocator holds, and for its own header. A
/// half does not: half aborts on a warm arena where a page below half answers
/// null, and a page below half is a measurement of one arena at one warmth
/// rather than a figure, since the slack a page buys is spent once the arena
/// holds more than a page. Exhausting a quarter would take an allocator
/// already holding eight exbibytes, which no host grants.
///
/// No host grants a total this large either. On a 64-bit `usize` it is more
/// than a hundred billion times the total `Limits.testing` states, which is
/// the larger of the two presets this file carries. On a 32-bit `usize` the
/// quarter comes to one byte under a gibibyte, which is still more than
/// twenty-six times that same total and is a quarter of everything such a
/// host can address at all. Refusing at or above the figure denies no caller
/// anything on either width. Past the edge an allocator's behaviour
/// is its own business and not something this library can read:
/// `std.mem.Allocator.rawAlloc` is documented to answer null when it cannot
/// allocate, and an allocator that aborts instead does so on state this
/// library cannot see, since the same figure a fresh `ArenaAllocator` refuses
/// cleanly aborts one that already holds a node.
///
/// The figure is pinned from below rather than derived: a test places the
/// largest limits this admits into a warm arena and holds that `Context.init`
/// answers `error.OutOfMemory` and never aborts. That test is what fails the
/// day an allocator's growth changes, which is the only derivation that stays
/// true.
pub const maximum_storage_bytes: usize = std.math.maxInt(usize) / 4;

/// Which stated figure `derive` cannot place, what was asked for, and the
/// largest that segment could have taken.
///
/// `largest` IS READ IN `derive`'s PLACEMENT ORDER. It is the most this
/// segment could have taken GIVEN THE SEGMENTS PLACED BEFORE IT, so it is the
/// answer to "write this figure instead" and not a property of the segment on
/// its own. A caller that lowers an earlier segment raises this one.
pub const Refusal = struct {
    segment: Segment,
    stated: usize,
    largest: usize,
};

/// The first segment figure `derive` cannot place, or null when every one
/// fits.
///
/// ALLOCATION FREE AND SIDE EFFECT FREE, so a caller asks before it builds
/// anything and says the sentence in its own words, with the segment, the
/// figure stated and the figure that would be admitted.
///
/// IT ANSWERS ABOUT THE FIGURES AND NOT THE ALIGNMENT. `derive` also refuses
/// an alignment under `minimum_alignment`, which is public for exactly that
/// reason and which a caller checks against directly. Given an alignment
/// `derive` accepts, `derive` answers `error.CapacityOverflow` exactly when
/// this answers non-null: a partial sum that would wrap has already crossed
/// half the address space, so `maximum_storage_bytes` subsumes the arithmetic
/// every `place` performs and no sum inside `derive` can fail once this has
/// passed.
pub fn refusal(limits: Limits) ?Refusal {
    const alignment = limits.maximum_alignment.toByteUnits();
    if (alignment < @alignOf(Memory)) return null;
    var cursor: usize = @sizeOf(Memory);
    for (std.enums.values(Segment)) |selected| {
        const stated = limits.at(selected);
        const offset = alignedWithin(cursor, alignment) orelse
            return .{ .segment = selected, .stated = stated, .largest = 0 };
        const largest = maximum_storage_bytes - offset;
        if (stated > largest) return .{ .segment = selected, .stated = stated, .largest = largest };
        cursor = offset + stated;
    }
    return null;
}

/// `cursor` rounded up to `alignment`, or null when that lands at or past
/// `maximum_storage_bytes`. `cursor` is at most the ceiling on entry, so the
/// rounding itself cannot wrap.
fn alignedWithin(cursor: usize, alignment: usize) ?usize {
    std.debug.assert(cursor <= maximum_storage_bytes);
    std.debug.assert(alignment != 0);
    if (alignment > maximum_storage_bytes) return null;
    const mask = alignment - 1;
    if (cursor > maximum_storage_bytes - mask) return null;
    const offset = (cursor + mask) & ~mask;
    if (offset > maximum_storage_bytes) return null;
    return offset;
}

pub const Segment = enum {
    configuration_tables,
    configuration_names,
    configuration_interfaces,
    configuration_transactions,
    type_tables,
    type_keys,
    type_payloads,
    attribute_tables,
    attribute_payloads,
    operation_storage,
    operation_nested,
    diagnostic_handlers,
    diagnostic_payloads,
    transient,
};

/// Which segment a request found full, and how many bytes it asked for.
///
/// The limit and the bytes in use at that moment are the segment's own
/// `SegmentUsage`, so a caller that reports an exhaustion reads all four
/// figures without this type repeating two of them.
pub const Exhausted = struct {
    segment: Segment,
    requested_bytes: usize,
};

pub const SegmentUsage = struct {
    frontier_bytes: usize,
    reserved_bytes: usize,

    pub fn remainingBytes(self: SegmentUsage) usize {
        return self.reserved_bytes - self.frontier_bytes;
    }
};

pub const Usage = struct {
    configuration_tables: SegmentUsage,
    configuration_names: SegmentUsage,
    configuration_interfaces: SegmentUsage,
    configuration_transactions: SegmentUsage,
    type_tables: SegmentUsage,
    type_keys: SegmentUsage,
    type_payloads: SegmentUsage,
    attribute_tables: SegmentUsage,
    attribute_payloads: SegmentUsage,
    operation_storage: SegmentUsage,
    operation_nested: SegmentUsage,
    diagnostic_handlers: SegmentUsage,
    diagnostic_payloads: SegmentUsage,
    transient: SegmentUsage,

    pub fn get(self: Usage, selected: Segment) SegmentUsage {
        return switch (selected) {
            inline else => |segment_name| @field(self, @tagName(segment_name)),
        };
    }
};

const SegmentAllocator = struct {
    fixed: FixedBufferAllocator,
    buffer: []u8,
    exhausted_segment: *?Segment,
    exhausted_request: *usize,
    segment_name: Segment,

    fn init(buffer: []u8, memory: *Memory, segment_name: Segment) SegmentAllocator {
        return .{
            .fixed = FixedBufferAllocator.init(buffer),
            .buffer = buffer,
            .exhausted_segment = &memory.exhausted_segment,
            .exhausted_request = &memory.exhausted_request,
            .segment_name = segment_name,
        };
    }

    pub fn allocator(self: *SegmentAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *SegmentAllocator = @ptrCast(@alignCast(context));
        const result = self.fixed.allocator().rawAlloc(len, alignment, return_address);
        if (result == null) self.recordExhaustion(len);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *SegmentAllocator = @ptrCast(@alignCast(context));
        return self.fixed.allocator().rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *SegmentAllocator = @ptrCast(@alignCast(context));
        return self.fixed.allocator().rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *SegmentAllocator = @ptrCast(@alignCast(context));
        self.fixed.allocator().rawFree(memory, alignment, return_address);
    }

    fn recordExhaustion(self: *SegmentAllocator, requested_bytes: usize) void {
        self.exhausted_segment.* = self.segment_name;
        self.exhausted_request.* = requested_bytes;
    }
};

pub const Capacity = struct {
    storage_bytes: usize,
    storage_alignment: Alignment,
    memory: Slice,
    configuration_tables: Slice,
    configuration_names: Slice,
    configuration_interfaces: Slice,
    configuration_transactions: Slice,
    type_tables: Slice,
    type_keys: Slice,
    type_payloads: Slice,
    attribute_tables: Slice,
    attribute_payloads: Slice,
    operation_storage: Slice,
    operation_nested: Slice,
    diagnostic_handlers: Slice,
    diagnostic_payloads: Slice,
    transient: Slice,

    pub const Slice = struct {
        offset: usize,
        bytes: usize,
    };

    pub fn asLimits(self: Capacity) Limits {
        return .{
            .maximum_alignment = self.storage_alignment,
            .configuration = .{
                .table_bytes = self.configuration_tables.bytes,
                .name_bytes = self.configuration_names.bytes,
                .interface_bytes = self.configuration_interfaces.bytes,
                .transaction_bytes = self.configuration_transactions.bytes,
            },
            .types = .{
                .table_bytes = self.type_tables.bytes,
                .key_bytes = self.type_keys.bytes,
                .payload_bytes = self.type_payloads.bytes,
            },
            .attributes = .{
                .table_bytes = self.attribute_tables.bytes,
                .payload_bytes = self.attribute_payloads.bytes,
            },
            .operations = .{
                .storage_bytes = self.operation_storage.bytes,
                .nested_bytes = self.operation_nested.bytes,
            },
            .diagnostics = .{
                .handler_bytes = self.diagnostic_handlers.bytes,
                .payload_bytes = self.diagnostic_payloads.bytes,
            },
            .transient_bytes = self.transient.bytes,
        };
    }

    pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
        const requested_alignment = limits.maximum_alignment.toByteUnits();
        if (requested_alignment < @alignOf(Memory)) return error.CapacityOverflow;
        if (refusal(limits) != null) return error.CapacityOverflow;
        var cursor: usize = 0;
        const memory = try place(@sizeOf(Memory), @alignOf(Memory), &cursor);
        const configuration_tables = try place(limits.configuration.table_bytes, requested_alignment, &cursor);
        const configuration_names = try place(limits.configuration.name_bytes, requested_alignment, &cursor);
        const configuration_interfaces = try place(limits.configuration.interface_bytes, requested_alignment, &cursor);
        const configuration_transactions = try place(limits.configuration.transaction_bytes, requested_alignment, &cursor);
        const type_tables = try place(limits.types.table_bytes, requested_alignment, &cursor);
        const type_keys = try place(limits.types.key_bytes, requested_alignment, &cursor);
        const type_payloads = try place(limits.types.payload_bytes, requested_alignment, &cursor);
        const attribute_tables = try place(limits.attributes.table_bytes, requested_alignment, &cursor);
        const attribute_payloads = try place(limits.attributes.payload_bytes, requested_alignment, &cursor);
        const operation_storage = try place(limits.operations.storage_bytes, requested_alignment, &cursor);
        const operation_nested = try place(limits.operations.nested_bytes, requested_alignment, &cursor);
        const diagnostic_handlers = try place(limits.diagnostics.handler_bytes, requested_alignment, &cursor);
        const diagnostic_payloads = try place(limits.diagnostics.payload_bytes, requested_alignment, &cursor);
        const transient = try place(limits.transient_bytes, requested_alignment, &cursor);
        return .{
            .storage_bytes = cursor,
            .storage_alignment = limits.maximum_alignment,
            .memory = memory,
            .configuration_tables = configuration_tables,
            .configuration_names = configuration_names,
            .configuration_interfaces = configuration_interfaces,
            .configuration_transactions = configuration_transactions,
            .type_tables = type_tables,
            .type_keys = type_keys,
            .type_payloads = type_payloads,
            .attribute_tables = attribute_tables,
            .attribute_payloads = attribute_payloads,
            .operation_storage = operation_storage,
            .operation_nested = operation_nested,
            .diagnostic_handlers = diagnostic_handlers,
            .diagnostic_payloads = diagnostic_payloads,
            .transient = transient,
        };
    }
};

pub const Memory = struct {
    exhausted_segment: ?Segment,
    /// The size of the request that found `exhausted_segment` full. It is
    /// read only beside that segment, through `exhaustion`.
    exhausted_request: usize,
    configuration_tables: SegmentAllocator,
    configuration_names: SegmentAllocator,
    configuration_interfaces: SegmentAllocator,
    configuration_transactions: SegmentAllocator,
    type_tables: SegmentAllocator,
    type_keys: SegmentAllocator,
    type_payloads: SegmentAllocator,
    attribute_tables: SegmentAllocator,
    attribute_payloads: SegmentAllocator,
    operation_storage: SegmentAllocator,
    operation_nested: SegmentAllocator,
    diagnostic_handlers: SegmentAllocator,
    diagnostic_payloads: SegmentAllocator,
    transient: SegmentAllocator,

    pub fn init(storage: [*]u8, capacity: Capacity) *Memory {
        const self: *Memory = @ptrCast(@alignCast(storage + capacity.memory.offset));
        self.exhausted_segment = null;
        self.exhausted_request = 0;
        self.configuration_tables = SegmentAllocator.init(segment(storage, capacity.configuration_tables), self, .configuration_tables);
        self.configuration_names = SegmentAllocator.init(segment(storage, capacity.configuration_names), self, .configuration_names);
        self.configuration_interfaces = SegmentAllocator.init(segment(storage, capacity.configuration_interfaces), self, .configuration_interfaces);
        self.configuration_transactions = SegmentAllocator.init(segment(storage, capacity.configuration_transactions), self, .configuration_transactions);
        self.type_tables = SegmentAllocator.init(segment(storage, capacity.type_tables), self, .type_tables);
        self.type_keys = SegmentAllocator.init(segment(storage, capacity.type_keys), self, .type_keys);
        self.type_payloads = SegmentAllocator.init(segment(storage, capacity.type_payloads), self, .type_payloads);
        self.attribute_tables = SegmentAllocator.init(segment(storage, capacity.attribute_tables), self, .attribute_tables);
        self.attribute_payloads = SegmentAllocator.init(segment(storage, capacity.attribute_payloads), self, .attribute_payloads);
        self.operation_storage = SegmentAllocator.init(segment(storage, capacity.operation_storage), self, .operation_storage);
        self.operation_nested = SegmentAllocator.init(segment(storage, capacity.operation_nested), self, .operation_nested);
        self.diagnostic_handlers = SegmentAllocator.init(segment(storage, capacity.diagnostic_handlers), self, .diagnostic_handlers);
        self.diagnostic_payloads = SegmentAllocator.init(segment(storage, capacity.diagnostic_payloads), self, .diagnostic_payloads);
        self.transient = SegmentAllocator.init(segment(storage, capacity.transient), self, .transient);
        return self;
    }

    pub fn usage(self: *const Memory) Usage {
        return .{
            .configuration_tables = segmentUsage(&self.configuration_tables),
            .configuration_names = segmentUsage(&self.configuration_names),
            .configuration_interfaces = segmentUsage(&self.configuration_interfaces),
            .configuration_transactions = segmentUsage(&self.configuration_transactions),
            .type_tables = segmentUsage(&self.type_tables),
            .type_keys = segmentUsage(&self.type_keys),
            .type_payloads = segmentUsage(&self.type_payloads),
            .attribute_tables = segmentUsage(&self.attribute_tables),
            .attribute_payloads = segmentUsage(&self.attribute_payloads),
            .operation_storage = segmentUsage(&self.operation_storage),
            .operation_nested = segmentUsage(&self.operation_nested),
            .diagnostic_handlers = segmentUsage(&self.diagnostic_handlers),
            .diagnostic_payloads = segmentUsage(&self.diagnostic_payloads),
            .transient = segmentUsage(&self.transient),
        };
    }

    pub fn exhaustion(self: *const Memory) ?Exhausted {
        const segment_name = self.exhausted_segment orelse return null;
        return .{ .segment = segment_name, .requested_bytes = self.exhausted_request };
    }

    pub fn hasCapacity(
        self: *const Memory,
        selected: Segment,
        bytes: usize,
        alignment: Alignment,
    ) bool {
        const allocator = switch (selected) {
            inline else => |segment_name| &@field(self, @tagName(segment_name)),
        };
        const offset = std.mem.alignPointerOffset(
            allocator.buffer.ptr + alloc_fixed.used(&allocator.fixed),
            alignment.toByteUnits(),
        ) orelse return false;
        const aligned = std.math.add(usize, alloc_fixed.used(&allocator.fixed), offset) catch return false;
        const end = std.math.add(usize, aligned, bytes) catch return false;
        return end <= allocator.buffer.len;
    }
};

pub fn cast(memory_pointer: *anyopaque) *Memory {
    return @ptrCast(@alignCast(memory_pointer));
}

pub fn segmentAllocator(context: anytype, selected: Segment) Allocator {
    if (comptime @hasField(@TypeOf(context.*), "memory")) {
        const memory = cast(context.memory);
        return switch (selected) {
            inline else => |segment_name| @field(memory, @tagName(segment_name)).allocator(),
        };
    }
    return context.allocator;
}

pub fn configurationTableAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).configuration_tables.allocator();
}

pub fn configurationNameAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).configuration_names.allocator();
}

pub fn configurationInterfaceAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).configuration_interfaces.allocator();
}

pub fn configurationTransactionAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).configuration_transactions.allocator();
}

pub fn typeTableAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).type_tables.allocator();
}

pub fn typeKeyAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).type_keys.allocator();
}

pub fn typePayloadAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).type_payloads.allocator();
}

pub fn attributeTableAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).attribute_tables.allocator();
}

pub fn attributePayloadAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).attribute_payloads.allocator();
}

pub fn operationStorageAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).operation_storage.allocator();
}

pub fn operationNestedAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).operation_nested.allocator();
}

pub fn diagnosticHandlerAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).diagnostic_handlers.allocator();
}

pub fn diagnosticPayloadAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).diagnostic_payloads.allocator();
}

pub fn transientAllocator(memory_pointer: *anyopaque) Allocator {
    return cast(memory_pointer).transient.allocator();
}

fn place(bytes: usize, alignment: usize, cursor: *usize) error{CapacityOverflow}!Capacity.Slice {
    const mask = std.math.sub(usize, alignment, 1) catch return error.CapacityOverflow;
    const padded = std.math.add(usize, cursor.*, mask) catch return error.CapacityOverflow;
    const offset = padded & ~mask;
    cursor.* = std.math.add(usize, offset, bytes) catch return error.CapacityOverflow;
    return .{ .offset = offset, .bytes = bytes };
}

fn segment(storage: [*]u8, capacity: Capacity.Slice) []u8 {
    return (storage + capacity.offset)[0..capacity.bytes];
}

fn segmentUsage(allocator: *const SegmentAllocator) SegmentUsage {
    return .{
        .frontier_bytes = alloc_fixed.used(&allocator.fixed),
        .reserved_bytes = allocator.buffer.len,
    };
}

/// Limits whose every segment states `bytes`, under the testing alignment, so
/// a test can move one figure and leave the rest flat.
fn flatLimits(bytes: usize) Limits {
    var limits = Limits.testing;
    for (std.enums.values(Segment)) |selected| limits.set(selected, bytes);
    return limits;
}

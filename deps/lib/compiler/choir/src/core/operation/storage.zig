const std = @import("std");
const alloc_observe = @import("alloc_observe");
const alloc_phase = @import("alloc_phase");

const Allocator = std.mem.Allocator;
const pool_items_per_chunk: usize = 32;

pub const Handle = struct {
    bytes: [*]u8,
    len: usize,
    alignment: std.mem.Alignment,

    pub fn deinit(self: *Handle, allocator: Allocator) void {
        allocator.rawFree(self.bytes[0..self.len], self.alignment, @returnAddress());
        self.* = undefined;
    }
};

const segment_count: usize = 8;

pub const Storage = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.operation_fixed_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "one_exact_operation_header_with_context_tracking_li_8dbfeaab8a9b",
                        .lifetime = .steady,
                        .detail = "one exact Operation header with context tracking links and initial structural region",
                    },
                    .{
                        .id = "initial_operand_values_result_types_use_records_val_dfde1e9abc4c",
                        .lifetime = .steady,
                        .detail = "initial operand values, result types, use records, values, regions, and successors",
                    },
                    .{
                        .id = "exact_registered_property_bytes_embedded_in_the_str_4e71d9c026ef",
                        .lifetime = .steady,
                        .detail = "exact registered property bytes embedded in the structural region",
                    },
                },
                .excluded = &.{
                    "attributes, nested property allocations, blocks, and region contents",
                    "later operand and successor replacement spill storage",
                    "profiling instrumentation and allocator implementation state",
                },
            },
            .capacity = .{
                .inputs = &.{},
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .constant = 0 },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 0,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "capacity arithmetic or allocation failure returns before the Operation header is initialized or storage is sealed",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "the parent mutable Operation retains allocator authority for explicitly excluded attributes, nested owners, and later spills",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "dialect property hooks may traverse state outside the embedded property byte region",
                },
            },
            .obligations = &.{
                .{ .key = "choir_operation_storage_capacity", .role = .capacity_model },
                .{ .key = "choir_operation_storage_acquisition", .role = .custom },
                .{ .key = "choir_operation_storage_boundary", .role = .overload },
                .{ .key = "choir_operation_storage_oom", .role = .overload },
                .{ .key = "choir_operation_storage_integration", .role = .custom },
                .{ .key = "choir_operation_tracking_static", .role = .custom },
                .{ .key = "choir_operation_storage_spill", .role = .custom },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub const Segment = struct {
        count: usize,
        element_bytes: usize,
        alignment: std.mem.Alignment,
    };

    pub const Limits = struct {
        segments: [segment_count]Segment,
    };

    pub const Capacity = struct {
        total_bytes: usize,
        allocation_alignment: std.mem.Alignment,

        pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
            var cursor: usize = 0;
            var alignment: usize = 1;
            for (limits.segments) |segment| {
                const bytes = std.math.mul(
                    usize,
                    segment.count,
                    segment.element_bytes,
                ) catch return error.CapacityOverflow;
                _ = try placeBytes(
                    bytes,
                    segment.alignment.toByteUnits(),
                    &cursor,
                    &alignment,
                );
            }
            return .{
                .total_bytes = cursor,
                .allocation_alignment = .fromByteUnits(alignment),
            };
        }
    };

    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    bytes: [*]u8,

    pub fn init(allocator: Allocator, limits: Limits) !Storage {
        const capacity = try Capacity.derive(limits);
        const bytes = allocator.rawAlloc(
            capacity.total_bytes,
            capacity.allocation_alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .bytes = bytes,
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    pub fn status(self: *const Storage) alloc_phase.capacity.Phase {
        return self.phase;
    }

    pub fn deinit(self: *Storage, allocator: Allocator) void {
        std.debug.assert(self.phase != .teardown);
        self.phase = .teardown;
        var handle = self.storageHandle();
        handle.deinit(allocator);
        self.* = undefined;
    }

    fn storageHandle(self: *const Storage) Handle {
        return .{
            .bytes = self.bytes,
            .len = self.capacity.total_bytes,
            .alignment = self.capacity.allocation_alignment,
        };
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(Storage);
}

pub fn PoolAllocator(
    comptime first_capacity: Storage.Capacity,
    comptime second_capacity: Storage.Capacity,
    comptime third_capacity: Storage.Capacity,
    comptime fourth_capacity: Storage.Capacity,
) type {
    comptime {
        std.debug.assert(first_capacity.total_bytes != second_capacity.total_bytes);
        std.debug.assert(first_capacity.total_bytes != third_capacity.total_bytes);
        std.debug.assert(first_capacity.total_bytes != fourth_capacity.total_bytes);
        std.debug.assert(second_capacity.total_bytes != third_capacity.total_bytes);
        std.debug.assert(second_capacity.total_bytes != fourth_capacity.total_bytes);
        std.debug.assert(third_capacity.total_bytes != fourth_capacity.total_bytes);
    }

    const FirstPool = FixedPool(first_capacity);
    const SecondPool = FixedPool(second_capacity);
    const ThirdPool = FixedPool(third_capacity);
    const FourthPool = FixedPool(fourth_capacity);
    return struct {
        backing: Allocator,
        first: FirstPool = .{},
        second: SecondPool = .{},
        third: ThirdPool = .{},
        fourth: FourthPool = .{},
        observation_id: if (alloc_observe.enabled) u64 else void,

        const Self = @This();
        const Class = enum { first, second, third, fourth };
        pub const items_per_chunk: usize = pool_items_per_chunk;
        pub const first_chunk_bytes: usize = FirstPool.chunk_bytes;
        pub const second_chunk_bytes: usize = SecondPool.chunk_bytes;
        pub const third_chunk_bytes: usize = ThirdPool.chunk_bytes;
        pub const fourth_chunk_bytes: usize = FourthPool.chunk_bytes;

        pub fn init(backing: Allocator) Self {
            return .{
                .backing = backing,
                .observation_id = if (comptime alloc_observe.enabled)
                    alloc_observe.producerId()
                else {},
            };
        }

        pub fn deinit(self: *Self) void {
            self.first.deinit(self.backing);
            self.second.deinit(self.backing);
            self.third.deinit(self.backing);
            self.fourth.deinit(self.backing);
            self.* = undefined;
        }

        pub fn allocator(self: *Self) Allocator {
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
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            var span = self.begin(.alloc, 0, 0, len, alignment, ret_addr);
            const result = if (classify(len, alignment)) |class| switch (class) {
                .first => self.first.create(self.backing) catch null,
                .second => self.second.create(self.backing) catch null,
                .third => self.third.create(self.backing) catch null,
                .fourth => self.fourth.create(self.backing) catch null,
            } else self.backing.rawAlloc(len, alignment, ret_addr);
            span.finish(.{
                .address = if (result) |ptr| @intFromPtr(ptr) else 0,
                .succeeded = result != null,
            });
            return result;
        }

        fn begin(
            self: *const Self,
            operation: alloc_observe.Operation,
            old_address: usize,
            old_len: usize,
            len: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) alloc_observe.Span {
            return alloc_observe.begin(
                if (comptime alloc_observe.enabled) self.observation_id else 0,
                .pool,
                operation,
                old_address,
                old_len,
                len,
                alignment.toByteUnits(),
                ret_addr,
            );
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            var span = self.begin(
                .resize,
                @intFromPtr(memory.ptr),
                memory.len,
                new_len,
                alignment,
                ret_addr,
            );
            const succeeded = if (memory.len == new_len)
                true
            else if (isClassLength(memory.len) or isClassLength(new_len))
                false
            else
                self.backing.rawResize(memory, alignment, new_len, ret_addr);
            span.finish(.{
                .address = if (succeeded) @intFromPtr(memory.ptr) else 0,
                .succeeded = succeeded,
            });
            return succeeded;
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            var span = self.begin(
                .remap,
                @intFromPtr(memory.ptr),
                memory.len,
                new_len,
                alignment,
                ret_addr,
            );
            const result = if (memory.len == new_len)
                memory.ptr
            else if (isClassLength(memory.len) or isClassLength(new_len))
                null
            else
                self.backing.rawRemap(memory, alignment, new_len, ret_addr);
            span.finish(.{
                .address = if (result) |ptr| @intFromPtr(ptr) else 0,
                .succeeded = result != null,
            });
            return result;
        }

        fn free(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            const self: *Self = @ptrCast(@alignCast(context));
            var span = self.begin(
                .free,
                @intFromPtr(memory.ptr),
                memory.len,
                0,
                alignment,
                ret_addr,
            );
            if (classify(memory.len, alignment)) |class| {
                switch (class) {
                    .first => self.first.destroy(memory.ptr),
                    .second => self.second.destroy(memory.ptr),
                    .third => self.third.destroy(memory.ptr),
                    .fourth => self.fourth.destroy(memory.ptr),
                }
            } else {
                self.backing.rawFree(memory, alignment, ret_addr);
            }
            span.finish(.{
                .address = @intFromPtr(memory.ptr),
                .succeeded = true,
            });
        }

        fn classify(len: usize, alignment: std.mem.Alignment) ?Class {
            if (len == first_capacity.total_bytes and
                alignment.compare(.lte, first_capacity.allocation_alignment)) return .first;
            if (len == second_capacity.total_bytes and
                alignment.compare(.lte, second_capacity.allocation_alignment)) return .second;
            if (len == third_capacity.total_bytes and
                alignment.compare(.lte, third_capacity.allocation_alignment)) return .third;
            if (len == fourth_capacity.total_bytes and
                alignment.compare(.lte, fourth_capacity.allocation_alignment)) return .fourth;
            return null;
        }

        fn isClassLength(len: usize) bool {
            return len == first_capacity.total_bytes or
                len == second_capacity.total_bytes or
                len == third_capacity.total_bytes or
                len == fourth_capacity.total_bytes;
        }
    };
}

fn FixedPool(comptime capacity: Storage.Capacity) type {
    const alignment = capacity.allocation_alignment.toByteUnits();
    comptime {
        std.debug.assert(capacity.total_bytes >= @sizeOf(?*anyopaque));
        std.debug.assert(alignment >= @alignOf(?*anyopaque));
    }

    return struct {
        chunks: ?*Chunk = null,
        free_list: ?*FreeNode = null,

        const Self = @This();
        const Slot = struct {
            bytes: [capacity.total_bytes]u8 align(alignment),
        };
        const Chunk = struct {
            next: ?*Chunk,
            used: usize,
            slots: [pool_items_per_chunk]Slot,
        };
        const FreeNode = struct {
            next: ?*FreeNode,
        };
        const chunk_bytes: usize = @sizeOf(Chunk);

        comptime {
            std.debug.assert(@sizeOf(Slot) == std.mem.alignForward(usize, capacity.total_bytes, alignment));
            std.debug.assert(@sizeOf(Slot) >= capacity.total_bytes);
            std.debug.assert(@alignOf(Slot) == alignment);
        }

        fn create(self: *Self, allocator: Allocator) Allocator.Error![*]u8 {
            if (self.free_list) |node| {
                self.free_list = node.next;
                const slot: *Slot = @ptrCast(@alignCast(node));
                slot.* = undefined;
                return @ptrCast(slot);
            }

            const chunk = self.chunks orelse return try self.addChunk(allocator);
            if (chunk.used == pool_items_per_chunk) return try self.addChunk(allocator);
            const slot = &chunk.slots[chunk.used];
            chunk.used += 1;
            slot.* = undefined;
            return @ptrCast(slot);
        }

        fn destroy(self: *Self, bytes: [*]u8) void {
            const slot: *Slot = @ptrCast(@alignCast(bytes));
            slot.* = undefined;
            const node: *FreeNode = @ptrCast(slot);
            node.* = .{ .next = self.free_list };
            self.free_list = node;
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            var chunk = self.chunks;
            while (chunk) |current| {
                chunk = current.next;
                allocator.destroy(current);
            }
            self.* = undefined;
        }

        fn addChunk(self: *Self, allocator: Allocator) Allocator.Error![*]u8 {
            const chunk = try allocator.create(Chunk);
            chunk.* = .{
                .next = self.chunks,
                .used = 1,
                .slots = undefined,
            };
            self.chunks = chunk;
            const slot = &chunk.slots[0];
            slot.* = undefined;
            return @ptrCast(slot);
        }
    };
}

pub fn List(comptime T: type) type {
    return struct {
        items: []T = &.{},
        capacity: usize = 0,

        const Self = @This();

        pub fn init(storage: []T) Self {
            if (storage.len == 0) return .{};
            return .{ .items = storage[0..0], .capacity = storage.len };
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.items.len < self.capacity);
            const index = self.items.len;
            const next_len = std.math.add(usize, index, 1) catch unreachable;
            self.items = self.items.ptr[0..next_len];
            self.items[index] = item;
        }

        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            const remaining = std.math.sub(usize, self.capacity, self.items.len) catch unreachable;
            std.debug.assert(items.len <= remaining);
            const previous_len = self.items.len;
            const next_len = std.math.add(usize, previous_len, items.len) catch unreachable;
            self.items = self.items.ptr[0..next_len];
            @memcpy(self.items[previous_len..], items);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.items = self.items.ptr[0..0];
        }
    };
}

pub fn Plan(
    comptime Header: type,
    comptime OperandValue: type,
    comptime ResultType: type,
    comptime Operand: type,
    comptime Result: type,
    comptime Region: type,
    comptime Successor: type,
) type {
    return struct {
        pub const Limits = struct {
            operands: usize,
            results: usize,
            regions: usize,
            successors: usize,
            properties: usize,
            properties_alignment: std.mem.Alignment,
        };

        pub const Capacity = struct {
            pub fn derive(limits: Limits) error{CapacityOverflow}!Storage.Capacity {
                return try Storage.Capacity.derive(storageLimits(limits));
            }
        };

        const Layout = struct {
            operands: usize,
            results: usize,
            regions: usize,
            successors: usize,
            properties: usize,
            header_offset: usize,
            operand_values_offset: usize,
            result_types_offset: usize,
            operands_offset: usize,
            results_offset: usize,
            regions_offset: usize,
            successors_offset: usize,
            properties_offset: usize,
            total_bytes: usize,
            allocation_alignment: std.mem.Alignment,

            fn derive(limits: Limits) error{CapacityOverflow}!Layout {
                var cursor: usize = 0;
                var alignment: usize = 1;
                const header_offset = try place(Header, 1, &cursor, &alignment);
                const operand_values_offset = try place(OperandValue, limits.operands, &cursor, &alignment);
                const result_types_offset = try place(ResultType, limits.results, &cursor, &alignment);
                const operands_offset = try place(Operand, limits.operands, &cursor, &alignment);
                const results_offset = try place(Result, limits.results, &cursor, &alignment);
                const regions_offset = try place(Region, limits.regions, &cursor, &alignment);
                const successors_offset = try place(Successor, limits.successors, &cursor, &alignment);
                const properties_offset = try placeBytes(
                    limits.properties,
                    limits.properties_alignment.toByteUnits(),
                    &cursor,
                    &alignment,
                );
                return .{
                    .operands = limits.operands,
                    .results = limits.results,
                    .regions = limits.regions,
                    .successors = limits.successors,
                    .properties = limits.properties,
                    .header_offset = header_offset,
                    .operand_values_offset = operand_values_offset,
                    .result_types_offset = result_types_offset,
                    .operands_offset = operands_offset,
                    .results_offset = results_offset,
                    .regions_offset = regions_offset,
                    .successors_offset = successors_offset,
                    .properties_offset = properties_offset,
                    .total_bytes = cursor,
                    .allocation_alignment = .fromByteUnits(alignment),
                };
            }
        };

        pub const Regions = struct {
            header: *Header,
            operand_values: []OperandValue,
            result_types: []ResultType,
            operands: []Operand,
            results: []Result,
            regions: []Region,
            successors: []Successor,
            properties: []u8,
        };

        pub const Allocation = struct {
            storage: Storage,
            regions: Regions,
        };

        pub fn init(allocator: Allocator, limits: Limits) !Allocation {
            var storage = try Storage.init(allocator, storageLimits(limits));
            errdefer storage.deinit(allocator);
            return .{
                .storage = storage,
                .regions = try acquire(&storage, limits),
            };
        }

        fn storageLimits(limits: Limits) Storage.Limits {
            return .{ .segments = .{
                .{ .count = 1, .element_bytes = @sizeOf(Header), .alignment = .fromByteUnits(@alignOf(Header)) },
                .{ .count = limits.operands, .element_bytes = @sizeOf(OperandValue), .alignment = .fromByteUnits(@alignOf(OperandValue)) },
                .{ .count = limits.results, .element_bytes = @sizeOf(ResultType), .alignment = .fromByteUnits(@alignOf(ResultType)) },
                .{ .count = limits.operands, .element_bytes = @sizeOf(Operand), .alignment = .fromByteUnits(@alignOf(Operand)) },
                .{ .count = limits.results, .element_bytes = @sizeOf(Result), .alignment = .fromByteUnits(@alignOf(Result)) },
                .{ .count = limits.regions, .element_bytes = @sizeOf(Region), .alignment = .fromByteUnits(@alignOf(Region)) },
                .{ .count = limits.successors, .element_bytes = @sizeOf(Successor), .alignment = .fromByteUnits(@alignOf(Successor)) },
                .{ .count = limits.properties, .element_bytes = 1, .alignment = limits.properties_alignment },
            } };
        }

        fn acquire(storage: *Storage, limits: Limits) error{CapacityOverflow}!Regions {
            std.debug.assert(storage.phase == .initialization);
            const layout = try Layout.derive(limits);
            std.debug.assert(layout.total_bytes == storage.capacity.total_bytes);
            std.debug.assert(layout.allocation_alignment == storage.capacity.allocation_alignment);
            const handle = storage.storageHandle();
            return .{
                .header = pointer(Header, handle, layout.header_offset),
                .operand_values = slice(OperandValue, handle, layout.operand_values_offset, layout.operands),
                .result_types = slice(ResultType, handle, layout.result_types_offset, layout.results),
                .operands = slice(Operand, handle, layout.operands_offset, layout.operands),
                .results = slice(Result, handle, layout.results_offset, layout.results),
                .regions = slice(Region, handle, layout.regions_offset, layout.regions),
                .successors = slice(Successor, handle, layout.successors_offset, layout.successors),
                .properties = byteSlice(handle, layout.properties_offset, layout.properties),
            };
        }

        fn pointer(comptime T: type, handle: Handle, offset: usize) *T {
            const raw: [*]u8 = @ptrFromInt(addressAt(handle, offset));
            return @ptrCast(@alignCast(raw));
        }

        fn slice(comptime T: type, handle: Handle, offset: usize, count: usize) []T {
            const byte_count = std.math.mul(usize, count, @sizeOf(T)) catch unreachable;
            assertRegion(handle, offset, byte_count);
            const raw: [*]u8 = @ptrFromInt(addressAt(handle, offset));
            const items: [*]T = @ptrCast(@alignCast(raw));
            return items[0..count];
        }
    };
}

pub fn Pair(comptime First: type, comptime Second: type) type {
    return struct {
        pub const Capacity = struct {
            count: usize,
            first_offset: usize,
            second_offset: usize,
            total_bytes: usize,
            allocation_alignment: std.mem.Alignment,

            pub fn derive(count: usize) error{CapacityOverflow}!Capacity {
                var cursor: usize = 0;
                var alignment: usize = 1;
                const first_offset = try place(First, count, &cursor, &alignment);
                const second_offset = try place(Second, count, &cursor, &alignment);
                return .{
                    .count = count,
                    .first_offset = first_offset,
                    .second_offset = second_offset,
                    .total_bytes = cursor,
                    .allocation_alignment = .fromByteUnits(alignment),
                };
            }
        };

        pub const Allocation = struct {
            handle: Handle,
            first: []First,
            second: []Second,
        };

        pub fn init(allocator: Allocator, count: usize) !Allocation {
            std.debug.assert(count > 0);
            const capacity = try Capacity.derive(count);
            const bytes = allocator.rawAlloc(
                capacity.total_bytes,
                capacity.allocation_alignment,
                @returnAddress(),
            ) orelse return error.OutOfMemory;
            const handle = Handle{
                .bytes = bytes,
                .len = capacity.total_bytes,
                .alignment = capacity.allocation_alignment,
            };
            return .{
                .handle = handle,
                .first = slice(First, handle, capacity.first_offset, capacity.count),
                .second = slice(Second, handle, capacity.second_offset, capacity.count),
            };
        }

        fn slice(comptime T: type, handle: Handle, offset: usize, count: usize) []T {
            const byte_count = std.math.mul(usize, count, @sizeOf(T)) catch unreachable;
            assertRegion(handle, offset, byte_count);
            const raw: [*]u8 = @ptrFromInt(addressAt(handle, offset));
            const items: [*]T = @ptrCast(@alignCast(raw));
            return items[0..count];
        }
    };
}

fn place(
    comptime T: type,
    count: usize,
    cursor: *usize,
    allocation_alignment: *usize,
) error{CapacityOverflow}!usize {
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.CapacityOverflow;
    return try placeBytes(bytes, @alignOf(T), cursor, allocation_alignment);
}

fn placeBytes(
    bytes: usize,
    alignment: usize,
    cursor: *usize,
    allocation_alignment: *usize,
) error{CapacityOverflow}!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = std.math.sub(usize, alignment, 1) catch unreachable;
    const padded = std.math.add(usize, cursor.*, mask) catch return error.CapacityOverflow;
    const offset = padded & ~mask;
    cursor.* = std.math.add(usize, offset, bytes) catch return error.CapacityOverflow;
    allocation_alignment.* = @max(allocation_alignment.*, alignment);
    return offset;
}

fn byteSlice(handle: Handle, offset: usize, len: usize) []u8 {
    assertRegion(handle, offset, len);
    const pointer: [*]u8 = @ptrFromInt(addressAt(handle, offset));
    return pointer[0..len];
}

fn addressAt(handle: Handle, offset: usize) usize {
    std.debug.assert(offset <= handle.len);
    return std.math.add(usize, @intFromPtr(handle.bytes), offset) catch unreachable;
}

fn assertRegion(handle: Handle, offset: usize, len: usize) void {
    const remaining = std.math.sub(usize, handle.len, offset) catch unreachable;
    std.debug.assert(len <= remaining);
}

test "operation storage capacity matches an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "choir_operation_storage_capacity"),
        );
    }

    const Header = extern struct { word: u64 };
    const Operand = extern struct { words: [3]u64 };
    const Result = struct { byte: u8 };
    const TypedPlan = Plan(Header, *u8, u32, Operand, Result, u128, *u16);
    const limits = TypedPlan.Limits{
        .operands = 3,
        .results = 2,
        .regions = 1,
        .successors = 4,
        .properties = 7,
        .properties_alignment = .@"32",
    };
    const capacity = try TypedPlan.Capacity.derive(limits);

    const Model = struct {
        fn placeType(comptime T: type, count: usize, cursor: *usize) !void {
            cursor.* = std.mem.alignForward(usize, cursor.*, @alignOf(T));
            const bytes = try std.math.mul(usize, count, @sizeOf(T));
            cursor.* = try std.math.add(usize, cursor.*, bytes);
        }

        fn placeBytes(bytes: usize, alignment: usize, cursor: *usize) !void {
            cursor.* = std.mem.alignForward(usize, cursor.*, alignment);
            cursor.* = try std.math.add(usize, cursor.*, bytes);
        }
    };
    var expected_bytes: usize = 0;
    try Model.placeType(Header, 1, &expected_bytes);
    try Model.placeType(*u8, limits.operands, &expected_bytes);
    try Model.placeType(u32, limits.results, &expected_bytes);
    try Model.placeType(Operand, limits.operands, &expected_bytes);
    try Model.placeType(Result, limits.results, &expected_bytes);
    try Model.placeType(u128, limits.regions, &expected_bytes);
    try Model.placeType(*u16, limits.successors, &expected_bytes);
    try Model.placeBytes(limits.properties, limits.properties_alignment.toByteUnits(), &expected_bytes);

    try std.testing.expectEqual(expected_bytes, capacity.total_bytes);
    try std.testing.expectEqual(@as(usize, 32), capacity.allocation_alignment.toByteUnits());
}

test "operation storage acquires one exact aligned region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "choir_operation_storage_acquisition"),
        );
    }

    const Header = extern struct { word: u64 };
    const Operand = extern struct { words: [3]u64 };
    const Result = struct { byte: u8 };
    const TypedPlan = Plan(Header, *u8, u32, Operand, Result, u128, *u16);
    const limits = TypedPlan.Limits{
        .operands = 3,
        .results = 2,
        .regions = 1,
        .successors = 4,
        .properties = 7,
        .properties_alignment = .@"32",
    };
    const capacity = try TypedPlan.Capacity.derive(limits);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var allocation = try TypedPlan.init(failing.allocator(), limits);
    defer allocation.storage.deinit(failing.allocator());
    const regions = allocation.regions;

    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expectEqual(capacity.total_bytes, failing.allocated_bytes);
    try std.testing.expect(@intFromPtr(allocation.storage.bytes) % capacity.allocation_alignment.toByteUnits() == 0);
    try std.testing.expectEqual(limits.operands, regions.operands.len);
    try std.testing.expectEqual(limits.results, regions.results.len);
    try std.testing.expectEqual(limits.properties, regions.properties.len);
    try std.testing.expect(!alloc_phase.capacity.typeHasAllocatorCapability(Storage));
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, allocation.storage.status());
    allocation.storage.activate();
    try std.testing.expectEqual(alloc_phase.capacity.Phase.steady, allocation.storage.status());
}

test "operation storage capacity rejects max plus one arithmetic" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "choir_operation_storage_boundary"),
        );
    }

    const TypedPlan = Plan(u8, usize, usize, usize, usize, usize, usize);
    try std.testing.expectError(error.CapacityOverflow, TypedPlan.Capacity.derive(.{
        .operands = std.math.maxInt(usize),
        .results = 0,
        .regions = 0,
        .successors = 0,
        .properties = 0,
        .properties_alignment = .@"1",
    }));
    try std.testing.expectError(error.CapacityOverflow, Pair(usize, usize).Capacity.derive(std.math.maxInt(usize)));
}

test "operation storage retries after allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "choir_operation_storage_oom"),
        );
    }

    const TypedPlan = Plan(u8, usize, usize, usize, usize, usize, usize);
    const limits = TypedPlan.Limits{
        .operands = 1,
        .results = 1,
        .regions = 1,
        .successors = 1,
        .properties = 1,
        .properties_alignment = .@"1",
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, TypedPlan.init(failing.allocator(), limits));

    failing.fail_index = std.math.maxInt(usize);
    var allocation = try TypedPlan.init(failing.allocator(), limits);
    allocation.storage.deinit(failing.allocator());
}

test "operation storage pool preserves fallback allocation provenance" {
    const TestAllocator = PoolAllocator(
        .{ .total_bytes = 64, .allocation_alignment = .@"8" },
        .{ .total_bytes = 96, .allocation_alignment = .@"8" },
        .{ .total_bytes = 128, .allocation_alignment = .@"8" },
        .{ .total_bytes = 160, .allocation_alignment = .@"8" },
    );
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var pool = TestAllocator.init(failing.allocator());
    defer pool.deinit();
    const allocator = pool.allocator();

    const fallback_before = failing.alloc_index;
    const fallback = allocator.rawAlloc(
        63,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    try std.testing.expectEqual(
        std.math.add(usize, fallback_before, 1) catch unreachable,
        failing.alloc_index,
    );
    const resize_before = failing.resize_index;
    try std.testing.expect(!allocator.rawResize(fallback[0..63], .@"8", 64, @returnAddress()));
    try std.testing.expectEqual(resize_before, failing.resize_index);
    try std.testing.expectEqual(
        @as(?[*]u8, null),
        allocator.rawRemap(fallback[0..63], .@"8", 96, @returnAddress()),
    );
    try std.testing.expectEqual(resize_before, failing.resize_index);
    allocator.rawFree(fallback[0..63], .@"8", @returnAddress());

    const aligned_before = failing.alloc_index;
    const aligned = allocator.rawAlloc(
        64,
        .@"16",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    try std.testing.expectEqual(
        std.math.add(usize, aligned_before, 1) catch unreachable,
        failing.alloc_index,
    );
    allocator.rawFree(aligned[0..64], .@"16", @returnAddress());
}

test "operation storage pool pads slot strides without widening allocations" {
    const TestAllocator = PoolAllocator(
        .{ .total_bytes = 17, .allocation_alignment = .@"8" },
        .{ .total_bytes = 25, .allocation_alignment = .@"8" },
        .{ .total_bytes = 33, .allocation_alignment = .@"8" },
        .{ .total_bytes = 41, .allocation_alignment = .@"8" },
    );
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var pool = TestAllocator.init(failing.allocator());
    defer pool.deinit();
    const allocator = pool.allocator();

    const first = allocator.rawAlloc(17, .@"8", @returnAddress()) orelse
        return error.OutOfMemory;
    try std.testing.expect(@intFromPtr(first) % 8 == 0);
    const allocation_count = failing.alloc_index;
    allocator.rawFree(first[0..17], .@"8", @returnAddress());

    const reused = allocator.rawAlloc(17, .@"8", @returnAddress()) orelse
        return error.OutOfMemory;
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(reused));
    allocator.rawFree(reused[0..17], .@"8", @returnAddress());
}

test "operation storage pool attributes requests satisfied without backing dispatch" {
    if (comptime !alloc_observe.enabled) return error.SkipZigTest;
    const Capture = struct {
        events: [4]alloc_observe.Event = undefined,
        count: usize = 0,

        fn record(context: *anyopaque, event: alloc_observe.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.count < self.events.len);
            self.events[self.count] = event;
            self.count += 1;
        }
    };
    const TestAllocator = PoolAllocator(
        .{ .total_bytes = 17, .allocation_alignment = .@"8" },
        .{ .total_bytes = 25, .allocation_alignment = .@"8" },
        .{ .total_bytes = 33, .allocation_alignment = .@"8" },
        .{ .total_bytes = 41, .allocation_alignment = .@"8" },
    );
    var capture = Capture{};
    const sink = alloc_observe.Sink{
        .context = &capture,
        .record = Capture.record,
    };
    var observation = try alloc_observe.install(&sink);
    defer observation.deinit();
    var pool = TestAllocator.init(std.testing.allocator);
    defer pool.deinit();
    const allocator = pool.allocator();
    const first = allocator.rawAlloc(17, .@"8", @returnAddress()) orelse
        return error.OutOfMemory;
    allocator.rawFree(first[0..17], .@"8", @returnAddress());
    const reused = allocator.rawAlloc(17, .@"8", @returnAddress()) orelse
        return error.OutOfMemory;
    allocator.rawFree(reused[0..17], .@"8", @returnAddress());

    try std.testing.expectEqual(@as(usize, 4), capture.count);
    try std.testing.expectEqual(alloc_observe.Producer.pool, capture.events[0].producer);
    try std.testing.expectEqual(alloc_observe.Operation.alloc, capture.events[0].operation);
    try std.testing.expect(capture.events[0].succeeded);
    try std.testing.expectEqual(alloc_observe.Operation.alloc, capture.events[2].operation);
    try std.testing.expectEqual(@intFromPtr(first), capture.events[2].address);
    try std.testing.expectEqual(capture.events[0].producer_id, capture.events[2].producer_id);
}

test "operation storage list exposes fixed capacity without allocation authority" {
    var backing: [3]u32 = undefined;
    var list = List(u32).init(&backing);
    list.appendAssumeCapacity(1);
    list.appendSliceAssumeCapacity(&.{ 2, 3 });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, list.items);
    list.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 3), list.capacity);
}

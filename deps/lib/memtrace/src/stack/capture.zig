const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");

pub const max_frames_limit: usize = 512;
const no_record = std.math.maxInt(u32);
const metadata_tag = "\"meta\":\"memtrace.stack\"";

pub const Attribution = enum {
    return_address,
    stack,
};

pub const Capture = struct {
    addresses: []const usize,
    truncated: bool,
    unwind_failed: bool,
    missing_return_address: bool,
};

pub const Definition = struct {
    addresses: []usize,
    truncated: bool,
    unwind_failed: bool,
    missing_return_address: bool,
    collision_next: u32,

    pub fn complete(self: Definition) bool {
        return !self.truncated and
            !self.unwind_failed and
            !self.missing_return_address;
    }
};

pub const Interned = struct {
    id: u32,
    is_new: bool,
};

pub const Interner = struct {
    definitions: std.ArrayListUnmanaged(Definition) = .empty,
    collision_heads: std.AutoHashMapUnmanaged(u64, u32) = .{},

    pub fn deinit(self: *Interner, allocator: std.mem.Allocator) void {
        for (self.definitions.items) |entry| allocator.free(entry.addresses);
        self.definitions.deinit(allocator);
        self.collision_heads.deinit(allocator);
        self.* = .{};
    }

    pub fn intern(
        self: *Interner,
        allocator: std.mem.Allocator,
        captured: Capture,
    ) !Interned {
        std.debug.assert(captured.addresses.len > 0);
        std.debug.assert(captured.addresses.len <= max_frames_limit);
        const hash = captureHash(captured);
        const prior = self.collision_heads.get(hash);
        var candidate = prior orelse no_record;
        while (candidate != no_record) {
            const entry = self.definitions.items[candidate];
            if (entry.truncated == captured.truncated and
                entry.unwind_failed == captured.unwind_failed and
                entry.missing_return_address == captured.missing_return_address and
                std.mem.eql(usize, entry.addresses, captured.addresses))
            {
                return .{ .id = candidate + 1, .is_new = false };
            }
            candidate = entry.collision_next;
        }
        if (self.definitions.items.len >= no_record) return error.OutOfMemory;
        const owned = try allocator.dupe(usize, captured.addresses);
        errdefer allocator.free(owned);
        try self.definitions.ensureUnusedCapacity(allocator, 1);
        const head = try self.collision_heads.getOrPut(allocator, hash);
        const index: u32 = @intCast(self.definitions.items.len);
        self.definitions.appendAssumeCapacity(.{
            .addresses = owned,
            .truncated = captured.truncated,
            .unwind_failed = captured.unwind_failed,
            .missing_return_address = captured.missing_return_address,
            .collision_next = prior orelse no_record,
        });
        head.value_ptr.* = index;
        return .{ .id = index + 1, .is_new = true };
    }

    pub fn recordForId(self: *const Interner, id: u32) *const Definition {
        std.debug.assert(id > 0);
        std.debug.assert(id <= self.definitions.items.len);
        return &self.definitions.items[id - 1];
    }
};

pub fn supportsCapture() bool {
    return sys.backtrace.supportsCapture();
}

pub fn isMetadataLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, metadata_tag) != null;
}

/// One `memtrace.stack` line, field for field as `writeDefinition` writes it.
pub const Record = struct {
    v: u64,
    meta: []const u8,
    stack_id: u32,
    truncated: bool,
    unwind_failed: bool,
    missing_return_address: bool,
    call_addresses: []const u64,
};

pub fn writeDefinition(
    writer: *std.Io.Writer,
    id: u32,
    definition: Definition,
) !void {
    std.debug.assert(id > 0);
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("v", 1);
    try object.field("meta", "memtrace.stack");
    try object.field("stack_id", id);
    try object.field("truncated", definition.truncated);
    try object.field("unwind_failed", definition.unwind_failed);
    try object.field("missing_return_address", definition.missing_return_address);
    const addresses = try object.array("call_addresses");
    for (definition.addresses) |address| try addresses.element(address);
    try addresses.end();
    try object.endLine();
}

pub fn validateFrameLimit(limit: usize) !void {
    if (limit < 2 or limit > max_frames_limit) return error.InvalidStackFrameLimit;
}

pub noinline fn capture(
    storage: *[max_frames_limit]usize,
    return_address: usize,
    frame_limit: usize,
) Capture {
    std.debug.assert(frame_limit >= 2);
    std.debug.assert(frame_limit <= storage.len);
    storage[0] = callAddress(return_address);
    const available = frame_limit - 1;
    const raw = @as(
        [*]?*anyopaque,
        @ptrCast(@alignCast(storage[1..].ptr)),
    )[0..available];
    @memset(raw, null);
    const count = sys.backtrace.capture(raw);
    for (storage[1 .. count + 1]) |*address| {
        address.* = callAddress(address.*);
    }
    return .{
        .addresses = storage[0 .. count + 1],
        .truncated = count == available,
        .unwind_failed = count == 0,
        .missing_return_address = return_address == 0,
    };
}

pub fn callAddress(return_address: usize) usize {
    if (comptime @import("builtin").cpu.arch.isSPARC()) return return_address;
    return return_address -| 1;
}

fn captureHash(captured: Capture) u64 {
    const flags: u64 =
        @as(u64, @intFromBool(captured.truncated)) |
        (@as(u64, @intFromBool(captured.unwind_failed)) << 1) |
        (@as(u64, @intFromBool(captured.missing_return_address)) << 2);
    return std.hash.Wyhash.hash(
        flags,
        std.mem.sliceAsBytes(captured.addresses),
    );
}

test "stack record names exactly the fields the writer writes" {
    var addresses = [_]usize{ 4096, 8192 };
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeDefinition(&output.writer, 3, .{
        .addresses = &addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = true,
        .collision_next = no_record,
    });
    const record = try std.json.parseFromSlice(
        Record,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer record.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 4096, 8192 }, record.value.call_addresses);
    const written = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer written.deinit();
    inline for (@typeInfo(Record).@"struct".field_names) |name| {
        try std.testing.expect(written.value.object.contains(name));
    }
}

test "stack interner distinguishes complete colliding definitions" {
    var interner: Interner = .{};
    defer interner.deinit(std.testing.allocator);
    const first_addresses = [_]usize{ 1, 2, 3 };
    const second_addresses = [_]usize{ 1, 2, 4 };
    const first = try interner.intern(std.testing.allocator, .{
        .addresses = &first_addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
    });
    const repeated = try interner.intern(std.testing.allocator, .{
        .addresses = &first_addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
    });
    const second = try interner.intern(std.testing.allocator, .{
        .addresses = &second_addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
    });
    try std.testing.expect(first.is_new);
    try std.testing.expect(!repeated.is_new);
    try std.testing.expect(second.is_new);
    try std.testing.expectEqual(first.id, repeated.id);
    try std.testing.expect(first.id != second.id);
}

fn checkInternerAllocationFailures(allocator: std.mem.Allocator) !void {
    var interner: Interner = .{};
    defer interner.deinit(allocator);
    const first_addresses = [_]usize{ 1, 2, 3 };
    const second_addresses = [_]usize{ 1, 2, 4 };
    _ = try interner.intern(allocator, .{
        .addresses = &first_addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
    });
    _ = try interner.intern(allocator, .{
        .addresses = &second_addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
    });
}

test "stack interner rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkInternerAllocationFailures,
        .{},
    );
}

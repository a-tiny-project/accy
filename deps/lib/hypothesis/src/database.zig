const std = @import("std");
const alloc_phase = @import("alloc_phase");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ChoiceNode = conjecture.ChoiceNode;
const Sha256 = std.crypto.hash.sha2.Sha256;
const assert = std.debug.assert;

const magic = "JHYP";
const format_version: u16 = 1;
const header_bytes: usize = 16;
const choice_bytes: usize = 40;
const byte_blocks_flag: u16 = 1;
const max_failure_bytes: usize = 10 * 1024 * 1024;
const digest_text_bytes: usize = Sha256.digest_length * 2;
const failure_extension = ".jhyp";
const failure_name_bytes = digest_text_bytes + failure_extension.len;

pub const FailureEntry = struct {
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
};

const FailureName = [failure_name_bytes]u8;

const ReplayLimits = struct {
    db_path: []const u8,
    namespace: ?[]const u8,
    max_entries: usize,
    max_choices: usize,
    max_byte_blocks: usize,
};

const ReplayCapacity = struct {
    entries: usize,
    choices: usize,
    byte_blocks: usize,
    encoded_bytes: usize,
    name_bytes: usize,
    total_bytes: usize,

    pub fn derive(limits: ReplayLimits) error{FailureTooLarge}!ReplayCapacity {
        const encoded_bytes = try failureByteLen(
            limits.max_choices,
            limits.max_byte_blocks,
        );
        const name_bytes = std.math.mul(
            usize,
            limits.max_entries,
            @sizeOf(FailureName),
        ) catch return error.FailureTooLarge;
        const choice_bytes_total = std.math.mul(
            usize,
            limits.max_choices,
            @sizeOf(ChoiceNode),
        ) catch return error.FailureTooLarge;
        const working_bytes = std.math.add(
            usize,
            encoded_bytes,
            choice_bytes_total,
        ) catch return error.FailureTooLarge;
        const total_bytes = std.math.add(
            usize,
            name_bytes,
            working_bytes,
        ) catch return error.FailureTooLarge;
        return .{
            .entries = limits.max_entries,
            .choices = limits.max_choices,
            .byte_blocks = limits.max_byte_blocks,
            .encoded_bytes = encoded_bytes,
            .name_bytes = name_bytes,
            .total_bytes = total_bytes,
        };
    }
};

const ReplayStatus = struct {
    entries_scanned: usize = 0,
    candidate_files: usize = 0,
    failures_loaded: usize = 0,
    failures_rejected: usize = 0,
    scan_budget_saturated: bool = false,
};

pub const ReplayCursor = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: ReplayCapacity,
    dir: ?std.Io.Dir,
    names: []FailureName,
    encoded: []u8,
    choices: []ChoiceNode,
    name_count: usize = 0,
    next_name: usize = 0,
    status_value: ReplayStatus = .{},

    pub const Limits: type = ReplayLimits;
    pub const Capacity: type = ReplayCapacity;
    pub const Status: type = ReplayStatus;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "hypothesis.replay_cursor",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "bounded_sorted_content_address_candidate_names",
                        .lifetime = .steady,
                        .detail = "bounded sorted content-address candidate names",
                    },
                    .{
                        .id = "maximum_admitted_canonical_failure_bytes",
                        .lifetime = .steady,
                        .detail = "maximum admitted canonical failure bytes",
                    },
                    .{
                        .id = "maximum_admitted_decoded_choice_nodes",
                        .lifetime = .steady,
                        .detail = "maximum admitted decoded choice nodes",
                    },
                },
                .excluded = &.{
                    "caller-owned database path, namespace, replay context, and captured result",
                    "directory and file handles plus operating-system directory and file caches",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "db_path", "db_path"),
                    alloc_phase.capacity.bindInput(Limits, "max_byte_blocks", "max_byte_blocks"),
                    alloc_phase.capacity.bindInput(Limits, "max_choices", "max_choices"),
                    alloc_phase.capacity.bindInput(Limits, "max_entries", "max_entries"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .collection = .{ .length = 0 } },
                    .{ .input = 1 },
                    .{ .input = 2 },
                    .{ .input = 3 },
                    .{ .add = .{ .left = 0, .right = 1 } },
                    .{ .add = .{ .left = 4, .right = 2 } },
                    .{ .add = .{ .left = 5, .right = 3 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .upper_bound,
                    .expression = 6,
                }},
            },
            .overload = .{
                .kind = .not_applicable,
                .detail = "scan and record limits define the domain; rejected records do not exhaust storage",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "directory, file, sort, and SHA callees lack an allocation-closure certificate",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "filesystem handles and caches are excluded; sealed replay observes caller allocation",
                },
            },
            .obligations = &.{
                .{ .key = "hypothesis_replay_capacity", .role = .capacity_model },
                .{ .key = "hypothesis_replay_sealed", .role = .foreign_risk },
                .{ .key = "hypothesis_replay_oom_retry", .role = .custom },
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

    pub fn init(
        allocator: Allocator,
        limits: Limits,
    ) !ReplayCursor {
        const capacity = try Capacity.derive(limits);
        var cursor = ReplayCursor{
            .phase = .initialization,
            .capacity = capacity,
            .dir = null,
            .names = &.{},
            .encoded = &.{},
            .choices = &.{},
        };
        errdefer cursor.release(allocator);
        if (capacity.entries == 0) return cursor;

        cursor.dir = openNamespaceDir(limits.db_path, limits.namespace) catch |err| switch (err) {
            error.FileNotFound => return cursor,
            else => return err,
        };
        cursor.names = try allocator.alloc(FailureName, capacity.entries);
        cursor.encoded = try allocator.alloc(u8, capacity.encoded_bytes);
        if (capacity.choices > 0) {
            cursor.choices = try allocator.alloc(ChoiceNode, capacity.choices);
        }
        try cursor.scanNames();
        return cursor;
    }

    pub fn activate(self: *ReplayCursor) void {
        assert(self.phase == .initialization);
        assert(self.name_count <= self.capacity.entries);
        assert(self.next_name == 0);
        self.phase = .steady;
    }

    pub fn next(self: *ReplayCursor) !?FailureEntry {
        assert(self.phase == .steady);
        assert(self.next_name <= self.name_count);
        while (self.next_name < self.name_count) {
            const name = self.names[self.next_name];
            self.next_name += 1;
            const failure = self.loadFailure(&name) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (failure) |entry| {
                self.status_value.failures_loaded += 1;
                assert(self.status_value.failures_loaded <= self.name_count);
                return entry;
            }
            self.status_value.failures_rejected += 1;
            assert(self.status_value.failures_rejected <= self.name_count);
        }
        return null;
    }

    pub fn status(self: *const ReplayCursor) Status {
        assert(self.phase == .steady);
        return self.status_value;
    }

    pub fn deinit(self: *ReplayCursor, allocator: Allocator) void {
        assert(self.phase != .teardown);
        self.phase = .teardown;
        self.release(allocator);
        self.* = undefined;
    }

    fn scanNames(self: *ReplayCursor) !void {
        assert(self.phase == .initialization);
        var iterator = self.dir.?.iterate();
        while (self.status_value.entries_scanned < self.capacity.entries) {
            const entry = try iterator.next(std.Options.debug_io) orelse break;
            self.status_value.entries_scanned += 1;
            if (entry.kind != .file) continue;
            if (!isFailureName(entry.name)) continue;
            @memcpy(self.names[self.name_count][0..], entry.name);
            self.name_count += 1;
        }
        self.status_value.scan_budget_saturated =
            self.status_value.entries_scanned == self.capacity.entries;
        self.status_value.candidate_files = self.name_count;
        std.mem.sort(FailureName, self.names[0..self.name_count], {}, nameLessThan);
    }

    fn loadFailure(self: *ReplayCursor, name: *const FailureName) !?FailureEntry {
        assert(self.phase == .steady);
        var file = try self.dir.?.openFile(std.Options.debug_io, name, .{
            .allow_directory = false,
        });
        defer file.close(std.Options.debug_io);
        const stat = try file.stat(std.Options.debug_io);
        if (stat.kind != .file) return null;
        const file_len = std.math.cast(usize, stat.size) orelse return null;
        if (file_len > self.encoded.len) return null;
        const data = self.encoded[0..file_len];
        if (try file.readPositionalAll(std.Options.debug_io, data, 0) != file_len) {
            return null;
        }
        var trailing: [1]u8 = undefined;
        if (try file.readPositionalAll(std.Options.debug_io, &trailing, file_len) != 0) {
            return null;
        }
        if (!failureNameMatches(name, data)) return null;
        return deserializeFailureInto(
            self.choices,
            self.capacity.byte_blocks,
            data,
        ) catch |err| switch (err) {
            error.InvalidFormat, error.UnsupportedVersion, error.CapacityExceeded => null,
        };
    }

    fn release(self: *ReplayCursor, allocator: Allocator) void {
        if (self.choices.len > 0) allocator.free(self.choices);
        if (self.encoded.len > 0) allocator.free(self.encoded);
        if (self.names.len > 0) allocator.free(self.names);
        if (self.dir) |dir| dir.close(std.Options.debug_io);
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(ReplayCursor);
}

pub fn saveFailure(
    allocator: Allocator,
    db_path: []const u8,
    namespace: ?[]const u8,
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
) !void {
    const resolved = try resolveDbPath(allocator, db_path, namespace);
    defer if (resolved.owned) |path| allocator.free(path);

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, resolved.path);
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, resolved.path, .{});
    defer dir.close(std.Options.debug_io);

    const data = try serializeFailure(allocator, choices, byte_blocks);
    defer allocator.free(data);
    const digest_text = sha256Hex(data);
    var name_buf: [failure_name_bytes]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{
        digest_text,
        failure_extension,
    }) catch unreachable;

    var atomic_file = try dir.createFileAtomic(
        std.Options.debug_io,
        name,
        .{ .replace = true },
    );
    defer atomic_file.deinit(std.Options.debug_io);
    try atomic_file.file.writePositionalAll(std.Options.debug_io, data, 0);
    try atomic_file.replace(std.Options.debug_io);
}

fn serializeFailure(
    allocator: Allocator,
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
) ![]u8 {
    const block_len = if (byte_blocks) |blocks| blocks.len else 0;
    const total = try failureByteLen(choices.len, block_len);
    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);
    @memcpy(buf[0..magic.len], magic);
    std.mem.writeInt(u16, buf[4..6], format_version, .little);
    std.mem.writeInt(
        u16,
        buf[6..8],
        if (byte_blocks != null) byte_blocks_flag else 0,
        .little,
    );
    std.mem.writeInt(u32, buf[8..12], @intCast(choices.len), .little);
    std.mem.writeInt(u32, buf[12..16], @intCast(block_len), .little);

    for (choices, 0..) |node, index| {
        const offset = header_bytes + index * choice_bytes;
        buf[offset] = @backingInt(node.kind);
        buf[offset + 1] = @intFromBool(node.was_forced);
        std.mem.writeInt(u64, buf[offset + 8 ..][0..8], node.value, .little);
        std.mem.writeInt(u64, buf[offset + 16 ..][0..8], node.min, .little);
        std.mem.writeInt(u64, buf[offset + 24 ..][0..8], node.max, .little);
        std.mem.writeInt(u64, buf[offset + 32 ..][0..8], node.shrink_towards, .little);
    }
    if (byte_blocks) |blocks| {
        @memcpy(buf[total - blocks.len ..], blocks);
    }

    return buf;
}

const FailureShape = struct {
    choice_count: usize,
    block_len: usize,
    total: usize,
    has_blocks: bool,
};

fn validateFailure(data: []const u8) !FailureShape {
    if (data.len < header_bytes) return error.InvalidFormat;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;
    if (std.mem.readInt(u16, data[4..6], .little) != format_version) {
        return error.UnsupportedVersion;
    }
    const flags = std.mem.readInt(u16, data[6..8], .little);
    if (flags & ~byte_blocks_flag != 0) return error.InvalidFormat;
    const choice_count: usize = std.mem.readInt(u32, data[8..12], .little);
    const block_len: usize = std.mem.readInt(u32, data[12..16], .little);
    if (flags & byte_blocks_flag == 0 and block_len != 0) return error.InvalidFormat;
    const total = failureByteLen(choice_count, block_len) catch return error.InvalidFormat;
    if (data.len != total) return error.InvalidFormat;

    for (0..choice_count) |index| {
        const offset = header_bytes + index * choice_bytes;
        for (data[offset + 2 .. offset + 8]) |reserved| {
            if (reserved != 0) return error.InvalidFormat;
        }
        if (std.enums.fromInt(conjecture.ChoiceKind, data[offset]) == null) {
            return error.InvalidFormat;
        }
        if (data[offset + 1] > 1) return error.InvalidFormat;
    }
    return .{
        .choice_count = choice_count,
        .block_len = block_len,
        .total = total,
        .has_blocks = flags & byte_blocks_flag != 0,
    };
}

fn decodeChoices(storage: []ChoiceNode, data: []const u8) void {
    for (storage, 0..) |*node, index| {
        const offset = header_bytes + index * choice_bytes;
        node.* = .{
            .kind = std.enums.fromInt(conjecture.ChoiceKind, data[offset]).?,
            .value = std.mem.readInt(u64, data[offset + 8 ..][0..8], .little),
            .min = std.mem.readInt(u64, data[offset + 16 ..][0..8], .little),
            .max = std.mem.readInt(u64, data[offset + 24 ..][0..8], .little),
            .shrink_towards = std.mem.readInt(u64, data[offset + 32 ..][0..8], .little),
            .was_forced = data[offset + 1] == 1,
        };
    }
}

fn deserializeFailureInto(
    choice_storage: []ChoiceNode,
    max_byte_blocks: usize,
    data: []const u8,
) !FailureEntry {
    const shape = try validateFailure(data);
    if (shape.choice_count > choice_storage.len) return error.CapacityExceeded;
    if (shape.block_len > max_byte_blocks) return error.CapacityExceeded;
    const choices = choice_storage[0..shape.choice_count];
    decodeChoices(choices, data);
    return .{
        .choices = choices,
        .byte_blocks = if (shape.has_blocks)
            data[shape.total - shape.block_len ..]
        else
            null,
    };
}

fn deserializeFailure(allocator: Allocator, data: []const u8) !FailureEntry {
    const shape = try validateFailure(data);

    const choices = try allocator.alloc(ChoiceNode, shape.choice_count);
    errdefer allocator.free(choices);
    decodeChoices(choices, data);

    const blocks: ?[]const u8 = if (shape.has_blocks) blk: {
        const owned = try allocator.alloc(u8, shape.block_len);
        @memcpy(owned, data[shape.total - shape.block_len ..]);
        break :blk owned;
    } else null;

    return .{
        .choices = choices,
        .byte_blocks = blocks,
    };
}

fn failureByteLen(choice_count: usize, block_len: usize) error{FailureTooLarge}!usize {
    if (choice_count > std.math.maxInt(u32)) return error.FailureTooLarge;
    if (block_len > std.math.maxInt(u32)) return error.FailureTooLarge;
    const encoded_choices = std.math.mul(usize, choice_count, choice_bytes) catch
        return error.FailureTooLarge;
    const with_header = std.math.add(usize, header_bytes, encoded_choices) catch
        return error.FailureTooLarge;
    const total = std.math.add(usize, with_header, block_len) catch
        return error.FailureTooLarge;
    if (total > max_failure_bytes) return error.FailureTooLarge;
    return total;
}

const ResolvedPath = struct {
    path: []const u8,
    owned: ?[]u8 = null,
};

fn resolveDbPath(
    allocator: Allocator,
    db_path: []const u8,
    namespace: ?[]const u8,
) !ResolvedPath {
    if (namespace) |ns| {
        const dir = sha256Hex(ns);
        const joined = try std.fs.path.join(allocator, &.{ db_path, &dir });
        return .{ .path = joined, .owned = joined };
    }
    return .{ .path = db_path };
}

fn openNamespaceDir(db_path: []const u8, namespace: ?[]const u8) !std.Io.Dir {
    var base = try std.Io.Dir.cwd().openDir(
        std.Options.debug_io,
        db_path,
        .{ .iterate = namespace == null },
    );
    if (namespace) |ns| {
        defer base.close(std.Options.debug_io);
        const child = sha256Hex(ns);
        return base.openDir(std.Options.debug_io, &child, .{ .iterate = true });
    }
    return base;
}

fn sha256Hex(bytes: []const u8) [digest_text_bytes]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn isFailureName(name: []const u8) bool {
    return name.len == failure_name_bytes and
        std.mem.endsWith(u8, name, failure_extension);
}

fn failureNameMatches(name: []const u8, data: []const u8) bool {
    if (!isFailureName(name)) return false;
    const expected = sha256Hex(data);
    return std.mem.eql(u8, name[0..digest_text_bytes], &expected);
}

fn nameLessThan(_: void, left: FailureName, right: FailureName) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

fn expectFailureEqual(
    expected_choices: []const ChoiceNode,
    expected_blocks: ?[]const u8,
    actual: FailureEntry,
) !void {
    try std.testing.expectEqualDeep(expected_choices, actual.choices);
    try std.testing.expectEqual(expected_blocks != null, actual.byte_blocks != null);
    if (expected_blocks) |blocks| {
        try std.testing.expectEqualSlices(u8, blocks, actual.byte_blocks.?);
    }
}

fn expectInvalidWithoutAllocation(data: []const u8) !void {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.InvalidFormat,
        deserializeFailure(failing.allocator(), data),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

fn checkReplayCursorAllocationFailures(
    allocator: Allocator,
    db_path: []const u8,
    namespace: []const u8,
    expected: usize,
) !void {
    var cursor = try ReplayCursor.init(allocator, .{
        .db_path = db_path,
        .namespace = namespace,
        .max_entries = expected,
        .max_choices = 128,
        .max_byte_blocks = 16,
    });
    defer cursor.deinit(allocator);
    cursor.activate();
    var loaded: usize = 0;
    while (try cursor.next()) |_| loaded += 1;
    try std.testing.expectEqual(expected, loaded);
}

test "serialize and deserialize roundtrips" {
    const allocator = std.testing.allocator;

    const choices = [_]ChoiceNode{
        .{ .kind = .integer, .value = 42, .min = 0, .max = 100, .shrink_towards = 7 },
        .{
            .kind = .boolean,
            .value = 1,
            .min = 0,
            .max = 1,
            .shrink_towards = 0,
            .was_forced = true,
        },
    };
    const byte_blocks = "hello";

    const data = try serializeFailure(allocator, &choices, byte_blocks);
    defer allocator.free(data);

    const entry = try deserializeFailure(allocator, data);
    defer allocator.free(entry.choices);
    defer if (entry.byte_blocks) |bb| allocator.free(bb);

    try expectFailureEqual(&choices, byte_blocks, entry);
    try std.testing.expectEqual(
        @as(usize, header_bytes + choice_bytes * 2 + byte_blocks.len),
        data.len,
    );
    try std.testing.expectEqualSlices(u8, magic, data[0..magic.len]);
    try std.testing.expectEqual(format_version, std.mem.readInt(u16, data[4..6], .little));
}

test "canonical failure bytes are stable little endian" {
    const allocator = std.testing.allocator;
    const choices = [_]ChoiceNode{.{
        .kind = .float,
        .value = 0x0102_0304_0506_0708,
        .min = 0x1112_1314_1516_1718,
        .max = 0x2122_2324_2526_2728,
        .shrink_towards = 0x3132_3334_3536_3738,
        .was_forced = true,
    }};
    const encoded = try serializeFailure(allocator, &choices, &.{ 0xaa, 0xbb });
    defer allocator.free(encoded);
    const expected = [_]u8{
        0x4a, 0x48, 0x59, 0x50, 0x01, 0x00, 0x01, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21,
        0x38, 0x37, 0x36, 0x35, 0x34, 0x33, 0x32, 0x31,
        0xaa, 0xbb,
    };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "fuzz: canonical failure codec roundtrips and rejects truncated prefixes" {
    const allocator = std.testing.allocator;
    const max_choices: usize = 32;
    const max_blocks: usize = 128;
    var prng = std.Random.DefaultPrng.init(0x4a48_5950_4442_0001);
    var choices: [max_choices]ChoiceNode = undefined;
    var blocks: [max_blocks]u8 = undefined;

    for (0..64) |_| {
        const random = prng.random();
        const choice_count = random.uintLessThan(usize, max_choices + 1);
        for (choices[0..choice_count]) |*node| {
            node.* = .{
                .kind = @fromBackingInt(@intCast(random.uintLessThan(u8, 4))),
                .value = random.int(u64),
                .min = random.int(u64),
                .max = random.int(u64),
                .shrink_towards = random.int(u64),
                .was_forced = random.boolean(),
            };
        }
        const block_len = random.uintLessThan(usize, max_blocks + 1);
        random.bytes(blocks[0..block_len]);
        const expected_blocks: ?[]const u8 = if (random.boolean()) blocks[0..block_len] else null;

        const encoded = try serializeFailure(allocator, choices[0..choice_count], expected_blocks);
        defer allocator.free(encoded);
        const decoded = try deserializeFailure(allocator, encoded);
        defer allocator.free(decoded.choices);
        defer if (decoded.byte_blocks) |owned| allocator.free(owned);
        try expectFailureEqual(choices[0..choice_count], expected_blocks, decoded);

        for (0..encoded.len) |prefix_len| {
            try expectInvalidWithoutAllocation(encoded[0..prefix_len]);
        }
    }
}

test "fuzz: malformed canonical failure fields reject before allocation" {
    const allocator = std.testing.allocator;
    const choices = [_]ChoiceNode{
        .{
            .kind = .bytes,
            .value = 3,
            .min = 1,
            .max = 8,
            .shrink_towards = 1,
            .was_forced = true,
        },
    };
    const encoded = try serializeFailure(allocator, &choices, "abc");
    defer allocator.free(encoded);
    var malformed = try allocator.dupe(u8, encoded);
    defer allocator.free(malformed);

    malformed[0] ^= 0xff;
    try expectInvalidWithoutAllocation(malformed);
    @memcpy(malformed, encoded);
    std.mem.writeInt(u16, malformed[4..6], format_version + 1, .little);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.UnsupportedVersion,
        deserializeFailure(failing.allocator(), malformed),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    @memcpy(malformed, encoded);
    std.mem.writeInt(u16, malformed[6..8], byte_blocks_flag | 2, .little);
    try expectInvalidWithoutAllocation(malformed);
    @memcpy(malformed, encoded);
    malformed[header_bytes] = 0xff;
    try expectInvalidWithoutAllocation(malformed);
    @memcpy(malformed, encoded);
    malformed[header_bytes + 1] = 2;
    try expectInvalidWithoutAllocation(malformed);
    @memcpy(malformed, encoded);
    malformed[header_bytes + 2] = 1;
    try expectInvalidWithoutAllocation(malformed);
    @memcpy(malformed, encoded);
    std.mem.writeInt(u16, malformed[6..8], 0, .little);
    try expectInvalidWithoutAllocation(malformed);
    @memcpy(malformed, encoded);
    std.mem.writeInt(u32, malformed[8..12], std.math.maxInt(u32), .little);
    try expectInvalidWithoutAllocation(malformed);
    @memcpy(malformed, encoded);
    std.mem.writeInt(u32, malformed[12..16], std.math.maxInt(u32), .little);
    try expectInvalidWithoutAllocation(malformed);

    const trailing = try std.mem.concat(allocator, u8, &.{ encoded, &.{0} });
    defer allocator.free(trailing);
    try expectInvalidWithoutAllocation(trailing);
    try std.testing.expectError(
        error.FailureTooLarge,
        failureByteLen(std.math.maxInt(usize), std.math.maxInt(usize)),
    );
}

test "save and load failure" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const choices = [_]ChoiceNode{
        .{ .kind = .integer, .value = 99, .min = 0, .max = 200, .shrink_towards = 0 },
    };

    try saveFailure(allocator, tmp_path, "test", &choices, null);

    var cursor = try ReplayCursor.init(allocator, .{
        .db_path = tmp_path,
        .namespace = "test",
        .max_entries = 1,
        .max_choices = 1,
        .max_byte_blocks = 0,
    });
    defer cursor.deinit(allocator);
    cursor.activate();
    const failure = (try cursor.next()).?;
    try std.testing.expectEqual(99, failure.choices[0].value);
    try std.testing.expect((try cursor.next()) == null);
}

test "fuzz: complete failure identity preserves distinct replay inputs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    const base = ChoiceNode{ .kind = .integer, .value = 1, .min = 0, .max = 4 };
    var choice = base;
    try saveFailure(allocator, tmp_path, "identity", &.{choice}, null);
    choice.kind = .boolean;
    try saveFailure(allocator, tmp_path, "identity", &.{choice}, null);
    choice = base;
    choice.value = 2;
    try saveFailure(allocator, tmp_path, "identity", &.{choice}, null);
    choice = base;
    choice.min = 1;
    try saveFailure(allocator, tmp_path, "identity", &.{choice}, null);
    choice = base;
    choice.max = 5;
    try saveFailure(allocator, tmp_path, "identity", &.{choice}, null);
    choice = base;
    choice.shrink_towards = 1;
    try saveFailure(allocator, tmp_path, "identity", &.{choice}, null);
    choice = base;
    choice.was_forced = true;
    try saveFailure(allocator, tmp_path, "identity", &.{choice}, null);
    try saveFailure(allocator, tmp_path, "identity", &.{base}, &.{});
    try saveFailure(allocator, tmp_path, "identity", &.{base}, "a");
    try saveFailure(allocator, tmp_path, "identity", &.{base}, "b");
    try saveFailure(allocator, tmp_path, "identity", &.{base}, "b");

    var cursor = try ReplayCursor.init(allocator, .{
        .db_path = tmp_path,
        .namespace = "identity",
        .max_entries = 10,
        .max_choices = 1,
        .max_byte_blocks = 1,
    });
    defer cursor.deinit(allocator);
    cursor.activate();
    var loaded: usize = 0;
    while (try cursor.next()) |_| loaded += 1;
    try std.testing.expectEqual(@as(usize, 10), loaded);
}

test "fuzz: load rejects a valid payload under the wrong content address" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    const data = try serializeFailure(allocator, &.{.{ .kind = .integer, .value = 1 }}, null);
    defer allocator.free(data);
    const resolved = try resolveDbPath(allocator, tmp_path, "integrity");
    defer if (resolved.owned) |path| allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, resolved.path);
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, resolved.path, .{});
    defer dir.close(std.Options.debug_io);
    var digest = sha256Hex(data);
    digest[0] = if (digest[0] == '0') '1' else '0';
    var name_buf: [failure_name_bytes]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ digest, failure_extension });
    try dir.writeFile(std.Options.debug_io, .{ .sub_path = name, .data = data });
    var cursor = try ReplayCursor.init(allocator, .{
        .db_path = tmp_path,
        .namespace = "integrity",
        .max_entries = 1,
        .max_choices = 1,
        .max_byte_blocks = 0,
    });
    defer cursor.deinit(allocator);
    cursor.activate();
    try std.testing.expect((try cursor.next()) == null);
    try std.testing.expectEqual(@as(usize, 1), cursor.status().failures_rejected);
}

test "replay cursor capacity matches an independent byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ReplayCursor, "hypothesis_replay_capacity"),
        );
    }

    const limits = ReplayCursor.Limits{
        .db_path = "unused",
        .namespace = null,
        .max_entries = 7,
        .max_choices = 11,
        .max_byte_blocks = 13,
    };
    const capacity = try ReplayCursor.Capacity.derive(limits);
    const expected_names = limits.max_entries * failure_name_bytes;
    const expected_encoded = header_bytes + limits.max_choices * choice_bytes +
        limits.max_byte_blocks;
    const expected_choices = limits.max_choices * @sizeOf(ChoiceNode);
    try std.testing.expectEqual(expected_names, capacity.name_bytes);
    try std.testing.expectEqual(expected_encoded, capacity.encoded_bytes);
    try std.testing.expectEqual(
        expected_names + expected_encoded + expected_choices,
        capacity.total_bytes,
    );
}

test "replay cursor admits at most the requested directory prefix" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    for (0..3) |value| {
        try saveFailure(
            allocator,
            tmp_path,
            "bounded",
            &.{.{ .kind = .integer, .value = value }},
            null,
        );
    }
    var cursor = try ReplayCursor.init(allocator, .{
        .db_path = tmp_path,
        .namespace = "bounded",
        .max_entries = 2,
        .max_choices = 1,
        .max_byte_blocks = 0,
    });
    defer cursor.deinit(allocator);
    cursor.activate();
    var loaded: usize = 0;
    while (try cursor.next()) |_| loaded += 1;
    try std.testing.expectEqual(@as(usize, 2), loaded);
    try std.testing.expectEqual(@as(usize, 2), cursor.status().entries_scanned);
    try std.testing.expect(cursor.status().scan_budget_saturated);
}

test "replay cursor accepts exact failure capacity and rejects max plus one" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    const first = ChoiceNode{ .kind = .integer, .value = 1 };
    const second = ChoiceNode{ .kind = .integer, .value = 2 };
    try saveFailure(allocator, tmp_path, "capacity", &.{first}, "a");
    try saveFailure(allocator, tmp_path, "capacity", &.{ first, second }, "a");
    try saveFailure(allocator, tmp_path, "capacity", &.{first}, "ab");
    var cursor = try ReplayCursor.init(allocator, .{
        .db_path = tmp_path,
        .namespace = "capacity",
        .max_entries = 3,
        .max_choices = 1,
        .max_byte_blocks = 1,
    });
    defer cursor.deinit(allocator);
    cursor.activate();
    var loaded: usize = 0;
    while (try cursor.next()) |_| loaded += 1;
    try std.testing.expectEqual(@as(usize, 1), loaded);
    try std.testing.expectEqual(@as(usize, 2), cursor.status().failures_rejected);
}

test "replay cursor keeps pointers stable with zero steady allocator operations" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ReplayCursor, "hypothesis_replay_sealed"),
        );
    }

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    try saveFailure(allocator, tmp_path, "sealed", &.{.{ .kind = .integer, .value = 0 }}, "a");
    try saveFailure(allocator, tmp_path, "sealed", &.{.{ .kind = .integer, .value = 1 }}, "b");

    var observed = try alloc_phase.ObservingPhaseAllocator.init(allocator);
    var cursor = try ReplayCursor.init(observed.initializationAllocator(), .{
        .db_path = tmp_path,
        .namespace = "sealed",
        .max_entries = 2,
        .max_choices = 1,
        .max_byte_blocks = 1,
    });
    cursor.activate();
    observed.seal();
    const encoded_pointer = cursor.encoded.ptr;
    const choice_pointer = cursor.choices.ptr;
    var loaded: usize = 0;
    while (try cursor.next()) |_| loaded += 1;
    try std.testing.expectEqual(@as(usize, 2), loaded);
    try std.testing.expectEqual(encoded_pointer, cursor.encoded.ptr);
    try std.testing.expectEqual(choice_pointer, cursor.choices.ptr);
    try std.testing.expectEqual(@as(u64, 0), observed.violations().total());
    observed.beginTeardown();
    cursor.deinit(observed.teardownAllocator());
    observed.deinit();
}

test "replay cursor surfaces every initialization OOM and retries" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ReplayCursor, "hypothesis_replay_oom_retry"),
        );
    }

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    var choices: [128]ChoiceNode = undefined;
    for (&choices, 0..) |*choice, index| {
        choice.* = .{ .kind = .integer, .value = @intCast(index) };
    }
    try saveFailure(allocator, tmp_path, "oom", &choices, "first");
    choices[0].value = 1_000;
    try saveFailure(allocator, tmp_path, "oom", &choices, "second");
    try std.testing.checkAllAllocationFailures(
        allocator,
        checkReplayCursorAllocationFailures,
        .{ tmp_path, "oom", @as(usize, 2) },
    );
    try checkReplayCursorAllocationFailures(allocator, tmp_path, "oom", 2);
}

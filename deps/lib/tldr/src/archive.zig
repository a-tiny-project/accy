const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const magic = "!<arch>\n";
const header_size = 60;

pub const Member = struct {
    name: []const u8,
    bytes: []const u8,
    header_offset: u64,
};

pub const SymbolIndexEntry = struct {
    name: []const u8,
    member_offset: u64,
};

pub const BuildMember = struct {
    name: []const u8,
    bytes: []const u8,
    symbols: []const []const u8 = &.{},
};

pub const ParsedArchive = struct {
    members: []Member,
    symbol_index: []SymbolIndexEntry,
    has_symbol_index: bool,

    pub fn deinit(self: *ParsedArchive, allocator: Allocator) void {
        allocator.free(self.members);
        allocator.free(self.symbol_index);
        self.* = undefined;
    }
};

pub fn isArchive(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], magic);
}

pub fn build(allocator: Allocator, members: []const BuildMember) Allocator.Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, magic);
    var member_offsets: []usize = &.{};
    var symbol_count: usize = 0;
    var symbol_name_bytes: usize = 0;
    for (members) |member| {
        symbol_count += member.symbols.len;
        for (member.symbols) |symbol| symbol_name_bytes += symbol.len + 1;
    }
    if (symbol_count != 0) {
        member_offsets = try allocator.alloc(usize, members.len);
        defer allocator.free(member_offsets);

        const symbol_index_size = 4 + symbol_count * 4 + symbol_name_bytes;
        var next_member_offset = magic.len + header_size + symbol_index_size + (symbol_index_size & 1);
        for (members, 0..) |member, index| {
            member_offsets[index] = next_member_offset;
            const payload_size = encodedMemberPayloadSize(member);
            next_member_offset += header_size + payload_size + (payload_size & 1);
        }

        try appendHeaderWithNameField(&out, allocator, "/", symbol_index_size);
        try appendU32Big(&out, allocator, @intCast(symbol_count));
        for (members, 0..) |member, member_index| {
            for (member.symbols) |_| try appendU32Big(&out, allocator, @intCast(member_offsets[member_index]));
        }
        for (members) |member| {
            for (member.symbols) |symbol| {
                try out.appendSlice(allocator, symbol);
                try out.append(allocator, 0);
            }
        }
        if ((symbol_index_size & 1) != 0) try out.append(allocator, '\n');
    }

    for (members) |member| {
        const payload_size = encodedMemberPayloadSize(member);
        try appendHeader(&out, allocator, member.name, payload_size);
        if (!usesShortMemberName(member.name)) try out.appendSlice(allocator, member.name);
        try out.appendSlice(allocator, member.bytes);
        if ((payload_size & 1) != 0) try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

pub fn parse(allocator: Allocator, input: model.Input) model.Error![]Member {
    const parsed = try parseDetailed(allocator, input);
    allocator.free(parsed.symbol_index);
    return parsed.members;
}

pub fn parseDetailed(allocator: Allocator, input: model.Input) model.Error!ParsedArchive {
    const bytes = input.bytes;
    if (!isArchive(bytes)) return error.InvalidArchive;

    var long_names: []const u8 = &.{};
    var members = std.ArrayListUnmanaged(Member).empty;
    var symbol_index = std.ArrayListUnmanaged(SymbolIndexEntry).empty;
    var has_symbol_index = false;
    errdefer {
        members.deinit(allocator);
        symbol_index.deinit(allocator);
    }

    var offset: usize = magic.len;
    while (offset < bytes.len) {
        if (offset + header_size > bytes.len) return error.InvalidArchive;
        const header_offset = offset;
        const header = bytes[offset .. offset + header_size];
        if (header[58] != '`' or header[59] != '\n') return error.InvalidArchive;
        offset += header_size;

        const size = try parseDecimal(header[48..58]);
        if (size > bytes.len - offset) return error.InvalidArchive;
        const raw_payload = bytes[offset .. offset + size];
        offset += size;
        if ((offset & 1) != 0) {
            if (offset >= bytes.len) return error.InvalidArchive;
            offset += 1;
        }

        const raw_name = trimField(header[0..16]);
        if (std.mem.eql(u8, raw_name, "/")) {
            has_symbol_index = true;
            try parseSymbolIndex(allocator, raw_payload, &symbol_index);
            continue;
        }
        if (std.mem.eql(u8, raw_name, "//")) {
            long_names = raw_payload;
            continue;
        }

        const decoded = try decodeMemberName(raw_name, raw_payload, long_names);
        try members.append(allocator, .{
            .name = decoded.name,
            .bytes = decoded.payload,
            .header_offset = @intCast(header_offset),
        });
    }

    if (offset != bytes.len) return error.InvalidArchive;
    const member_slice = try members.toOwnedSlice(allocator);
    errdefer allocator.free(member_slice);
    const symbol_index_slice = try symbol_index.toOwnedSlice(allocator);
    return .{
        .members = member_slice,
        .symbol_index = symbol_index_slice,
        .has_symbol_index = has_symbol_index,
    };
}

pub fn memberIndexByOffsetWithCursor(members: []const Member, offset: u64, cursor: *usize) ?usize {
    if (cursor.* < members.len) {
        const current_offset = members[cursor.*].header_offset;
        if (current_offset == offset) return cursor.*;
        if (current_offset < offset) {
            var index = cursor.* + 1;
            while (index < members.len) : (index += 1) {
                const member_offset = members[index].header_offset;
                if (member_offset == offset) {
                    cursor.* = index;
                    return index;
                }
                if (member_offset > offset) return null;
            }
            return null;
        }
    }
    const index = memberIndexByOffset(members, offset) orelse return null;
    cursor.* = index;
    return index;
}

pub fn memberIndexByOffset(members: []const Member, offset: u64) ?usize {
    var low: usize = 0;
    var high: usize = members.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const member_offset = members[middle].header_offset;
        if (member_offset == offset) return middle;
        if (offset < member_offset) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    return null;
}

test "member offset cursor handles ordered and fallback lookups" {
    const members = [_]Member{
        .{ .name = "a.o", .bytes = &.{}, .header_offset = 8 },
        .{ .name = "b.o", .bytes = &.{}, .header_offset = 24 },
        .{ .name = "c.o", .bytes = &.{}, .header_offset = 40 },
    };

    var cursor: usize = 0;
    try std.testing.expectEqual(@as(?usize, 0), memberIndexByOffsetWithCursor(&members, 8, &cursor));
    try std.testing.expectEqual(@as(usize, 0), cursor);
    try std.testing.expectEqual(@as(?usize, 2), memberIndexByOffsetWithCursor(&members, 40, &cursor));
    try std.testing.expectEqual(@as(usize, 2), cursor);
    try std.testing.expectEqual(@as(?usize, 1), memberIndexByOffsetWithCursor(&members, 24, &cursor));
    try std.testing.expectEqual(@as(usize, 1), cursor);
    try std.testing.expectEqual(@as(?usize, null), memberIndexByOffsetWithCursor(&members, 32, &cursor));
}

fn parseSymbolIndex(
    allocator: Allocator,
    payload: []const u8,
    symbol_index: *std.ArrayListUnmanaged(SymbolIndexEntry),
) model.Error!void {
    if (payload.len < 4) return error.InvalidArchive;
    const symbol_count = readU32Big(payload, 0);
    const offset_table_size = std.math.mul(usize, symbol_count, 4) catch return error.InvalidArchive;
    const string_table_start = 4 + offset_table_size;
    if (string_table_start > payload.len) return error.InvalidArchive;

    try symbol_index.ensureUnusedCapacity(allocator, symbol_count);
    var name_offset = string_table_start;
    var index: usize = 0;
    while (index < symbol_count) : (index += 1) {
        const end = std.mem.indexOfScalarPos(u8, payload, name_offset, 0) orelse return error.InvalidArchive;
        try symbol_index.append(allocator, .{
            .name = payload[name_offset..end],
            .member_offset = readU32Big(payload, 4 + index * 4),
        });
        name_offset = end + 1;
    }
}

const DecodedMember = struct {
    name: []const u8,
    payload: []const u8,
};

fn decodeMemberName(
    raw_name: []const u8,
    raw_payload: []const u8,
    long_names: []const u8,
) model.Error!DecodedMember {
    if (std.mem.startsWith(u8, raw_name, "#1/")) {
        const name_len = try parseDecimal(raw_name[3..]);
        if (name_len > raw_payload.len) return error.InvalidArchive;
        return .{
            .name = raw_payload[0..name_len],
            .payload = raw_payload[name_len..],
        };
    }

    if (raw_name.len >= 2 and raw_name[0] == '/' and std.ascii.isDigit(raw_name[1])) {
        const name_offset = try parseDecimal(raw_name[1..]);
        if (name_offset >= long_names.len) return error.InvalidArchive;
        const start: usize = @intCast(name_offset);
        const line_end = std.mem.indexOfScalarPos(u8, long_names, start, '\n') orelse long_names.len;
        const name_end = if (line_end > start and long_names[line_end - 1] == '/')
            line_end - 1
        else
            line_end;
        return .{ .name = long_names[start..name_end], .payload = raw_payload };
    }

    return .{ .name = trimShortName(raw_name), .payload = raw_payload };
}

fn parseDecimal(field: []const u8) model.Error!usize {
    const trimmed = trimField(field);
    if (trimmed.len == 0) return error.InvalidArchive;
    var value: usize = 0;
    for (trimmed) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidArchive;
        value = std.math.mul(usize, value, 10) catch return error.InvalidArchive;
        value = std.math.add(usize, value, byte - '0') catch return error.InvalidArchive;
    }
    return value;
}

fn readU32Big(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

fn usesShortMemberName(name: []const u8) bool {
    return name.len != 0 and
        name.len + 1 <= 16 and
        std.mem.indexOfScalar(u8, name, '/') == null;
}

fn encodedMemberPayloadSize(member: BuildMember) usize {
    return member.bytes.len + if (usesShortMemberName(member.name)) @as(usize, 0) else member.name.len;
}

fn appendHeader(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    name: []const u8,
    payload_size: usize,
) Allocator.Error!void {
    if (usesShortMemberName(name)) {
        var name_buf: [17]u8 = undefined;
        const archive_name = std.fmt.bufPrint(&name_buf, "{s}/", .{name}) catch unreachable;
        try appendHeaderWithNameField(out, allocator, archive_name, payload_size);
        return;
    }
    var name_buf: [17]u8 = undefined;
    const archive_name = std.fmt.bufPrint(&name_buf, "#1/{d}", .{name.len}) catch unreachable;
    try appendHeaderWithNameField(out, allocator, archive_name, payload_size);
}

fn appendHeaderWithNameField(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    name: []const u8,
    size: usize,
) Allocator.Error!void {
    try appendField(out, allocator, 16, name);
    try appendField(out, allocator, 12, "0");
    try appendField(out, allocator, 6, "0");
    try appendField(out, allocator, 6, "0");
    try appendField(out, allocator, 8, "100644");

    var size_buf: [20]u8 = undefined;
    const size_text = std.fmt.bufPrint(&size_buf, "{d}", .{size}) catch unreachable;
    try appendField(out, allocator, 10, size_text);
    try out.appendSlice(allocator, "`\n");
}

fn appendU32Big(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    value: u32,
) Allocator.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try out.appendSlice(allocator, &bytes);
}

fn appendField(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    width: usize,
    value: []const u8,
) Allocator.Error!void {
    std.debug.assert(value.len <= width);
    try out.appendSlice(allocator, value);
    try out.appendNTimes(allocator, ' ', width - value.len);
}

fn trimField(field: []const u8) []const u8 {
    return std.mem.trimEnd(u8, field, " ");
}

fn trimShortName(raw_name: []const u8) []const u8 {
    const slash_index = std.mem.indexOfScalar(u8, raw_name, '/') orelse raw_name.len;
    return raw_name[0..slash_index];
}

test "archive parser reads short and BSD extended member names" {
    const bytes =
        magic ++
        "short.o/        0           0     0     100644  3         `\nabc\n" ++
        "#1/16           0           0     0     100644  20        `\nvery-long-name.o!\nxy";
    const members = try parse(std.testing.allocator, .{ .name = "libx.a", .bytes = bytes });
    defer std.testing.allocator.free(members);

    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("short.o", members[0].name);
    try std.testing.expectEqualSlices(u8, "abc", members[0].bytes);
    try std.testing.expectEqualStrings("very-long-name.o", members[1].name);
    try std.testing.expectEqualSlices(u8, "!\nxy", members[1].bytes);
}

test "archive parser reads GNU long-name tables" {
    const bytes =
        magic ++
        "//              0           0     0     100644  20        `\nlong-member-name.o/\n" ++
        "/0              0           0     0     100644  2         `\nxy";
    const members = try parse(std.testing.allocator, .{ .name = "libx.a", .bytes = bytes });
    defer std.testing.allocator.free(members);

    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings("long-member-name.o", members[0].name);
    try std.testing.expectEqualSlices(u8, "xy", members[0].bytes);
}

test "archive parser keeps slashes inside GNU long member names" {
    const bytes =
        magic ++
        "//              0           0     0     100644  63        `\n" ++
        ".zig-cache/o/57afe1b693277004bcc2a09b815ff3f8/libtinyrt_zcu.o/\n\n" ++
        "/0              0           0     0     100644  2         `\nxy";
    const members = try parse(std.testing.allocator, .{ .name = "libtinyrt.a", .bytes = bytes });
    defer std.testing.allocator.free(members);

    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings(
        ".zig-cache/o/57afe1b693277004bcc2a09b815ff3f8/libtinyrt_zcu.o",
        members[0].name,
    );
    try std.testing.expectEqualSlices(u8, "xy", members[0].bytes);
}

test "archive parser reads GNU symbol indexes" {
    const bytes =
        magic ++
        "/               0           0     0     100644  12        `\n" ++
        "\x00\x00\x00\x01\x00\x00\x00\x50sym\x00" ++
        "target.o/       0           0     0     100644  2         `\nxy";
    var parsed = try parseDetailed(std.testing.allocator, .{ .name = "libx.a", .bytes = bytes });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.members.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.symbol_index.len);
    try std.testing.expect(parsed.has_symbol_index);
    try std.testing.expectEqualStrings("target.o", parsed.members[0].name);
    try std.testing.expectEqual(@as(u64, 80), parsed.members[0].header_offset);
    try std.testing.expectEqualStrings("sym", parsed.symbol_index[0].name);
    try std.testing.expectEqual(@as(u64, 80), parsed.symbol_index[0].member_offset);
}

test "archive builder writes member symbol index" {
    const bytes = try build(std.testing.allocator, &.{
        .{ .name = "target.o", .bytes = "xy", .symbols = &.{"sym"} },
    });
    defer std.testing.allocator.free(bytes);

    var parsed = try parseDetailed(std.testing.allocator, .{ .name = "libx.a", .bytes = bytes });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.has_symbol_index);
    try std.testing.expectEqual(@as(usize, 1), parsed.members.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.symbol_index.len);
    try std.testing.expectEqualStrings("target.o", parsed.members[0].name);
    try std.testing.expectEqualStrings("sym", parsed.symbol_index[0].name);
    try std.testing.expectEqual(parsed.members[0].header_offset, parsed.symbol_index[0].member_offset);
}

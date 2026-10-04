const std = @import("std");
const root = @import("../../root.zig");
const macho = @import("root.zig");

pub fn options() root.LinkOptions {
    return .{
        .target = .macos_aarch64_macho,
        .entry_symbol = "entry",
        .image_base = 0x100000000,
        .page_size = macho.layout.vm_page_bytes,
        .pie = true,
        .incremental_mode = .off,
        .macho_executable = .{
            .signature_identifier = "tiny.n6.test",
            .minimum_macos = .{ .major = 11, .minor = 4 },
            .sdk_version = .{ .major = 11, .minor = 4 },
            .imports = &.{.{ .name = "_getpid", .signature = .i32_noargs }},
            .input_protocol = .choir_unsigned64_literals,
            .startup = .lc_main_zero_argument_i32,
        },
    };
}

test {
    std.testing.refAllDecls(macho.classic);
    std.testing.refAllDecls(macho.fixup);
    std.testing.refAllDecls(macho.signature);
}

test "Mach-O executable product refuses absent policy and incremental reuse" {
    var requested = options();
    requested.macho_executable = null;
    try std.testing.expectError(error.MissingMachOExecutablePolicy, macho.layout.Layout.init(std.testing.allocator, &.{}, requested));
    requested = options();
    requested.incremental_mode = .prepare;
    try std.testing.expectError(error.UnsupportedMachOIncremental, macho.layout.Layout.init(std.testing.allocator, &.{}, requested));
    requested = options();
    requested.pie = false;
    try std.testing.expectError(error.UnsupportedMachOExecutablePolicy, macho.layout.Layout.init(std.testing.allocator, &.{}, requested));
}

/// A format/control fixture, not a compiler-generated or executed product.
/// Dev owns the independent canonical Choir artifact-to-object witness.
pub fn literalObject(allocator: std.mem.Allocator) ![]u8 {
    const strings = "\x00entry\x00local\x00_getpid\x00readonly\x00";
    const bytes = try allocator.alloc(u8, 640 + strings.len);
    @memset(bytes, 0);
    const put = macho.layout.put;
    put(u32, bytes, 0, 0xfeedfacf);
    put(u32, bytes, 4, 0x0100000c);
    put(u32, bytes, 12, 1);
    put(u32, bytes, 16, 2);
    put(u32, bytes, 20, 416);
    put(u32, bytes, 32, 0x19);
    put(u32, bytes, 36, 392);
    put(u32, bytes, 96, 4);
    for ([_][]const u8{ "__text", "__const", "__data", "__bss" }, 0..) |name, index| {
        const offset = 104 + index * 80;
        @memcpy(bytes[offset..][0..name.len], name);
        const segment = if (index < 2) "__TEXT" else "__DATA";
        @memcpy(bytes[offset + 16 ..][0..segment.len], segment);
        put(u32, bytes, offset + 52, if (index == 0) 4 else 3);
        put(u32, bytes, offset + 64, if (index == 0) 0x400 else if (index == 3) 1 else 0);
    }
    put(u64, bytes, 144, 96);
    put(u32, bytes, 152, 448);
    put(u32, bytes, 160, 552);
    put(u32, bytes, 164, 3);
    put(u64, bytes, 216, 96);
    put(u64, bytes, 224, 8);
    put(u32, bytes, 232, 544);
    put(u32, bytes, 424, 2);
    put(u32, bytes, 428, 24);
    put(u32, bytes, 432, 576);
    put(u32, bytes, 436, 4);
    put(u32, bytes, 440, 640);
    put(u32, bytes, 444, strings.len);
    // Two calls, one address load; all original TEXT pointer slots stay zero.
    for ([_]usize{ 0, 32 }) |start| {
        put(u32, bytes, 448 + start, 0x58000090);
        put(u32, bytes, 452 + start, 0xd63f0200);
        put(u32, bytes, 456 + start, 0x14000004);
        put(u32, bytes, 460 + start, 0xd503201f);
        put(u32, bytes, 472 + start, 0xd65f03c0);
    }
    put(u32, bytes, 512, 0x58000049);
    put(u32, bytes, 516, 0x14000003);
    put(u32, bytes, 528, 0xd65f03c0);
    put(u64, bytes, 544, 42);
    const slots = [_]u32{ 16, 48, 72 };
    const targets = [_]u32{ 1, 2, 3 };
    for (slots, targets, 0..) |slot, symbol, index| {
        put(u32, bytes, 552 + index * 8, slot);
        put(u32, bytes, 556 + index * 8, symbol | (3 << 25) | (1 << 27));
    }
    const names = [_]u32{ 1, 7, 13, 21 };
    const kinds = [_]u8{ 0x0f, 0x0e, 1, 0x0f };
    const sections = [_]u8{ 1, 1, 0, 2 };
    const values = [_]u64{ 0, 32, 0, 96 };
    for (names, 0..) |name, index| {
        const offset = 576 + index * 16;
        put(u32, bytes, offset, name);
        bytes[offset + 4] = kinds[index];
        bytes[offset + 5] = sections[index];
        put(u64, bytes, offset + 8, values[index]);
    }
    @memcpy(bytes[640..], strings);
    return bytes;
}

test "Mach-O executable redirects every local global and imported text literal to DATA" {
    const allocator = std.testing.allocator;
    const source = try literalObject(allocator);
    defer allocator.free(source);
    var plan = try macho.layout.Layout.init(allocator, &.{.{ .name = "literal.o", .bytes = source }}, options());
    defer plan.deinit(allocator);
    const out = try allocator.alloc(u8, plan.requiredBytes());
    defer allocator.free(out);
    try plan.write(out);
    const counts = plan.byteCounts();
    try std.testing.expectEqual(counts.file, counts.ownedFileBytes());
    try std.testing.expectEqual(@as(u64, 24), counts.pointer_cells);
    try std.testing.expectEqual(@as(u64, 24), counts.retained_text_slots);
    // First input text follows the wrapper and its alignment padding.
    const text: usize = std.mem.alignForward(usize, @intCast(plan.text_offset + macho.layout.wrapper_bytes), 16);
    for ([_]usize{ 16, 48, 72 }) |slot| {
        try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, out[text + slot ..][0..8], .little));
    }
    const data: usize = @intCast(plan.data_offset);
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, out[data + 8 ..][0..8], .little));
    try std.testing.expectEqual(@as(u64, options().image_base + text + 32), std.mem.readInt(u64, out[data..][0..8], .little));
    try std.testing.expect(std.mem.indexOf(u8, plan.binds.items, "_getpid\x00") != null);
    const again = try allocator.alloc(u8, plan.requiredBytes());
    defer allocator.free(again);
    try plan.write(again);
    try std.testing.expectEqualSlices(u8, out, again);
}

test "Mach-O executable refuses signed addends and missing literal coverage" {
    const allocator = std.testing.allocator;
    const source = try literalObject(allocator);
    defer allocator.free(source);
    macho.layout.put(u64, source, 464, @bitCast(@as(i64, -1)));
    try std.testing.expectError(error.UnsupportedMachOAddend, macho.layout.Layout.init(allocator, &.{.{ .name = "negative.o", .bytes = source }}, options()));
    macho.layout.put(u64, source, 464, 0);
    macho.layout.put(u32, source, 164, 2);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "missing.o", .bytes = source }}, options()));
}

test "Mach-O executable caller buffer mismatch leaves all bytes untouched" {
    const allocator = std.testing.allocator;
    const source = try literalObject(allocator);
    defer allocator.free(source);
    var plan = try macho.layout.Layout.init(allocator, &.{.{ .name = "literal.o", .bytes = source }}, options());
    defer plan.deinit(allocator);
    var short = @as([8]u8, @splat(0x7a));
    try std.testing.expectError(error.InvalidRange, plan.write(&short));
    for (short) |byte| try std.testing.expectEqual(@as(u8, 0x7a), byte);
}

test "Mach-O executable local references keep their owning input despite equal names" {
    const allocator = std.testing.allocator;
    const left = try literalObject(allocator);
    defer allocator.free(left);
    const right = try literalObject(allocator);
    defer allocator.free(right);
    right[580] = 0x0e; // Second entry and readonly symbols are local to that input.
    right[628] = 0x0e;
    var plan = try macho.layout.Layout.init(allocator, &.{
        .{ .name = "left.o", .bytes = left },
        .{ .name = "right.o", .bytes = right },
    }, options());
    defer plan.deinit(allocator);
    const bytes = try allocator.alloc(u8, plan.requiredBytes());
    defer allocator.free(bytes);
    try plan.write(bytes);
    const data: usize = @intCast(plan.data_offset);
    const first = std.mem.readInt(u64, bytes[data..][0..8], .little);
    const second = std.mem.readInt(u64, bytes[data + 24 ..][0..8], .little);
    try std.testing.expectEqual(@as(u64, 96), second - first);
}

test "Mach-O executable refuses duplicate globals unused mutable data and malformed protocols" {
    const allocator = std.testing.allocator;
    const bytes = try literalObject(allocator);
    defer allocator.free(bytes);
    try std.testing.expectError(error.DuplicateSymbol, macho.layout.Layout.init(allocator, &.{
        .{ .name = "one.o", .bytes = bytes },
        .{ .name = "two.o", .bytes = bytes },
    }, options()));
    macho.layout.put(u64, bytes, 304, 1); // Unused __data is still refused.
    macho.layout.put(u32, bytes, 312, 544);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "mutable.o", .bytes = bytes }}, options()));
    macho.layout.put(u64, bytes, 304, 0);
    bytes[428] = 23;
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "malformed.o", .bytes = bytes }}, options()));
}

test "Mach-O executable refuses pointers into erased slots and overlapping neighborhoods" {
    const allocator = std.testing.allocator;
    const bytes = try literalObject(allocator);
    defer allocator.free(bytes);
    macho.layout.put(u64, bytes, 600, 16); // Local symbol enters an erased literal slot.
    try std.testing.expectError(error.AmbiguousMachOLiteral, macho.layout.Layout.init(allocator, &.{.{ .name = "slot.o", .bytes = bytes }}, options()));
    macho.layout.put(u64, bytes, 600, 32);
    macho.layout.put(u32, bytes, 560, 16); // Two fixups own the same complete neighborhood.
    try std.testing.expectError(error.AmbiguousMachOLiteral, macho.layout.Layout.init(allocator, &.{.{ .name = "overlap.o", .bytes = bytes }}, options()));
}

test "Mach-O executable checks all construction allocation failures and exact retry" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationWitness, .{});
}

fn allocationWitness(allocator: std.mem.Allocator) !void {
    const bytes = try literalObject(allocator);
    defer allocator.free(bytes);
    var plan = try macho.layout.Layout.init(allocator, &.{.{ .name = "literal.o", .bytes = bytes }}, options());
    defer plan.deinit(allocator);
    const image = try allocator.alloc(u8, plan.requiredBytes());
    defer allocator.free(image);
    try plan.write(image);
}

test "Mach-O executable rejects zero-offset truncated and overlapping source extents" {
    const allocator = std.testing.allocator;
    const bytes = try literalObject(allocator);
    defer allocator.free(bytes);
    macho.layout.put(u32, bytes, 152, 0);
    macho.layout.put(u64, bytes, 144, 4096);
    try std.testing.expectError(error.InvalidRange, macho.layout.Layout.init(allocator, &.{.{ .name = "truncated.o", .bytes = bytes }}, options()));
    macho.layout.put(u64, bytes, 144, 96);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "header.o", .bytes = bytes }}, options()));
    macho.layout.put(u32, bytes, 152, 448);
    macho.layout.put(u32, bytes, 232, 0);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "const-header.o", .bytes = bytes }}, options()));
    macho.layout.put(u32, bytes, 232, 448);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "payload.o", .bytes = bytes }}, options()));
    macho.layout.put(u32, bytes, 232, 576);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "symbols.o", .bytes = bytes }}, options()));
}

test "Mach-O executable checks relocation symbol and string region overlap and bounds" {
    const allocator = std.testing.allocator;
    const original = try literalObject(allocator);
    defer allocator.free(original);
    const bytes = try allocator.dupe(u8, original);
    defer allocator.free(bytes);
    // Keep each relocated table semantically valid so the source-region admission
    // is the failing boundary, rather than an incidental malformed record.
    @memcpy(bytes[448..][0..24], original[552..][0..24]);
    macho.layout.put(u32, bytes, 160, 448);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "relocations.o", .bytes = bytes }}, options()));
    @memcpy(bytes, original);
    @memcpy(bytes[448..][0..64], original[576..][0..64]);
    macho.layout.put(u32, bytes, 432, 448);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "symbol-table.o", .bytes = bytes }}, options()));
    @memcpy(bytes, original);
    @memcpy(bytes[448..][0 .. original.len - 640], original[640..]);
    macho.layout.put(u32, bytes, 440, 448);
    try std.testing.expectError(error.UnsupportedMachOInputProtocol, macho.layout.Layout.init(allocator, &.{.{ .name = "string-table.o", .bytes = bytes }}, options()));
    for ([_]usize{ 160, 432, 440 }) |offset| {
        @memcpy(bytes, original);
        macho.layout.put(u32, bytes, offset, @intCast(bytes.len));
        try std.testing.expectError(error.InvalidRange, macho.layout.Layout.init(allocator, &.{.{ .name = "truncated-table.o", .bytes = bytes }}, options()));
    }
    @memcpy(bytes, original);
    macho.layout.put(u32, bytes, 232, 0);
    macho.layout.put(u64, bytes, 224, 4096);
    try std.testing.expectError(error.InvalidRange, macho.layout.Layout.init(allocator, &.{.{ .name = "truncated-const.o", .bytes = bytes }}, options()));
}

test "Mach-O executable convenience image and manifest clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, linkedAllocationWitness, .{});
}

fn linkedAllocationWitness(allocator: std.mem.Allocator) !void {
    const bytes = try literalObject(allocator);
    defer allocator.free(bytes);
    var image = try root.link(allocator, &.{.{ .name = "literal.o", .bytes = bytes }}, options());
    defer image.deinit(allocator);
}

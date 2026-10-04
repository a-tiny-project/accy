const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");

const formats = @import("formats/root.zig");
const linker = @import("link.zig");
const model = @import("model.zig");

const elf_object = formats.elf.object;
const format = formats.elf.format;
const memory = sys.memory;

const ehdr_size = format.ehdr_size;
const phdr_size = format.phdr_size;
const readU16 = format.readU16;
const readU32 = format.readU32;
const readU64 = format.readU64;
const requireRange = format.requireRange;

pub const LoadError = model.Error || memory.MapError || memory.ProtectError;

/// `supported` is whether `loadExecutable` can load an image on this host. It loads x86_64
/// code only, so elsewhere it refuses with `UnsupportedArchitecture`, and a caller's test skips.
pub const supported = builtin.cpu.arch == .x86_64;

pub const LoadedImage = struct {
    memory: []align(std.heap.page_size_min) u8,
    entry_address: usize,

    pub fn deinit(self: *LoadedImage) void {
        memory.unmap(self.memory);
        self.* = undefined;
    }

    pub fn entry(self: LoadedImage, comptime Function: type) Function {
        return @ptrFromInt(self.entry_address);
    }
};

const ImageSpan = struct {
    start: u64,
    end: u64,

    fn byteCount(self: ImageSpan) model.Error!usize {
        if (self.end <= self.start) return error.InvalidRange;
        return std.math.cast(usize, self.end - self.start) orelse error.InvalidRange;
    }
};

const LoadHeader = struct {
    flags: u32,
    offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
};

pub fn loadExecutable(
    allocator: std.mem.Allocator,
    inputs: []const model.Input,
    options: model.LinkOptions,
) LoadError!LoadedImage {
    if (!supported) return error.UnsupportedArchitecture;

    var probe_options = loadOptions(options);
    probe_options.image_base = 0;
    var probe = try linker.link(allocator, inputs, probe_options);
    defer probe.deinit(allocator);

    const probe_span = try imageSpan(probe.bytes);
    const memory_len = try probe_span.byteCount();
    const mapping = try memory.reserveAddressSpace(memory_len);
    errdefer memory.unmap(mapping);

    var mapped_options = loadOptions(options);
    const mapping_address: u64 = @intCast(@intFromPtr(mapping.ptr));
    if (mapping_address < probe_span.start) return error.InvalidRange;
    mapped_options.image_base = mapping_address - probe_span.start;

    var linked = try linker.link(allocator, inputs, mapped_options);
    defer linked.deinit(allocator);

    const mapped_span = try imageSpan(linked.bytes);
    if (mapped_span.start != mapping_address) return error.InvalidRange;
    if (try mapped_span.byteCount() > mapping.len) return error.InvalidRange;

    try memory.protect(mapping, .{ .read = true, .write = true });
    @memset(mapping, 0);
    try copyLoadSegments(mapping, linked.bytes, mapped_span);
    try protectLoadSegments(mapping, linked.bytes, mapped_span);

    const entry_address = try entryAddress(linked.bytes, mapped_span);
    return .{
        .memory = mapping,
        .entry_address = entry_address,
    };
}

fn loadOptions(options: model.LinkOptions) model.LinkOptions {
    var result = options;
    result.output_kind = .executable;
    result.page_size = memory.pageSize();
    result.mapped_output_file = null;
    return result;
}

fn imageSpan(image: []const u8) model.Error!ImageSpan {
    var result = ImageSpan{
        .start = std.math.maxInt(u64),
        .end = 0,
    };
    var found = false;
    var iterator = try LoadIterator.init(image);
    while (iterator.next()) |header| {
        if (header.memory_size < header.file_size) return error.InvalidElfHeader;
        const start = alignDown(header.virtual_address, iterator.page_size);
        const end = try alignForwardU64(try checkedAddU64(header.virtual_address, header.memory_size), iterator.page_size);
        result.start = @min(result.start, start);
        result.end = @max(result.end, end);
        found = true;
    }
    if (!found) return error.MissingSection;
    return result;
}

fn copyLoadSegments(mapping: []u8, image: []const u8, span: ImageSpan) model.Error!void {
    var iterator = try LoadIterator.init(image);
    while (iterator.next()) |header| {
        try requireRange(image, header.offset, header.file_size);
        const dest_start = try relativeOffset(span, header.virtual_address);
        const file_size = std.math.cast(usize, header.file_size) orelse return error.InvalidRange;
        if (file_size > mapping.len - dest_start) return error.InvalidRange;
        const source_start = std.math.cast(usize, header.offset) orelse return error.InvalidRange;
        @memcpy(mapping[dest_start..][0..file_size], image[source_start..][0..file_size]);
    }
}

fn protectLoadSegments(
    mapping: []align(std.heap.page_size_min) u8,
    image: []const u8,
    span: ImageSpan,
) LoadError!void {
    var iterator = try LoadIterator.init(image);
    while (iterator.next()) |header| {
        const page_start = alignDown(header.virtual_address, iterator.page_size);
        const page_end = try alignForwardU64(try checkedAddU64(header.virtual_address, header.memory_size), iterator.page_size);
        const start = try relativeOffset(span, page_start);
        const size = std.math.cast(usize, page_end - page_start) orelse return error.InvalidRange;
        if (size > mapping.len - start) return error.InvalidRange;
        const segment: []align(std.heap.page_size_min) u8 = @alignCast(mapping[start..][0..size]);
        try memory.protect(segment, protectionForFlags(header.flags));
    }
}

fn entryAddress(image: []const u8, span: ImageSpan) model.Error!usize {
    if (image.len < ehdr_size) return error.InvalidElfHeader;
    const entry = readU64(image, 24);
    if (entry < span.start or entry >= span.end) return error.MissingEntrySymbol;
    return std.math.cast(usize, entry) orelse error.InvalidRange;
}

const LoadIterator = struct {
    image: []const u8,
    phoff: u64,
    phnum: u16,
    index: u16 = 0,
    page_size: u64,

    fn init(image: []const u8) model.Error!LoadIterator {
        if (image.len < ehdr_size) return error.InvalidElfHeader;
        if (!std.mem.eql(u8, image[0..4], std.elf.MAGIC)) return error.InvalidElfHeader;
        if (readU16(image, 16) != @backingInt(std.elf.ET.EXEC)) return error.UnsupportedOutputKind;
        const phoff = readU64(image, 32);
        const phentsize = readU16(image, 54);
        const phnum = readU16(image, 56);
        if (phentsize != phdr_size) return error.InvalidElfHeader;
        try requireRange(image, phoff, @as(u64, phnum) * phdr_size);
        return .{
            .image = image,
            .phoff = phoff,
            .phnum = phnum,
            .page_size = memory.pageSize(),
        };
    }

    fn next(self: *LoadIterator) ?LoadHeader {
        while (self.index < self.phnum) {
            const offset: usize = @intCast(self.phoff + @as(u64, self.index) * phdr_size);
            self.index += 1;
            if (readU32(self.image, offset) != @backingInt(std.elf.PT.LOAD)) continue;
            return .{
                .flags = readU32(self.image, offset + 4),
                .offset = readU64(self.image, offset + 8),
                .virtual_address = readU64(self.image, offset + 16),
                .file_size = readU64(self.image, offset + 32),
                .memory_size = readU64(self.image, offset + 40),
            };
        }
        return null;
    }
};

fn protectionForFlags(flags: u32) memory.Protection {
    return .{
        .read = (flags & std.elf.PF_R) != 0,
        .write = (flags & std.elf.PF_W) != 0,
        .execute = (flags & std.elf.PF_X) != 0,
    };
}

fn relativeOffset(span: ImageSpan, address: u64) model.Error!usize {
    if (address < span.start or address > span.end) return error.InvalidRange;
    return std.math.cast(usize, address - span.start) orelse error.InvalidRange;
}

fn alignDown(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

fn alignForwardU64(value: u64, alignment: u64) model.Error!u64 {
    const mask = alignment - 1;
    if (value > std.math.maxInt(u64) - mask) return error.InvalidRange;
    return (value + mask) & ~mask;
}

fn checkedAddU64(a: u64, b: u64) model.Error!u64 {
    return std.math.add(u64, a, b) catch error.InvalidRange;
}

test "load executable maps entry function" {
    const allocator = std.testing.allocator;
    const text = [_]u8{ 0xb8, 41, 0, 0, 0, 0xc3 };
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);

    const loaded_result = loadExecutable(allocator, &.{.{ .name = "entry.o", .bytes = object }}, .{ .incremental_mode = .off });
    if (builtin.cpu.arch != .x86_64) {
        try std.testing.expectError(error.UnsupportedArchitecture, loaded_result);
        return;
    }
    var loaded = try loaded_result;
    defer loaded.deinit();

    const Entry = *const fn () callconv(.c) i32;
    const entry = loaded.entry(Entry);
    try std.testing.expectEqual(@as(i32, 41), entry());
}

test "load executable runs linked call relocation" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, caller_text.len),
            elf_object.Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{elf_object.Relocation.x86_64(1, 1, 3, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const callee_text = [_]u8{ 0xb8, 42, 0, 0, 0, 0xc3 };
    const callee_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &callee_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("callee", 1, 0, callee_text.len),
        },
    });
    defer allocator.free(callee_object);

    const loaded_result = loadExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "callee.o", .bytes = callee_object },
    }, .{ .incremental_mode = .off });
    if (builtin.cpu.arch != .x86_64) {
        try std.testing.expectError(error.UnsupportedArchitecture, loaded_result);
        return;
    }
    var loaded = try loaded_result;
    defer loaded.deinit();

    const Entry = *const fn () callconv(.c) i32;
    const entry = loaded.entry(Entry);
    try std.testing.expectEqual(@as(i32, 42), entry());
}

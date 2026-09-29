const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");

const Allocator = std.mem.Allocator;

pub const Frame = struct {
    function: []const u8,
    location: []const u8,
};

const Range = struct {
    start: usize,
    len: usize,
};

pub const Symbols = struct {
    stdout: []u8,
    frames: std.ArrayListUnmanaged(Frame),
    ranges: std.AutoHashMapUnmanaged(u64, Range),

    pub fn deinit(self: *Symbols, allocator: Allocator) void {
        self.ranges.deinit(allocator);
        self.frames.deinit(allocator);
        allocator.free(self.stdout);
        self.* = undefined;
    }

    pub fn find(self: *const Symbols, address: u64) []const Frame {
        const range = self.ranges.get(address) orelse return &.{};
        return self.frames.items[range.start..][0..range.len];
    }
};

pub fn resolveAlloc(
    allocator: Allocator,
    binary_path: []const u8,
    addresses: []const u64,
) !Symbols {
    if (addresses.len == 0) return error.NoStackAddresses;
    if (comptime builtin.target.ofmt == .elf) {
        return resolveElfAlloc(
            allocator,
            binary_path,
            addresses,
        ) catch |err| {
            if (err == error.InvalidElfMagic) {
                return resolveExternalAlloc(
                    allocator,
                    binary_path,
                    addresses,
                );
            }
            return err;
        };
    }
    return resolveExternalAlloc(allocator, binary_path, addresses);
}

fn resolveElfAlloc(
    allocator: Allocator,
    binary_path: []const u8,
    addresses: []const u64,
) !Symbols {
    const io = sys.fs.debugIo();
    const file = if (std.fs.path.isAbsolute(binary_path))
        try sys.fs.openAbsoluteFile(binary_path, .{})
    else
        try sys.fs.cwd().openFile(io, binary_path, .{});
    defer file.close(io);
    var elf_file = try std.debug.ElfFile.load(
        allocator,
        io,
        file,
        null,
        &.none,
    );
    defer elf_file.deinit(allocator);
    const dwarf = if (elf_file.dwarf) |*value|
        value
    else
        return error.MissingDebugInfo;
    try dwarf.open(allocator, elf_file.endian);

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var text_arena = std.heap.ArenaAllocator.init(allocator);
    defer text_arena.deinit();
    for (addresses) |address| {
        _ = text_arena.reset(.retain_capacity);
        const source_location = source_location: {
            const compile_unit = dwarf.findCompileUnit(
                elf_file.endian,
                address,
            ) catch break :source_location null;
            break :source_location dwarf.getLineNumberInfo(
                allocator,
                text_arena.allocator(),
                elf_file.endian,
                compile_unit,
                address,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                break :source_location null;
            };
        };
        try writeElfSymbol(
            &output.writer,
            address,
            dwarf.getSymbolName(address),
            source_location,
        );
    }

    const stdout = try output.toOwnedSlice();
    return try symbolsFromOutput(allocator, stdout, addresses);
}

fn writeElfSymbol(
    writer: *std.Io.Writer,
    address: u64,
    name: ?[]const u8,
    source_location: ?std.debug.SourceLocation,
) !void {
    try writer.print("0x{x}: {s}", .{ address, name orelse "??" });
    if (source_location) |location| {
        try writer.print(
            " at {s}:{d}:{d}\n",
            .{
                location.file_name,
                location.line,
                location.column,
            },
        );
    } else {
        try writer.writeAll(" at ??:0\n");
    }
}

fn resolveExternalAlloc(
    allocator: Allocator,
    binary_path: []const u8,
    addresses: []const u64,
) !Symbols {
    const fixed_count = 4;
    const argv = try allocator.alloc([]const u8, fixed_count + addresses.len);
    defer allocator.free(argv);
    const address_text = try allocator.alloc([]const u8, addresses.len);
    var address_count: usize = 0;
    defer {
        for (address_text[0..address_count]) |text| allocator.free(text);
        allocator.free(address_text);
    }
    argv[0] = "addr2line";
    argv[1] = "-aCifp";
    argv[2] = "-e";
    argv[3] = binary_path;
    for (addresses, 0..) |address, index| {
        const text = try std.fmt.allocPrint(allocator, "0x{x}", .{address});
        address_text[index] = text;
        address_count += 1;
        argv[fixed_count + index] = text;
    }
    var io_state = sys.thread.initThreadedIo(allocator, .{});
    defer io_state.deinit();
    const result = try sys.process.run(allocator, io_state.io(), .{
        .argv = argv,
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stderr);
    if (std.mem.trim(u8, result.stdout, " \t\r\n").len == 0) {
        allocator.free(result.stdout);
        return error.SymbolizationFailed;
    }
    return try symbolsFromOutput(allocator, result.stdout, addresses);
}

fn symbolsFromOutput(
    allocator: Allocator,
    stdout: []u8,
    addresses: []const u64,
) !Symbols {
    var symbols = Symbols{
        .stdout = stdout,
        .frames = .empty,
        .ranges = .{},
    };
    errdefer symbols.deinit(allocator);
    try parseOutput(allocator, &symbols);
    for (addresses) |address| {
        if (!symbols.ranges.contains(address)) return error.SymbolizationFailed;
    }
    return symbols;
}

fn parseOutput(allocator: Allocator, symbols: *Symbols) !void {
    var current_address: ?u64 = null;
    var current_start: usize = 0;
    var lines = std.mem.splitScalar(u8, symbols.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (parseAddressLine(line)) |address_line| {
            if (current_address) |address| {
                try finishAddress(allocator, symbols, address, current_start);
            }
            current_address = address_line.address;
            current_start = symbols.frames.items.len;
            try symbols.frames.append(
                allocator,
                parseFrame(address_line.text),
            );
            continue;
        }
        if (current_address == null) return error.InvalidSymbolizerOutput;
        const inline_prefix = "(inlined by) ";
        if (!std.mem.startsWith(u8, line, inline_prefix)) {
            return error.InvalidSymbolizerOutput;
        }
        try symbols.frames.append(
            allocator,
            parseFrame(line[inline_prefix.len..]),
        );
    }
    if (current_address) |address| {
        try finishAddress(allocator, symbols, address, current_start);
    }
}

const AddressLine = struct {
    address: u64,
    text: []const u8,
};

fn parseAddressLine(line: []const u8) ?AddressLine {
    if (!std.mem.startsWith(u8, line, "0x")) return null;
    const separator = std.mem.indexOf(u8, line, ": ") orelse return null;
    const address = std.fmt.parseUnsigned(
        u64,
        line[2..separator],
        16,
    ) catch return null;
    return .{
        .address = address,
        .text = line[separator + 2 ..],
    };
}

fn parseFrame(text: []const u8) Frame {
    if (std.mem.lastIndexOf(u8, text, " at ")) |separator| {
        return .{
            .function = text[0..separator],
            .location = text[separator + 4 ..],
        };
    }
    return .{ .function = text, .location = "" };
}

fn finishAddress(
    allocator: Allocator,
    symbols: *Symbols,
    address: u64,
    start: usize,
) !void {
    if (symbols.frames.items.len == start) return error.InvalidSymbolizerOutput;
    try symbols.ranges.putNoClobber(allocator, address, .{
        .start = start,
        .len = symbols.frames.items.len - start,
    });
}

test "ELF resolver tears down caller-owned allocations after failure" {
    if (comptime builtin.os.tag != .linux or
        builtin.target.ofmt != .elf)
    {
        return error.SkipZigTest;
    }
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        resolveElfAlloc(
            failing.allocator(),
            "/proc/self/exe",
            &.{1},
        ),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(
        failing.allocated_bytes,
        failing.freed_bytes,
    );
}

test "addr2line parser keeps inline frames under one address" {
    const text =
        "0x0000000000000010: leaf at leaf.zig:1\n" ++
        " (inlined by) caller at caller.zig:2\n" ++
        "0x0000000000000020: root at root.zig:3\n";
    const owned = try std.testing.allocator.dupe(u8, text);
    var symbols = Symbols{
        .stdout = owned,
        .frames = .empty,
        .ranges = .{},
    };
    defer symbols.deinit(std.testing.allocator);
    try parseOutput(std.testing.allocator, &symbols);
    try std.testing.expectEqual(@as(usize, 2), symbols.find(0x10).len);
    try std.testing.expectEqualStrings(
        "caller",
        symbols.find(0x10)[1].function,
    );
    try std.testing.expectEqual(@as(usize, 1), symbols.find(0x20).len);
}

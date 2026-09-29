const std = @import("std");
const scratch = @import("workspace/root.zig");

pub const default_system_directory = "/usr/share/X11/locale";
pub const fallback_locale = "en_US.UTF-8";

pub const Options = struct {
    locale: []const u8,
    home: ?[]const u8 = null,
    xcompose_file: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    system_directory: []const u8 = default_system_directory,
    io: std.Io = std.Options.debug_io,
};

pub fn xdg(output: []u8, options: Options) !?[]const u8 {
    if (options.xdg_config_home) |directory| {
        if (std.fs.path.isAbsolute(directory)) {
            return try join(output, &.{ directory, "XCompose" });
        }
    }
    const home_directory = options.home orelse return null;
    return try join(output, &.{ home_directory, ".config", "XCompose" });
}

pub fn home(output: []u8, options: Options) !?[]const u8 {
    const directory = options.home orelse return null;
    return try join(output, &.{ directory, ".XCompose" });
}

pub fn locale(storage: *scratch.Storage, output: []u8, options: Options) ![]const u8 {
    return try copy(output, try localeValue(storage, options));
}

pub fn expandInclude(
    storage: *scratch.Storage,
    output: []u8,
    options: Options,
    input: []const u8,
) ![]const u8 {
    var builder = Builder.init(output);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '%') {
            try builder.appendByte(input[index]);
            index += 1;
            continue;
        }
        if (index + 1 >= input.len) return error.InvalidIncludeExpansion;
        switch (input[index + 1]) {
            '%' => try builder.appendByte('%'),
            'H' => try builder.append(options.home orelse return error.MissingHome),
            'S' => try builder.append(options.system_directory),
            'L' => try builder.append(try localeValue(storage, options)),
            else => return error.InvalidIncludeExpansion,
        }
        index += 2;
    }
    return builder.value();
}

fn localeValue(storage: *scratch.Storage, options: Options) ![]const u8 {
    const resolved_locale = try resolveLocale(storage, options);
    const requested = if (std.mem.eql(u8, resolved_locale, "C"))
        fallback_locale
    else
        resolved_locale;

    const registry_path = try join(
        storage.auxiliaryPath(0),
        &.{ options.system_directory, "compose.dir" },
    );
    const relative = (try resolveRegistry(
        storage,
        options.io,
        registry_path,
        .right_to_left,
        requested,
    )) orelse return error.LocaleUnavailable;
    const output = storage.auxiliaryPath(1);
    if (std.fs.path.isAbsolute(relative)) return try copy(output, relative);
    return try join(output, &.{ options.system_directory, relative });
}

fn resolveLocale(storage: *scratch.Storage, options: Options) ![]const u8 {
    const alias_path = try join(
        storage.auxiliaryPath(0),
        &.{ options.system_directory, "locale.alias" },
    );
    const resolved = try resolveRegistry(
        storage,
        options.io,
        alias_path,
        .left_to_right,
        options.locale,
    );
    return try copy(storage.auxiliaryPath(1), resolved orelse options.locale);
}

const Direction = enum {
    left_to_right,
    right_to_left,
};

fn resolveRegistry(
    storage: *scratch.Storage,
    io: std.Io,
    file_path: []const u8,
    direction: Direction,
    name: []const u8,
) !?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return null;
    if (stat.size >= scratch.max_registry_bytes) return error.StreamTooLong;
    var reader = file.reader(io, storage.registryLine());
    while (true) {
        const raw_line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => return error.LineByteCapacityExceeded,
        } orelse return null;
        if (raw_line.len > storage.lineLimit()) return error.LineByteCapacityExceeded;
        if (resolveLine(raw_line, direction, name)) |resolved| return resolved;
    }
}

fn resolveLine(raw_line: []const u8, direction: Direction, name: []const u8) ?[]const u8 {
    var line = std.mem.trim(u8, raw_line, " \t\x0b\x0c\r\n");
    if (line.len == 0 or line[0] == '#') return null;

    const left_end = std.mem.indexOfAny(u8, line, " \t\x0b\x0c\r:") orelse line.len;
    if (left_end == 0) return null;
    const left = line[0..left_end];
    line = line[left_end..];
    line = std.mem.trimStart(u8, line, " \t\x0b\x0c\r");
    if (line.len > 0 and line[0] == ':') line = line[1..];
    line = std.mem.trimStart(u8, line, " \t\x0b\x0c\r");
    const right_end = std.mem.indexOfAny(u8, line, " \t\x0b\x0c\r") orelse line.len;
    if (right_end == 0) return null;
    const right = line[0..right_end];

    return switch (direction) {
        .left_to_right => if (std.mem.eql(u8, left, name)) right else null,
        .right_to_left => if (std.mem.eql(u8, right, name)) left else null,
    };
}

fn join(output: []u8, parts: []const []const u8) ![]const u8 {
    var builder = Builder.init(output);
    const first_index = for (parts, 0..) |part, index| {
        if (part.len != 0) break index;
    } else return builder.value();
    try builder.append(parts[first_index]);
    var previous = parts[first_index];
    for (parts[first_index + 1 ..]) |part| {
        if (part.len == 0) continue;
        const previous_separator = std.fs.path.isSep(previous[previous.len - 1]);
        const current_separator = std.fs.path.isSep(part[0]);
        if (!previous_separator and !current_separator) {
            try builder.appendByte(std.fs.path.sep);
        }
        try builder.append(if (previous_separator and current_separator) part[1..] else part);
        previous = part;
    }
    return builder.value();
}

fn copy(output: []u8, input: []const u8) ![]const u8 {
    var builder = Builder.init(output);
    try builder.append(input);
    return builder.value();
}

const Builder = struct {
    bytes: []u8,
    length: usize = 0,

    fn init(bytes: []u8) Builder {
        return .{ .bytes = bytes };
    }

    fn appendByte(self: *Builder, byte: u8) !void {
        if (self.length == self.bytes.len) return error.PathByteCapacityExceeded;
        self.bytes[self.length] = byte;
        self.length += 1;
    }

    fn append(self: *Builder, input: []const u8) !void {
        if (input.len > self.bytes.len - self.length) {
            return error.PathByteCapacityExceeded;
        }
        @memcpy(self.bytes[self.length..][0..input.len], input);
        self.length += input.len;
    }

    fn value(self: *const Builder) []const u8 {
        return self.bytes[0..self.length];
    }
};

test "locale aliases and Compose registry resolve through bounded scratch" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);

    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "locale.alias",
        .data = "friendly en_US.UTF-8\n",
    });
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "compose.dir",
        .data = "custom/Compose en_US.UTF-8\n",
    });

    var storage = try scratch.Storage.init(allocator, scratch.default_limits);
    defer storage.deinit(allocator);
    storage.activate();
    try storage.acquire();
    defer storage.reset();
    const resolved = try locale(&storage, storage.filePath(0), .{
        .locale = "friendly",
        .system_directory = root,
    });
    const expected = try std.fs.path.join(allocator, &.{ root, "custom/Compose" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "include expansion uses bounded home locale system and percent substitutions" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);

    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "compose.dir",
        .data = "Compose en_US.UTF-8\n",
    });
    var storage = try scratch.Storage.init(allocator, scratch.default_limits);
    defer storage.deinit(allocator);
    storage.activate();
    try storage.acquire();
    defer storage.reset();
    const expanded = try expandInclude(
        &storage,
        storage.filePath(1),
        .{ .locale = "C", .home = "/home/example", .system_directory = root },
        "%H|%S|%L|%%",
    );

    const locale_path = try std.fs.path.join(allocator, &.{ root, "Compose" });
    defer allocator.free(locale_path);
    const expected = try std.fmt.allocPrint(
        allocator,
        "/home/example|{s}|{s}|%",
        .{ root, locale_path },
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, expanded);
}

test "unregistered locale does not silently select the fallback" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);

    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "compose.dir",
        .data = "Compose en_US.UTF-8\n",
    });
    var storage = try scratch.Storage.init(allocator, scratch.default_limits);
    defer storage.deinit(allocator);
    storage.activate();
    try storage.acquire();
    defer storage.reset();
    try std.testing.expectError(error.LocaleUnavailable, locale(
        &storage,
        storage.filePath(0),
        .{ .locale = "blabla", .system_directory = root },
    ));
}

const std = @import("std");
const model = @import("model.zig");
const assembly = @import("assembly.zig");

const Capture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(model.Entry) = .empty,
    counter: model.ByteCounter = .{},

    fn append(self: *Capture, item: model.Entry) !void {
        std.debug.assert(self.entries.items.len <= model.maximum_entries);
        if (self.entries.items.len == model.maximum_entries) {
            return error.CompilerInputCountExceeded;
        }
        const physical: ?[]const u8 = if (item.pinned_source.len == 0)
            null
        else
            item.pinned_source;
        try self.counter.add(self.allocator, physical, item.byte_length, item.sha256);
        try self.entries.append(self.allocator, item);
    }

    fn file(self: *Capture, input: model.Input, path: []const u8) !void {
        try self.captureFile(input, path, null);
    }

    fn captureFile(
        self: *Capture,
        input: model.Input,
        path: []const u8,
        source_pin: ?[]const u8,
    ) !void {
        try model.validatePath(input.path);
        const source = try std.Io.Dir.cwd().openFile(self.io, path, .{ .follow_symlinks = input.assembly == null });
        defer source.close(self.io);
        const stat = try source.stat(self.io);
        if (stat.kind != .file) return error.UnsupportedCompilerInput;
        if (stat.size > model.maximum_file_bytes) return error.CompilerInputTooLarge;
        if (input.assembly) |arch| {
            if (input.pinned or input.generated or input.directory or source_pin != null) return error.UnqualifiedCompilerAssemblyOrigin;
            if (stat.size > assembly.maximum_source_bytes) return error.CompilerAssemblySourceTooLarge;
            var bytes: [assembly.maximum_source_bytes + 1]u8 = undefined;
            var assembly_reader = source.reader(self.io, &.{});
            const length = try assembly_reader.interface.readSliceShort(&bytes);
            if (length > assembly.maximum_source_bytes) return error.CompilerAssemblySourceTooLarge;
            const after = try source.stat(self.io);
            try stableSource(stat, after, length);
            const named = try std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });
            try stableSource(after, named, length);
            try assembly.validate(bytes[0..length], arch);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes[0..length], &digest, .{});
            try self.append(.{
                .path = try self.allocator.dupe(u8, input.path),
                .pinned_source = "",
                .byte_length = length,
                .sha256 = digest,
            });
            return;
        }
        var buffer: [64 * 1024]u8 = undefined;
        var reader = source.reader(self.io, &.{});
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var length: u64 = 0;
        while (length <= model.maximum_file_bytes) {
            const count = try reader.interface.readSliceShort(&buffer);
            if (count == 0) break;
            length += count;
            if (length > model.maximum_file_bytes) return error.CompilerInputTooLarge;
            digest.update(buffer[0..count]);
        }
        if (length != stat.size) return error.CompilerInputChangedDuringCapture;
        const pinned_source = source_pin orelse if (input.pinned) try self.pin(path) else "";
        try self.append(.{
            .path = try self.allocator.dupe(u8, input.path),
            .pinned_source = pinned_source,
            .byte_length = length,
            .sha256 = digest.finalResult(),
        });
    }

    fn pin(self: *Capture, path: []const u8) ![]const u8 {
        const resolved = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        _ = try storePin(resolved);
        return resolved;
    }

    fn tree(self: *Capture, input: model.Input, path: []const u8) !void {
        if (!input.pinned and !input.generated) return error.UntrackedCompilerDirectory;
        if (input.pinned) {
            const root = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
            _ = try storePin(root);
            try self.treeContents(input, root, root);
        } else {
            try self.treeContents(input, path, "");
        }
    }

    /// The caller qualifies the canonical root once. A resolved descendant can
    /// borrow that pin; an alias outside the root must establish its own pin.
    fn treeContents(
        self: *Capture,
        input: model.Input,
        path: []const u8,
        pinned_source: []const u8,
    ) !void {
        std.debug.assert(input.pinned == (pinned_source.len != 0));
        var directory = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer directory.close(self.io);
        var root_buffer: [model.maximum_path_bytes]u8 = undefined;
        const root_length = try directory.realPath(self.io, &root_buffer);
        const root = root_buffer[0..root_length];
        var walker = try directory.walkSelectively(self.allocator);
        defer walker.deinit();
        defer while (walker.stack.items.len > 0) walker.leave(self.io);
        var budget: WalkBudget = .{};
        while (try walker.next(self.io)) |item| {
            const links = try budget.visit(item.depth());
            if (item.kind == .sym_link and !input.pinned) return error.MutableCompilerInput;
            if (item.kind != .file and item.kind != .directory and item.kind != .sym_link) {
                return error.UnsupportedCompilerInput;
            }
            if (item.kind == .directory) {
                try walker.enter(self.io, item);
                continue;
            }
            var logical_buffer: [model.maximum_path_bytes]u8 = undefined;
            const logical = std.fmt.bufPrint(&logical_buffer, "{s}/{s}", .{ input.path, item.path }) catch
                return error.InvalidCompilerInputPath;
            try model.validatePath(logical);
            var resolved: ResolvedLink = undefined;
            var physical_buffer: [model.maximum_path_bytes]u8 = undefined;
            const physical = if (item.kind == .sym_link) target: {
                resolved = try ResolvedLink.resolve(self.io, item.dir, item.basename, links, root);
                break :target resolved.path();
            } else target: {
                const length = try item.dir.realPathFile(self.io, item.basename, &physical_buffer);
                break :target physical_buffer[0..length];
            };
            const entry_pin = if (input.pinned) try self.resolvedPin(root, pinned_source, physical) else "";
            if (item.kind == .sym_link) {
                const stat = try std.Io.Dir.cwd().statFile(self.io, physical, .{ .follow_symlinks = false });
                if (stat.kind == .directory) {
                    budget.enter(item.depth(), resolved.links);
                    var target = item;
                    target.dir = std.Io.Dir.cwd();
                    target.basename = resolved.path();
                    target.kind = .directory;
                    try walker.enter(self.io, target);
                    continue;
                }
                if (stat.kind != .file) return error.UnsupportedCompilerInput;
            }
            try self.captureFile(.{ .path = logical, .pinned = input.pinned }, physical, entry_pin);
        }
    }

    fn resolvedPin(
        self: *Capture,
        root: []const u8,
        root_pin: []const u8,
        path: []const u8,
    ) ![]const u8 {
        std.debug.assert(root_pin.len != 0);
        if (withinRoot(root, path)) {
            if (std.mem.eql(u8, root, root_pin)) return self.allocator.dupe(u8, path);
            return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ root_pin, path[root.len..] });
        }
        return self.pin(path) catch |err| switch (err) {
            error.UnpinnedCompilerToolchain => error.MutableCompilerInput,
            else => err,
        };
    }

    fn inherit(self: *Capture, path: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(model.maximum_manifest_bytes),
        );
        const entries = try model.decode(self.allocator, bytes);
        for (entries) |item| try self.append(item);
    }

    fn write(self: *Capture, path: []const u8) !void {
        const bytes = try model.encode(self.allocator, self.entries.items);
        var directory = try std.Io.Dir.cwd().openDir(self.io, path, .{});
        defer directory.close(self.io);
        try directory.writeFile(self.io, .{ .sub_path = "manifest.bin", .data = bytes });
        const source = try std.fmt.allocPrint(
            self.allocator,
            "pub const qualified = true;\n" ++
                "pub const refusal: ?[]const u8 = null;\n" ++
                "pub const bytes: []const u8 = @embedFile(\"manifest.bin\");\n" ++
                "pub const input_count: u32 = {d};\n" ++
                "pub const foreign_bytes: u64 = {d};\n",
            .{ self.entries.items.len, self.counter.bytes },
        );
        try directory.writeFile(self.io, .{ .sub_path = "root.zig", .data = source });
    }
};

/// Directory handles keep ancestor aliases out of subsequent kernel path walks.
/// Link expansions are counted explicitly, including links in a target's parents.
const ResolvedLink = struct {
    buffer: [model.maximum_path_bytes + 1]u8 = undefined,
    length: usize,
    links: u32,

    fn path(self: *const ResolvedLink) [:0]const u8 {
        std.debug.assert(self.length <= model.maximum_path_bytes);
        std.debug.assert(self.buffer[self.length] == 0);
        return self.buffer[0..self.length :0];
    }

    fn resolve(
        io: std.Io,
        directory: std.Io.Dir,
        name: []const u8,
        links: u32,
        root: []const u8,
    ) !ResolvedLink {
        std.debug.assert(links <= model.maximum_symlink_depth);
        var result = ResolvedLink{
            .length = 0,
            .links = links,
        };
        result.length = try directory.realPath(io, result.buffer[0..model.maximum_path_bytes]);
        var pending: [model.maximum_path_bytes]u8 = undefined;
        if (name.len > pending.len) return error.CompilerInputPathTooLong;
        @memcpy(pending[0..name.len], name);
        var length = name.len;
        var position: usize = 0;
        const maximum_steps = model.maximum_path_bytes * (model.maximum_symlink_depth + 1);
        var steps: u32 = 0;
        while (position < length) {
            std.debug.assert(steps < maximum_steps);
            steps += 1;
            const end = std.mem.indexOfScalarPos(u8, pending[0..length], position, '/') orelse length;
            const part = pending[position..end];
            position = @min(end + 1, length);
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                result.parent();
                continue;
            }
            const parent_length = result.length;
            const separator: usize = @intFromBool(result.length > 1);
            if (result.length + separator + part.len > model.maximum_path_bytes) {
                return error.CompilerInputPathTooLong;
            }
            if (separator != 0) {
                result.buffer[result.length] = '/';
                result.length += 1;
            }
            @memcpy(result.buffer[result.length..][0..part.len], part);
            result.length += part.len;
            result.buffer[result.length] = 0;
            if (!withinRoot(root, result.path()) and
                !withinRoot(result.path(), root) and
                !withinRoot(result.path(), "/nix/store"))
            {
                _ = storePin(result.path()) catch return error.MutableCompilerInput;
            }
            const stat = try std.Io.Dir.cwd().statFile(io, result.path(), .{
                .follow_symlinks = false,
            });
            if (stat.kind != .sym_link) {
                if (position < length and stat.kind != .directory) return error.NotDir;
                continue;
            }
            if (result.links == model.maximum_symlink_depth) {
                return error.CompilerInputSymlinkDepthExceeded;
            }
            result.links += 1;
            var target: [model.maximum_path_bytes]u8 = undefined;
            const target_length = try std.Io.Dir.cwd().readLink(io, result.path(), &target);
            const rest = pending[position..length];
            const join: usize = @intFromBool(rest.len != 0);
            if (target_length + join + rest.len > pending.len) return error.CompilerInputPathTooLong;
            if (join != 0) target[target_length] = '/';
            @memcpy(target[target_length + join ..][0..rest.len], rest);
            length = target_length + join + rest.len;
            @memcpy(pending[0..length], target[0..length]);
            position = 0;
            result.length = if (std.fs.path.isAbsolute(target[0..target_length])) 1 else parent_length;
        }
        result.buffer[result.length] = 0;
        return result;
    }

    fn parent(self: *ResolvedLink) void {
        std.debug.assert(self.length > 0);
        const end = std.mem.lastIndexOfScalar(u8, self.buffer[0..self.length], '/').?;
        self.length = @max(end, 1);
    }
};

const WalkBudget = struct {
    const Frame = struct { depth: usize, links: u32 };
    frames: [model.maximum_symlink_depth]Frame = undefined,
    frame_count: u32 = 0,
    visited: u32 = 0,

    fn visit(self: *WalkBudget, depth: usize) !u32 {
        std.debug.assert(self.visited <= model.maximum_entries);
        std.debug.assert(self.frame_count <= self.frames.len);
        if (self.visited == model.maximum_entries) return error.CompilerInputCountExceeded;
        self.visited += 1;
        while (self.frame_count > 0 and self.frames[self.frame_count - 1].depth >= depth) {
            self.frame_count -= 1;
        }
        return if (self.frame_count == 0) 0 else self.frames[self.frame_count - 1].links;
    }

    fn enter(self: *WalkBudget, depth: usize, links: u32) void {
        std.debug.assert(links > 0);
        std.debug.assert(links <= model.maximum_symlink_depth);
        std.debug.assert(self.frame_count < self.frames.len);
        if (self.frame_count > 0) {
            const parent = self.frames[self.frame_count - 1];
            std.debug.assert(depth > parent.depth);
            std.debug.assert(links > parent.links);
        }
        self.frames[self.frame_count] = .{ .depth = depth, .links = links };
        self.frame_count += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(allocator);
    defer arguments.deinit();
    std.debug.assert(arguments.skip());
    const output = arguments.next() orelse return error.MissingManifestOutput;
    invalidate(init.io, output);
    errdefer invalidate(init.io, output);
    const request_path = arguments.next() orelse return error.MissingManifestRequest;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        request_path,
        allocator,
        .limited(model.maximum_manifest_bytes),
    );
    const parsed = try std.json.parseFromSlice(model.Request, allocator, bytes, .{});
    const request = parsed.value;
    if (request.inputs.len > model.maximum_entries) return error.CompilerInputCountExceeded;
    var capture = Capture{ .allocator = allocator, .io = init.io };
    if (request.inherited) {
        try capture.inherit(arguments.next() orelse return error.MissingInheritedManifest);
    }
    const template = if (request.compilation) arguments.next() orelse return error.MissingCompilerGraphTemplate else null;
    const paths = try allocator.alloc([]const u8, request.inputs.len);
    for (request.inputs, paths) |input, *path| {
        path.* = arguments.next() orelse return error.MissingCompilerInput;
        if (input.directory) try capture.tree(input, path.*) else try capture.file(input, path.*);
    }
    if (arguments.next() != null) return error.UnexpectedCompilerInput;
    if (template) |path| {
        const graph = try compilation(allocator, init.io, path, request.inputs, paths);
        try capture.append(try model.entry("compilations/0/compilation.json", "", graph));
        var directory = try std.Io.Dir.cwd().openDir(init.io, output, .{});
        defer directory.close(init.io);
        try directory.writeFile(init.io, .{ .sub_path = "compilation.json", .data = graph });
    }
    try capture.write(output);
}

/// Materialize only nonroot producing-Compile paths from the exact ordered
/// make arguments. The final bounded JSON is itself a native manifest input.
fn compilation(
    allocator: std.mem.Allocator,
    io: std.Io,
    template: []const u8,
    inputs: []const model.Input,
    paths: []const []const u8,
) ![]const u8 {
    const maximum = model.maximum_graph_bytes;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, template, allocator, .limited(maximum + 1));
    defer allocator.free(bytes);
    if (bytes.len > maximum) return error.CompilerGraphTooLarge;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    if (!std.mem.eql(u8, object.get("schema").?.string, "tiny.compilation/v2") or object.get("root").?.integer != 0) return error.InvalidCompilerGraphTemplate;
    const compiles = object.get("compiles").?.array.items;
    if (compiles.len == 0 or compiles.len > model.maximum_compiles or object.get("modules").?.array.items.len > model.maximum_modules) return error.InvalidCompilerGraphTemplate;
    for (compiles, 0..) |*node, id| {
        if (node.object.get("id").?.integer != id) return error.InvalidCompilerGraphTemplate;
        const output = node.object.getPtr("output").?;
        if (id == 0) {
            if (output.* != .null) return error.InvalidCompilerGraphTemplate;
            continue;
        }
        var logical_buffer: [96]u8 = undefined;
        const expected = try std.fmt.bufPrint(&logical_buffer, "compiles/{d}/output", .{id});
        const file = output.object.get("file").?.object;
        if (!std.mem.eql(u8, file.get("input").?.string, expected) or !std.mem.eql(u8, file.get("origin").?.string, "generated") or output.object.get("path").? != .null) return error.InvalidCompilerGraphTemplate;
        var scoped_buffer: [128]u8 = undefined;
        const scoped = try std.fmt.bufPrint(&scoped_buffer, "compilations/0/{s}", .{expected});
        var actual: ?[]const u8 = null;
        for (inputs, paths) |input, path| {
            if (!std.mem.eql(u8, input.path, scoped)) continue;
            if (actual != null or input.directory or input.assembly != null) return error.InvalidCompilerLinkedOutput;
            if (path.len == 0 or path.len > model.maximum_path_bytes or !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) return error.InvalidCompilerLinkedOutput;
            for (path) |byte| if (byte < 32 or byte == 127) return error.InvalidCompilerLinkedOutput;
            actual = path;
        }
        output.object.getPtr("path").?.* = .{ .string = actual orelse return error.MissingCompilerLinkedOutput };
    }
    const buffer = try allocator.alloc(u8, maximum);
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(parsed.value, .{}, &writer) catch return error.CompilerGraphTooLarge;
    return buffer[0..writer.buffered().len];
}

/// Metadata and length must describe the same complete read through one handle.
/// This detects ordinary concurrent replacement or writes, not hostile timestamp forgery.
/// A same-length write within one timestamp tick goes unseen: a kernel that stamps files at
/// its tick, such as Linux before 6.13's multigrain timestamps, gives it the old times.
fn stableSource(before: std.Io.File.Stat, after: std.Io.File.Stat, length: u64) !void {
    if (before.kind != .file or after.kind != .file or before.inode != after.inode or
        before.size != length or after.size != length or
        before.mtime.nanoseconds != after.mtime.nanoseconds or
        before.ctime.nanoseconds != after.ctime.nanoseconds)
    {
        return error.CompilerInputChangedDuringCapture;
    }
}

fn invalidate(io: std.Io, output: []const u8) void {
    var directory = std.Io.Dir.cwd().openDir(io, output, .{}) catch return;
    defer directory.close(io);
    for ([_][]const u8{ "root.zig", "manifest.bin", "compilation.json" }) |leaf| directory.deleteFile(io, leaf) catch {};
}

fn withinRoot(root: []const u8, path: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and
        (path.len == root.len or path[root.len] == '/');
}

fn storePin(path: []const u8) ![]const u8 {
    const prefix = "/nix/store/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.UnpinnedCompilerToolchain;
    const suffix = path[prefix.len..];
    const end = std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len;
    const result = path[0 .. prefix.len + end];
    try model.validatePin(result);
    return result;
}

/// These fixtures supply the already-qualified root capability directly. The
/// public tree entry point and the toolchain regression still validate real pins.
const fixture_pin = "/nix/store/00000000000000000000000000000000-fixture";

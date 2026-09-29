const std = @import("std");
const model = @import("root.zig").model;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    root: []const u8,
    symbols: std.debug.SelfInfo = .init,

    pub fn init(b: *std.Build) !Context {
        const directory = try b.root.joinString(b.graph.arena, "");
        const cwd = try std.process.currentPathAlloc(b.graph.io, b.graph.arena);
        return .{
            .allocator = b.graph.arena,
            .io = b.graph.io,
            .cwd = cwd,
            .root = try std.fs.path.resolve(b.graph.arena, &.{ cwd, directory }),
        };
    }

    pub fn deinit(self: *Context) void {
        self.symbols.deinit(self.io);
    }

    pub fn path(self: *const Context, value: ?std.Build.LazyPath) !model.Path {
        const lazy = value orelse return .{ .kind = .absent };
        return switch (lazy) {
            .src_path => |p| try self.owned(p.owner, p.sub_path),
            .dependency => |p| try self.owned(p.dependency.builder, p.sub_path),
            .cwd_relative => |p| .{ .kind = .source, .value = try self.relative(p) },
            .generated => |p| .{ .kind = .generated, .value = p.sub_path },
            .relative => |p| .{
                .kind = .relative,
                .value = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
                    @tagName(p.base), p.sub_path,
                }),
            },
        };
    }

    fn owned(self: *const Context, owner: *std.Build, sub_path: []const u8) !model.Path {
        const absolute = try owner.root.joinString(self.allocator, sub_path);
        return .{ .kind = .source, .value = try self.relative(absolute) };
    }

    fn relative(self: *const Context, value: []const u8) ![]const u8 {
        const absolute = try std.fs.path.resolve(self.allocator, &.{ self.cwd, value });
        return std.fs.path.relative(self.allocator, self.cwd, null, self.root, absolute);
    }

    /// Retain source modules in this build root; line numbers and addresses are not identities.
    pub fn registration(self: *Context, step: *const std.Build.Step) ![]const []const u8 {
        var files: std.ArrayList([]const u8) = .empty;
        for (step.debug_stack_trace.return_addresses) |address| {
            if (address == 0) continue;
            var symbols: std.ArrayList(std.debug.Symbol) = .empty;
            try self.symbols.getSymbols(
                self.io,
                self.allocator,
                self.allocator,
                address - 1,
                true,
                &symbols,
            );
            for (symbols.items) |symbol| {
                const location = symbol.source_location orelse continue;
                const file = try self.relative(location.file_name);
                if (outside(file)) continue;
                var found = false;
                for (files.items) |existing| {
                    if (std.mem.eql(u8, existing, file)) found = true;
                }
                if (!found) try files.append(self.allocator, file);
            }
        }
        return files.toOwnedSlice(self.allocator);
    }
};

fn outside(path: []const u8) bool {
    return std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../") or
        std.fs.path.isAbsolute(path);
}

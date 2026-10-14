const std = @import("std");
const manifest = @import("root.zig");

pub const Inputs = struct {
    build: *std.Build,
    walks: *manifest.source.Walks,
    files: std.ArrayList(manifest.File) = .empty,
    /// One run per call that appends files, for `source.merge`.
    runs: manifest.source.Runs,
    references: usize = 0,

    pub fn reference(self: *Inputs) !void {
        if (self.references == manifest.linked.maximum_references) return error.CompilerReferenceCountExceeded;
        self.references += 1;
    }

    pub fn assembly(self: *Inputs, path: std.Build.LazyPath, name: []const u8, arch: std.Target.Cpu.Arch) !void {
        if (path != .src_path and path != .dependency) return error.UnqualifiedCompilerAssemblyOrigin;
        try self.reference();
        const start = try self.runs.begin(&self.files);
        try manifest.source.append(self.build, &self.files, .{
            .identity = .{ .path = name, .assembly = arch },
            .path = path,
        });
        self.runs.end(&self.files, start);
    }

    pub fn file(self: *Inputs, path: std.Build.LazyPath, name: []const u8) !void {
        try self.reference();
        const start = try self.runs.begin(&self.files);
        try manifest.source.append(self.build, &self.files, .{
            .identity = .{ .path = name, .pinned = pinned(path) },
            .path = path,
        });
        self.runs.end(&self.files, start);
    }

    pub fn directory(self: *Inputs, path: std.Build.LazyPath, name: []const u8) !void {
        try self.reference();
        const start = try self.runs.begin(&self.files);
        defer self.runs.end(&self.files, start);
        if (pinned(path)) {
            try manifest.source.append(self.build, &self.files, .{
                .identity = .{ .path = name, .pinned = true, .directory = true },
                .path = path,
            });
        } else if (path == .generated) {
            try self.generatedDirectory(path, name);
        } else try manifest.source.collect(self.walks, self.build, path, name, &self.files);
    }

    fn generatedDirectory(self: *Inputs, path: std.Build.LazyPath, name: []const u8) !void {
        const generated = path.generated;
        const owner = self.build.graph.generated_files.items[@backingInt(generated.index)];
        if (owner.cast(std.Build.Step.WriteFile)) |write| {
            if (write.mode != .whole_cached) return error.MutableCompilerInput;
        } else if (owner.cast(std.Build.Step.Run)) |run| {
            if (run.has_side_effects) return error.MutableCompilerInput;
        } else return error.UnqualifiedGeneratedCompilerDirectory;
        try manifest.source.append(self.build, &self.files, .{
            .identity = .{ .path = name, .directory = true, .generated = true },
            .path = path,
        });
    }

    pub fn module(self: *Inputs, path: std.Build.LazyPath, name: []const u8) ![]const u8 {
        if (path == .generated) {
            const generated = path.generated;
            const owner = self.build.graph.generated_files.items[@backingInt(generated.index)];
            if (owner.cast(std.Build.Step.Options) != null) {
                const identity = self.build.pathJoin(&.{ name, "options.zig" });
                try self.file(path, identity);
                return identity;
            }
        }
        try self.directory(path.dirname(), name);
        return self.build.pathJoin(&.{ name, try basename(self.build, path) });
    }
};

fn pinned(path: std.Build.LazyPath) bool {
    return switch (path) {
        .cwd_relative => |value| std.mem.startsWith(u8, value, "/nix/store/"),
        .relative => |value| switch (value.base) {
            .zig_exe, .zig_lib => true,
            else => std.mem.startsWith(u8, value.sub_path, "/nix/store/"),
        },
        else => false,
    };
}

fn basename(b: *std.Build, path: std.Build.LazyPath) ![]const u8 {
    const sub_path = switch (path) {
        .src_path => |value| value.sub_path,
        .dependency => |value| value.sub_path,
        .generated => |value| value.sub_path,
        .cwd_relative => |value| value,
        .relative => |value| value.sub_path,
    };
    if (sub_path.len != 0) return std.fs.path.basename(sub_path);
    if (path != .generated) return error.UnqualifiedCompilerSourceName;
    const generated = path.generated;
    if (generated.up != 0) return error.UnqualifiedCompilerSourceName;
    const owner = b.graph.generated_files.items[@backingInt(generated.index)];
    const run = owner.cast(std.Build.Step.Run) orelse return error.UnqualifiedCompilerSourceName;
    if (run.argv.items.len > manifest.model.maximum_entries) {
        return error.CompilerInputCountExceeded;
    }
    for (run.argv.items) |argument| switch (argument) {
        .output_file, .output_directory => |output| {
            if (output.generated_file == generated.index) return output.basename;
        },
        else => {},
    };
    return error.UnqualifiedCompilerSourceName;
}

pub fn origin(b: *std.Build, path: std.Build.LazyPath) ![]const u8 {
    return switch (path) {
        .src_path => |value| relative(b, value.owner, value.sub_path),
        .dependency => |value| relative(b, value.dependency.builder, value.sub_path),
        .generated => "generated",
        .cwd_relative => |value| value,
        .relative => |value| b.fmt("{s}/{s}", .{ @tagName(value.base), value.sub_path }),
    };
}

fn relative(b: *std.Build, owner: *std.Build, path: []const u8) ![]const u8 {
    const allocator = b.graph.arena;
    const base = try b.root.joinString(allocator, "");
    const source = try owner.root.joinString(allocator, path);
    const cwd = try std.process.currentPathAlloc(b.graph.io, allocator);
    return std.fs.path.relative(allocator, cwd, &b.graph.environ_map, base, source);
}

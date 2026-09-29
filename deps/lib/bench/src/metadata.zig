const std = @import("std");
const builtin = @import("builtin");
const pretty_json = @import("pretty").json;
const stabilizer = @import("stabilizer");

pub const BuildMetadata = struct {
    git_sha: []const u8,
    git_dirty: bool,
    optimize: []const u8,
    target: []const u8,
    zig_version: []const u8,
    host_os: []const u8,
    host_arch: []const u8,
};

const FakeBuildOptions = struct {
    const git_sha = "abc123";
    const git_dirty = true;
    const optimize = "ReleaseFast";
    const target = "x86_64-linux-gnu";
    const host_os = "linux";
    const host_arch = "x86_64";
};

pub fn currentBuildMetadata(comptime build_options: type) BuildMetadata {
    return .{
        .git_sha = build_options.git_sha,
        .git_dirty = build_options.git_dirty,
        .optimize = build_options.optimize,
        .target = build_options.target,
        .zig_version = builtin.zig_version_string,
        .host_os = build_options.host_os,
        .host_arch = build_options.host_arch,
    };
}

pub fn compiledBuildMetadata() BuildMetadata {
    return .{
        .git_sha = "",
        .git_dirty = false,
        .optimize = @tagName(builtin.mode),
        .target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi),
        .zig_version = builtin.zig_version_string,
        .host_os = @tagName(builtin.os.tag),
        .host_arch = @tagName(builtin.cpu.arch),
    };
}

pub fn writeBuildMetadata(object: pretty_json.Object, metadata: BuildMetadata) !void {
    try object.field("git_sha", metadata.git_sha);
    try object.field("git_dirty", metadata.git_dirty);
    try object.field("optimize", metadata.optimize);
    try object.field("target", metadata.target);
    try object.field("zig_version", metadata.zig_version);
    try object.field("host_os", metadata.host_os);
    try object.field("host_arch", metadata.host_arch);
    try object.end();
}

pub fn writeStabilizerConfig(object: pretty_json.Object, layout_config: stabilizer.Config) !void {
    try object.field("seed", layout_config.seed);
    const heap = try object.object("heap");
    try heap.field("enabled", layout_config.heap.enabled);
    try heap.field("pointer_validation", layout_config.heap.pointer_validation);
    try heap.field("shuffle_slots", layout_config.heap.shuffle_slots);
    try heap.field("min_class_size", layout_config.heap.min_class_size);
    try heap.field("max_shuffled_size", layout_config.heap.max_shuffled_size);
    try heap.end();
    const stack = try object.object("stack");
    try stack.field("enabled", layout_config.stack.enabled);
    try stack.field("entries", layout_config.stack.entries);
    try stack.field("alignment", layout_config.stack.alignment);
    try stack.end();
    const code = try object.object("code");
    try code.field("enabled", layout_config.code.enabled);
    try code.field("shuffle_slots", layout_config.code.shuffle_slots);
    try code.field("alignment", layout_config.code.alignment);
    try code.field("interval_ms", layout_config.code.interval_ms);
    try code.end();
    try object.end();
}

test "stabilizer config metadata records heap stack and code fields" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var stream = pretty_json.Writer.init(&out.writer, .minified);
    try writeStabilizerConfig(try stream.object(), .{
        .seed = 77,
        .heap = .{
            .pointer_validation = false,
            .shuffle_slots = 5,
            .max_shuffled_size = 4096,
        },
        .stack = .{
            .entries = 9,
        },
        .code = .{
            .enabled = false,
        },
    });

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"seed\":77") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pointer_validation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shuffle_slots\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_shuffled_size\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":{\"enabled\":true,\"entries\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":{\"enabled\":false") != null);
}

test "build metadata helper records profile build options" {
    const value = currentBuildMetadata(FakeBuildOptions);
    try std.testing.expectEqualStrings("abc123", value.git_sha);
    try std.testing.expect(value.git_dirty);
    try std.testing.expectEqualStrings("ReleaseFast", value.optimize);
    try std.testing.expectEqualStrings("x86_64-linux-gnu", value.target);
    try std.testing.expectEqualStrings(builtin.zig_version_string, value.zig_version);
    try std.testing.expectEqualStrings("linux", value.host_os);
    try std.testing.expectEqualStrings("x86_64", value.host_arch);
}

test "build metadata writes benchmark environment" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var stream = pretty_json.Writer.init(&out.writer, .minified);
    const root = try stream.object();
    try writeBuildMetadata(try root.object("metadata"), .{
        .git_sha = "abc123",
        .git_dirty = true,
        .optimize = "ReleaseFast",
        .target = "x86_64-linux-gnu",
        .zig_version = "0.16.0",
        .host_os = "linux",
        .host_arch = "x86_64",
    });
    try root.end();

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metadata\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"git_sha\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"git_dirty\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"host_os\":\"linux\"") != null);
}

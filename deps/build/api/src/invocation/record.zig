const std = @import("std");
const invocation = @import("root.zig");

pub const variable = "TINY_COMPILER_INVOCATION_V1";
pub const schema = "tiny.compiler-invocation/v1";
/// Below the per-environment-string limit; oversized invocations stay transient.
pub const maximum_bytes = 64 * 1024;
pub const maximum_arguments = 20_009;
pub const maximum_paths = 256;

pub const Maker = struct {
    allow_so_scripts: ?bool = null,
    libc_file: ?[]const u8 = null,
    sysroot: ?[]const u8 = null,
    search_prefixes: []const []const u8 = &.{},
    debug_compiler_runtime_libs: ?[]const u8 = null,
    build_id: ?[]const u8 = null,
    error_limit: ?u32 = null,
    zig_lib_directory: []const u8,
    libc_runtimes_directory: ?[]const u8 = null,
    incremental: ?bool = null,
    reference_trace: ?u32 = null,
    cache_poison: std.Build.Graph.CachePoison = .pure,
};

pub const Binding = struct {
    compiler: []const u8,
    directory: []const u8,
    build_file: []const u8,
};

pub const Record = struct {
    schema: []const u8,
    binding: Binding,
    arguments: []const []const u8,
    environment: []const invocation.environment.Value,
    maker: Maker,

    pub fn requirePublication(self: Record, actual: Binding) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.UnrecordedCompilerBuild;
        inline for (@typeInfo(Binding).@"struct".field_names) |field| {
            if (!std.mem.eql(u8, @field(self.binding, field), @field(actual, field))) {
                return error.UnrecordedCompilerBuild;
            }
        }
        if (self.maker.cache_poison == .ignored or self.maker.cache_poison == .disallowed) {
            return error.UnrecordedCompilerBuild;
        }
        if (!std.mem.startsWith(u8, actual.compiler, "/nix/store/")) {
            return error.UnrecordedCompilerBuild;
        }
    }
};

/// Never let a child mistake an inherited parent invocation for its own.
pub fn forget(values: *std.process.Environ.Map) void {
    _ = values.swapRemove(variable);
}

/// Called after launcher argument and compiler validation, before every spawn.
/// Unsupported inputs only withhold publication authority; they do not block Zig.
pub fn refresh(
    allocator: std.mem.Allocator,
    values: *std.process.Environ.Map,
    compiler: []const u8,
    directory: []const u8,
    args: []const []const u8,
) std.mem.Allocator.Error!void {
    forget(values);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const record = create(temporary, values, compiler, directory, args) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    var output: [maximum_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    std.json.Stringify.value(record, .{}, &writer) catch return;
    try values.put(variable, writer.buffered());
}

fn create(
    allocator: std.mem.Allocator,
    values: *const std.process.Environ.Map,
    compiler: []const u8,
    directory: []const u8,
    args: []const []const u8,
) !Record {
    if (args.len == 0 or args.len > maximum_arguments) return error.UnrecordedCompilerBuild;
    if (!std.mem.eql(u8, args[0], "build")) return error.UnrecordedCompilerBuild;
    if (!std.mem.startsWith(u8, compiler, "/nix/store/")) return error.UnrecordedCompilerBuild;
    if (!std.fs.path.isAbsolute(directory)) return error.UnrecordedCompilerBuild;
    const parsed = try invocation.arguments.parse(allocator, values, compiler, directory, args);
    return .{
        .schema = schema,
        .binding = .{
            .compiler = compiler,
            .directory = directory,
            .build_file = parsed.build_file,
        },
        .arguments = args,
        .environment = try invocation.environment.capture(allocator, values),
        .maker = parsed.maker,
    };
}

/// The caller owns a bounded parsing arena and must observe the environment's
/// configuration-cache dependency before using this result in a build graph.
pub fn receive(
    allocator: std.mem.Allocator,
    values: *const std.process.Environ.Map,
    actual: Binding,
) !Record {
    const bytes = values.get(variable) orelse return error.UnrecordedCompilerBuild;
    if (bytes.len > maximum_bytes) return error.UnrecordedCompilerBuild;
    const decoded = std.json.parseFromSliceLeaky(Record, allocator, bytes, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.UnrecordedCompilerBuild;
    };
    try decoded.requirePublication(actual);
    if (decoded.arguments.len > maximum_arguments) return error.UnrecordedCompilerBuild;
    const expected = try create(
        allocator,
        values,
        actual.compiler,
        actual.directory,
        decoded.arguments,
    );
    const exact = try std.json.Stringify.valueAlloc(allocator, expected, .{});
    if (!std.mem.eql(u8, bytes, exact)) return error.UnrecordedCompilerBuild;
    return decoded;
}

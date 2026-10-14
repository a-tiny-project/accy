const std = @import("std");
const invocation = @import("root.zig");

pub const variable = "TINY_COMPILER_INVOCATION_V1";
pub const schema = "tiny.compiler-invocation/v1";
/// Names the exported record to configuration. Zig keys its configuration
/// cache on `-D` options and never on the environment, so the launcher passes
/// the record's digest here and one cached configuration answers to one record.
pub const option = "tiny-invocation";
const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Digest = [Sha256.digest_length * 2]u8;
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

/// One compiler launch: the compiler, the directory Maker runs in, the build
/// file, and the arguments that determine the build. Scheduling options are
/// left out by `arguments.withoutScheduling`, whoever added them: admission
/// picks `-j` and `--maxrss` from load, so recording them would key the
/// configuration cache on load. Admission's receipt records them instead.
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
    const determining = try invocation.arguments.withoutScheduling(allocator, args);
    const parsed =
        try invocation.arguments.parse(allocator, values, compiler, directory, determining);
    return .{
        .schema = schema,
        .binding = .{
            .compiler = compiler,
            .directory = directory,
            .build_file = parsed.build_file,
        },
        .arguments = determining,
        .environment = try invocation.environment.capture(allocator, values),
        .maker = parsed.maker,
    };
}

/// The lowercase hexadecimal SHA-256 of an exported record's bytes.
pub fn digest(bytes: []const u8) Digest {
    var raw: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

pub const argument_bytes = "-D".len + option.len + "=".len + @sizeOf(Digest);

/// The `-D` argument a launcher passes beside the record it exported. It stays
/// out of the recorded arguments, which it names.
pub fn argument(storage: *[argument_bytes]u8, bytes: []const u8) []const u8 {
    const written = std.fmt.bufPrint(storage, "-D{s}={s}", .{ option, &digest(bytes) }) catch
        unreachable;
    std.debug.assert(written.len == argument_bytes);
    return written;
}

/// Repeats `receive` at make time for a configuration the cache may have
/// reused. The exported record must be the bytes the configuration embedded,
/// and it must still derive from this process's environment and directory.
pub fn verify(
    allocator: std.mem.Allocator,
    values: *const std.process.Environ.Map,
    embedded: []const u8,
    directory: []const u8,
) !void {
    const exported = values.get(variable) orelse return error.UnrecordedCompilerBuild;
    if (!std.mem.eql(u8, exported, embedded)) return error.CompilerInvocationChanged;
    const decoded = std.json.parseFromSliceLeaky(Record, allocator, embedded, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.UnrecordedCompilerBuild;
    };
    _ = try receive(allocator, values, .{
        .compiler = decoded.binding.compiler,
        .directory = directory,
        .build_file = decoded.binding.build_file,
    });
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

const std = @import("std");
const model = @import("root.zig").model;
const emit = @import("emit.zig");
const native = @import("../root.zig").model;
const fixture = @import("binding_fixture");
const api = @import("build_definition");

fn fixtureDirectory(path: []const u8) ![]const u8 {
    try std.testing.expectEqualStrings("record.json", std.fs.path.basename(path));
    return std.fs.path.dirname(path) orelse error.MissingCompilerBindingDirectory;
}

fn load(allocator: std.mem.Allocator, directory: []const u8, name: []const u8, limit: usize) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit + 1));
    if (bytes.len > limit) return error.CompilerBindingLeafTooLarge;
    return bytes;
}

fn record(allocator: std.mem.Allocator, directory: []const u8) !model.Record {
    const bytes = try load(allocator, directory, "record.json", model.maximum_record_bytes);
    const parsed = try std.json.parseFromSlice(model.Record, allocator, bytes, .{});
    return parsed.value;
}

fn qualified(allocator: std.mem.Allocator, directory: []const u8, binary: []const u8) !model.Record {
    const result = try record(allocator, directory);
    try std.testing.expectEqual(.qualified, result.status);
    try std.testing.expectEqual(null, result.refusal);
    try std.testing.expectEqualStrings(binary, result.binary.path);
    const actual = try emit.hashFile(std.testing.io, binary);
    try std.testing.expectEqual(actual.bytes, result.binary.bytes);
    try std.testing.expectEqualSlices(u8, &actual.sha256, &result.binary.sha256);
    const payload = model.Payload{
        .manifest = try load(allocator, directory, "manifest.bin", model.maximum_manifest_bytes),
        .invocation = try load(allocator, directory, "invocation.json", model.maximum_invocation_bytes),
        .compilation = try load(allocator, directory, "compilation.json", model.maximum_compilation_bytes),
    };
    try model.validate(allocator, result.compile, payload);
    const origins = [_]model.Identity{ result.manifest.?, result.invocation.?, result.compilation.? };
    const copies = [_][]const u8{ payload.manifest, payload.invocation, payload.compilation };
    const limits = [_]usize{ model.maximum_manifest_bytes, model.maximum_invocation_bytes, model.maximum_compilation_bytes };
    for (origins, copies, limits) |origin, copy, limit| {
        const original = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            origin.path,
            allocator,
            .limited(limit + 1),
        );
        try std.testing.expectEqualSlices(u8, original, copy);
        try std.testing.expectEqual(copy.len, origin.bytes);
        const hash = model.digest(copy);
        try std.testing.expectEqualSlices(u8, &hash, &origin.sha256);
    }
    return result;
}

test "compiler binding associates two emitted binaries with their exact native and raw owner bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try qualified(arena.allocator(), try fixtureDirectory(fixture.first_record), fixture.first_binary);
    const second = try qualified(arena.allocator(), try fixtureDirectory(fixture.second_record), fixture.second_binary);
    try std.testing.expectEqualStrings("compiler-binding-first", first.compile.name);
    try std.testing.expectEqualStrings("compiler-binding-second", second.compile.name);
    try std.testing.expect(!std.mem.eql(u8, &first.binary.sha256, &second.binary.sha256));
    try std.testing.expect(!std.mem.eql(u8, &first.manifest.?.sha256, &second.manifest.?.sha256));
    try std.testing.expect(!std.mem.eql(u8, &first.compilation.?.sha256, &second.compilation.?.sha256));
    try std.testing.expectEqualSlices(u8, &first.invocation.?.sha256, &second.invocation.?.sha256);
}

test "compiler binding preserves native discovery refusal without qualified payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try record(arena.allocator(), try fixtureDirectory(fixture.native_record));
    try std.testing.expectEqual(.refused, result.status);
    try std.testing.expectEqualStrings("UnqualifiedCompilerNativeDiscovery", result.refusal.?);
    try std.testing.expectEqual(null, result.manifest);
    try std.testing.expectEqual(null, result.invocation);
    try std.testing.expectEqual(null, result.compilation);
    try std.testing.expectEqualStrings(fixture.native_binary, result.binary.path);
}

test "compiler binding refuses missing mismatched malformed and oversized input records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try record(allocator, try fixtureDirectory(fixture.first_record));
    const original = model.Payload{
        .manifest = try load(allocator, try fixtureDirectory(fixture.first_record), "manifest.bin", model.maximum_manifest_bytes),
        .invocation = try load(allocator, try fixtureDirectory(fixture.first_record), "invocation.json", model.maximum_invocation_bytes),
        .compilation = try load(allocator, try fixtureDirectory(fixture.first_record), "compilation.json", model.maximum_compilation_bytes),
    };
    var changed = original;
    changed.invocation = "{}";
    try std.testing.expectError(error.CompilerBindingInputMismatch, model.validate(allocator, result.compile, changed));
    changed = original;
    changed.compilation = try load(allocator, try fixtureDirectory(fixture.second_record), "compilation.json", model.maximum_compilation_bytes);
    try std.testing.expectError(error.CompilerBindingInputMismatch, model.validate(allocator, result.compile, changed));
    changed = original;
    changed.manifest = try native.encode(allocator, &.{});
    try std.testing.expectError(error.CompilerBindingInputMissing, model.validate(allocator, result.compile, changed));
    changed.manifest = "malformed compiled inputs";
    try std.testing.expectError(error.CompilerManifestSchemaMismatch, model.validate(allocator, result.compile, changed));
    changed = original;
    changed.manifest = try allocator.alloc(u8, model.maximum_manifest_bytes + 1);
    try std.testing.expectError(error.CompilerBindingLeafTooLarge, model.validate(allocator, result.compile, changed));
}

test "compiler binding missing and malformed export cannot publish a success record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const output = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    var request = emit.Request{
        .output = output,
        .binary = fixture.first_binary,
        .compiler = .{ .name = "compiler-binding-first", .kind = "exe" },
    };
    try std.testing.expectError(error.MissingCompilerBindingManifest, emit.exportRecord(allocator, io, request));
    try temporary.dir.writeFile(io, .{ .sub_path = "bad.bin", .data = "malformed compiled inputs" });
    request.manifest = try temporary.dir.realPathFileAlloc(io, "bad.bin", allocator);
    const good = try record(allocator, try fixtureDirectory(fixture.first_record));
    request.invocation = good.invocation.?.path;
    request.compilation = good.compilation.?.path;
    try std.testing.expectError(error.CompilerManifestSchemaMismatch, emit.exportRecord(allocator, io, request));
    const oversized = try allocator.alloc(u8, model.maximum_manifest_bytes + 1);
    @memset(oversized, 0);
    try temporary.dir.writeFile(io, .{ .sub_path = "bad.bin", .data = oversized });
    try std.testing.expectError(error.CompilerBindingLeafTooLarge, emit.exportRecord(allocator, io, request));
    try std.testing.expectError(error.FileNotFound, temporary.dir.openFile(io, "record.json", .{}));
    request.refusal = "UnrecordedCompilerBuild";
    request.manifest = null;
    request.invocation = null;
    request.compilation = null;
    try emit.exportRecord(allocator, io, request);
    const refused = try record(allocator, output);
    try std.testing.expectEqual(.refused, refused.status);
    try std.testing.expectEqualStrings("UnrecordedCompilerBuild", refused.refusal.?);
    try std.testing.expectEqual(null, refused.manifest);
}

test "compiler binding cleans failed payload writes and invalidates reused completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const output = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    const good = try record(allocator, try fixtureDirectory(fixture.first_record));
    var request = emit.Request{
        .output = output,
        .binary = fixture.first_binary,
        .compiler = good.compile,
        .manifest = good.manifest.?.path,
        .invocation = good.invocation.?.path,
        .compilation = good.compilation.?.path,
    };
    try emit.exportRecord(allocator, io, request);
    try std.testing.expectEqual(.qualified, (try record(allocator, output)).status);
    try temporary.dir.deleteFile(io, "compilation.json");
    try temporary.dir.createDir(io, "compilation.json", .default_dir);
    try temporary.dir.writeFile(io, .{ .sub_path = "record.json.tmp", .data = "interrupted record" });
    try std.testing.expectError(error.IsDir, emit.exportRecord(allocator, io, request));
    for ([_][]const u8{ "record.json", "record.json.tmp", "manifest.bin", "invocation.json" }) |leaf| {
        try std.testing.expectError(error.FileNotFound, temporary.dir.openFile(io, leaf, .{}));
    }
    var obstruction = try temporary.dir.openDir(io, "compilation.json", .{});
    obstruction.close(io);
    try temporary.dir.deleteDir(io, "compilation.json");
    try emit.exportRecord(allocator, io, request);
    try std.testing.expectEqual(.qualified, (try record(allocator, output)).status);
    request.manifest = null;
    try std.testing.expectError(error.MissingCompilerBindingManifest, emit.exportRecord(allocator, io, request));
    for ([_][]const u8{
        "record.json", "record.json.tmp", "manifest.bin", "invocation.json", "compilation.json",
    }) |leaf| {
        try std.testing.expectError(error.FileNotFound, temporary.dir.openFile(io, leaf, .{}));
    }
}

fn writeInput(allocator: std.mem.Allocator, directory: std.Io.Dir, name: []const u8, bytes: []const u8) ![]const u8 {
    try directory.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    return directory.realPathFileAlloc(std.testing.io, name, allocator);
}

fn fixtureRequest(allocator: std.mem.Allocator, output: std.Io.Dir) !emit.Request {
    const good = try record(allocator, try fixtureDirectory(fixture.first_record));
    return .{
        .output = try output.realPathFileAlloc(std.testing.io, ".", allocator),
        .binary = fixture.first_binary,
        .compiler = good.compile,
        .manifest = good.manifest.?.path,
        .invocation = good.invocation.?.path,
        .compilation = good.compilation.?.path,
    };
}

fn expectEmpty(directory: std.Io.Dir) !void {
    for ([_][]const u8{
        "record.json", "record.json.tmp", "manifest.bin", "invocation.json", "compilation.json",
    }) |leaf| {
        try std.testing.expectError(error.FileNotFound, directory.openFile(std.testing.io, leaf, .{}));
    }
}

fn exactManifest(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const decoded = try native.decode(allocator, bytes);
    var entries: std.ArrayList(native.Entry) = .empty;
    try entries.appendSlice(allocator, decoded);
    var remaining = model.maximum_manifest_bytes - bytes.len;
    const framing_bytes = 2 * @sizeOf(u32) + @sizeOf(u64) + 32;
    const minimum_padding_path_bytes = 32;
    while (remaining > 0) {
        var encoded_size = @min(remaining, framing_bytes + native.maximum_path_bytes);
        const leftover = remaining - encoded_size;
        if (leftover > 0 and leftover < framing_bytes + minimum_padding_path_bytes) {
            encoded_size -= framing_bytes + minimum_padding_path_bytes;
        }
        const path = try allocator.alloc(u8, encoded_size - framing_bytes);
        @memset(path, 'x');
        _ = try std.fmt.bufPrint(path, "zz-binding-padding/{d:0>5}/", .{entries.items.len});
        try entries.append(allocator, try native.entry(path, "", ""));
        remaining -= encoded_size;
    }
    const result = try native.encode(allocator, entries.items);
    try std.testing.expectEqual(model.maximum_manifest_bytes, result.len);
    return result;
}

test "compiler binding admits exact native manifest extent and refuses its next byte in fixed scratch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var inputs = std.testing.tmpDir(.{});
    defer inputs.cleanup();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    var request = try fixtureRequest(allocator, output.dir);
    const original = try load(allocator, try fixtureDirectory(fixture.first_record), "manifest.bin", model.maximum_manifest_bytes);
    const exact = try exactManifest(allocator, original);
    request.manifest = try writeInput(allocator, inputs.dir, "manifest.bin", exact);
    const storage = try allocator.alloc(u8, model.scratch_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    try emit.exportRecord(fixed.allocator(), io, request);
    const published = try qualified(allocator, request.output, request.binary);
    try std.testing.expectEqual(model.maximum_manifest_bytes, published.manifest.?.bytes);
    const excessive = try allocator.alloc(u8, exact.len + 1);
    @memcpy(excessive[0..exact.len], exact);
    excessive[exact.len] = 0;
    _ = try writeInput(allocator, inputs.dir, "manifest.bin", excessive);
    fixed.reset();
    try std.testing.expectError(error.CompilerBindingLeafTooLarge, emit.exportRecord(fixed.allocator(), io, request));
    try expectEmpty(output.dir);
}

test "compiler binding retains exact compilation and invocation bounds independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var inputs = std.testing.tmpDir(.{});
    defer inputs.cleanup();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    var request = try fixtureRequest(allocator, output.dir);
    const original = try load(allocator, try fixtureDirectory(fixture.first_record), "manifest.bin", model.maximum_manifest_bytes);
    const entries = try native.decode(allocator, original);
    const invocation = try allocator.alloc(u8, model.maximum_invocation_bytes);
    const compilation = try allocator.alloc(u8, model.maximum_compilation_bytes);
    const names = [_][]const u8{ "invocation.json", "compilation.json" };
    const payloads = [_][]u8{ invocation, compilation };
    for (names, payloads) |name, bytes| {
        const raw = try load(allocator, try fixtureDirectory(fixture.first_record), name, bytes.len);
        @memset(bytes, ' ');
        @memcpy(bytes[0..raw.len], raw);
    }
    for (entries) |*entry| {
        const bytes = if (std.mem.eql(u8, entry.path, "invocation.json")) invocation else if (std.mem.eql(u8, entry.path, "compilations/0/compilation.json")) compilation else continue;
        entry.* = try native.entry(entry.path, entry.pinned_source, bytes);
    }
    request.manifest = try writeInput(allocator, inputs.dir, "manifest.bin", try native.encode(allocator, entries));
    request.invocation = try writeInput(allocator, inputs.dir, names[0], invocation);
    request.compilation = try writeInput(allocator, inputs.dir, names[1], compilation);
    const storage = try allocator.alloc(u8, model.scratch_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    try emit.exportRecord(fixed.allocator(), io, request);
    const published = try qualified(allocator, request.output, request.binary);
    try std.testing.expectEqual(model.maximum_invocation_bytes, published.invocation.?.bytes);
    try std.testing.expectEqual(model.maximum_compilation_bytes, published.compilation.?.bytes);
    for (names, payloads) |name, bytes| {
        const excessive = try allocator.alloc(u8, bytes.len + 1);
        @memcpy(excessive[0..bytes.len], bytes);
        excessive[bytes.len] = ' ';
        _ = try writeInput(allocator, inputs.dir, name, excessive);
        fixed.reset();
        try std.testing.expectError(error.CompilerBindingLeafTooLarge, emit.exportRecord(fixed.allocator(), io, request));
        try expectEmpty(output.dir);
        _ = try writeInput(allocator, inputs.dir, name, bytes);
    }
}

test "compiler binding names exact scratch exhaustion and removes reused completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    const request = try fixtureRequest(allocator, output.dir);
    const storage = try allocator.alloc(u8, model.scratch_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    try emit.exportRecord(fixed.allocator(), io, request);
    try std.testing.expectEqual(.qualified, (try record(allocator, request.output)).status);
    fixed.reset();
    _ = try fixed.allocator().alloc(u8, model.scratch_bytes);
    try std.testing.expectEqual(model.scratch_bytes, fixed.end_index);
    try std.testing.expectError(error.OutOfMemory, fixed.allocator().alloc(u8, 1));
    try std.testing.expectError(error.CompilerBindingScratchExceeded, emit.exportRecord(fixed.allocator(), io, request));
    try expectEmpty(output.dir);
}

test "compiler binding bounds binary hashing before reading an oversized file" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "oversized", .{});
    defer file.close(io);
    try file.setLength(io, model.maximum_binary_bytes + 1);
    const path = try temporary.dir.realPathFileAlloc(io, "oversized", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.CompilerBindingBinaryTooLarge, emit.hashFile(io, path));
}

fn unrecorded(b: *std.Build) void {
    const source = b.addWriteFiles().add("main.zig", "pub fn main() void {}\n");
    const compile = b.addExecutable(.{
        .name = "unrecorded",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const exported = api.exportCompilerBinding(b, compile);
    const again = api.exportCompilerBinding(b, compile);
    std.debug.assert(exported.step == again.step);
    const run = b.addRunArtifact(compile);
    run.step.dependOn(&exported.step.step);
    b.step("binding", "Compiler binding fixture").dependOn(&run.step);
}

test "compiler binding finalization records missing invocation on the same consumer Compile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.testing.io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    const b = try std.Build.create(graph, .cwd(), &.{});
    api.package(b, unrecorded);
    const step = &b.top_level_steps.get("binding").?.step;
    const run = step.dependencies.items[0].cast(std.Build.Step.Run).?;
    const compile = run.producer.?;
    const exported = api.exportCompilerBinding(b, compile);
    try std.testing.expectEqualStrings("UnrecordedCompilerBuild", exported.step.argv.items[5].bytes);
    const consumed = exported.step.argv.items[2].lazy_path.lazy_path;
    try std.testing.expectEqual(compile.getEmittedBin().generated.index, consumed.generated.index);
    try std.testing.expect(std.mem.indexOfScalar(
        *std.Build.Step,
        run.step.dependencies.items,
        &exported.step.step,
    ) != null);
}

fn replaceGraph(allocator: std.mem.Allocator, original: model.Payload, graph: []const u8, output: ?native.Entry) !model.Payload {
    const decoded = try native.decode(allocator, original.manifest);
    var entries: std.ArrayList(native.Entry) = .empty;
    for (decoded) |entry| {
        if (std.mem.eql(u8, entry.path, "compilations/0/compilation.json")) {
            try entries.append(allocator, try native.entry(entry.path, "", graph));
        } else if (!std.mem.startsWith(u8, entry.path, "compilations/0/compiles/")) try entries.append(allocator, entry);
    }
    if (output) |item| try entries.append(allocator, item);
    return .{ .manifest = try native.encode(allocator, entries.items), .invocation = original.invocation, .compilation = graph };
}

test "compiler binding linked dispatch preserves genuine v1 and rejects malformed cross-version roots and outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const directory = try fixtureDirectory(fixture.first_record);
    const actual = try record(allocator, directory);
    const original = model.Payload{
        .manifest = try load(allocator, directory, "manifest.bin", model.maximum_manifest_bytes),
        .invocation = try load(allocator, directory, "invocation.json", model.maximum_invocation_bytes),
        .compilation = try load(allocator, directory, "compilation.json", model.maximum_compilation_bytes),
    };
    const v1 = try std.json.Stringify.valueAlloc(allocator, .{ .schema = "tiny.compilation/v1", .compile = actual.compile }, .{});
    try model.validate(allocator, actual.compile, try replaceGraph(allocator, original, v1, null));
    const modules = "[{\"id\":0,\"imports\":[],\"link_objects\":[{\"other_step\":{\"compile\":1}}]},{\"id\":1,\"imports\":[],\"link_objects\":[]}]";
    const root_compile = try std.json.Stringify.valueAlloc(allocator, actual.compile, .{});
    const root = try std.fmt.allocPrint(allocator, "{{\"id\":0,\"root_module\":0,\"compile\":{s},\"output\":null}}", .{root_compile});
    const child = "{\"id\":1,\"root_module\":1,\"compile\":{\"name\":\"child\",\"kind\":\"obj\"},\"output\":{\"file\":{\"input\":\"compiles/1/output\",\"origin\":\"generated\"},\"path\":\"/actual/child.o\"}}";
    const v2 = try std.fmt.allocPrint(allocator, "{{\"schema\":\"tiny.compilation/v2\",\"root\":0,\"compiles\":[{s},{s}],\"modules\":{s}}}", .{ root, child, modules });
    const output = try native.entry("compilations/0/compiles/1/output", "", "actual object");
    try model.validate(allocator, actual.compile, try replaceGraph(allocator, original, v2, output));
    try std.testing.expectError(error.CompilerBindingInputMissing, model.validate(allocator, actual.compile, try replaceGraph(allocator, original, v2, null)));
    const mutations = [_][2][]const u8{
        .{ "tiny.compilation/v2", "tiny.compilation/v3" },
        .{ "tiny.compilation/v2", "tiny.compilation/v1" },
        .{ "\"root\":0", "\"root\":1" },
        .{ "\"id\":1", "\"id\":2" },
        .{ "\"kind\":\"obj\"", "\"kind\":\"exe\"" },
        .{ "\"compiles/1/output\"", "\"compiles/0/output\"" },
        .{ "\"origin\":\"generated\"", "\"origin\":\"foreign\"" },
        .{ "\"root_module\":1", "\"root_module\":9" },
    };
    for (mutations) |change| {
        const changed = try std.mem.replaceOwned(u8, allocator, v2, change[0], change[1]);
        try std.testing.expectError(error.CompilerBindingCompilationMismatch, model.validate(allocator, actual.compile, try replaceGraph(allocator, original, changed, output)));
    }
    const disconnected = try std.mem.replaceOwned(u8, allocator, v2, "[{\"other_step\":{\"compile\":1}}]", "[]");
    try std.testing.expectError(error.CompilerBindingUnreachableCompile, model.validate(allocator, actual.compile, try replaceGraph(allocator, original, disconnected, output)));
    const cycle = try std.mem.replaceOwned(u8, allocator, v2, "\"link_objects\":[]", "\"link_objects\":[{\"other_step\":{\"compile\":0}}]");
    try std.testing.expectError(error.CompilerBindingLinkedCycle, model.validate(allocator, actual.compile, try replaceGraph(allocator, original, cycle, output)));
}

test "compiler binding linked actual Debug parent consumes distinct Fast LLVM objects with joined outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const directory = try fixtureDirectory(fixture.linked_record);
    const actual = try qualified(allocator, directory, fixture.linked_binary);
    const raw = try load(allocator, directory, "compilation.json", model.maximum_compilation_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    const graph = parsed.value.object;
    try std.testing.expectEqualStrings("tiny.compilation/v2", graph.get("schema").?.string);
    const nodes = graph.get("compiles").?.array.items;
    const modules = graph.get("modules").?.array.items;
    try std.testing.expectEqual(3, nodes.len);
    try std.testing.expectEqualStrings("debug", modules[0].object.get("optimize").?.string);
    const entries = try native.decode(allocator, try load(allocator, directory, "manifest.bin", model.maximum_manifest_bytes));
    var observed: [2]model.Identity = undefined;
    for (nodes[1..], 0..) |node, ordinal| {
        const compile = node.object.get("compile").?.object;
        try std.testing.expectEqualStrings("binding-linked-object", compile.get("name").?.string);
        try std.testing.expectEqualStrings("obj", compile.get("kind").?.string);
        try std.testing.expect(compile.get("use_llvm").?.bool);
        const module_id: usize = @intCast(node.object.get("root_module").?.integer);
        try std.testing.expectEqualStrings("fast", modules[module_id].object.get("optimize").?.string);
        const output = node.object.get("output").?.object;
        const path = output.get("path").?.string;
        try std.testing.expect(!std.mem.eql(u8, actual.binary.path, path));
        const identity = try emit.hashFile(std.testing.io, path);
        observed[ordinal] = identity;
        const name = try std.fmt.allocPrint(allocator, "compilations/0/compiles/{d}/output", .{ordinal + 1});
        const entry = for (entries) |item| {
            if (std.mem.eql(u8, item.path, name)) break item;
        } else return error.MissingLinkedOutput;
        try std.testing.expectEqual(identity.bytes, entry.byte_length);
        try std.testing.expectEqualSlices(u8, &identity.sha256, &std.fmt.bytesToHex(entry.sha256, .lower));
    }
    try std.testing.expect(!std.mem.eql(u8, observed[0].path, observed[1].path));
    try std.testing.expect(!std.mem.eql(u8, &observed[0].sha256, &observed[1].sha256));
    const assembly_identity = try emit.hashFile(std.testing.io, fixture.linked_assembly);
    const root_links = modules[0].object.get("link_objects").?.array.items;
    const assembly_object = root_links[2].object.get("assembly_file").?.object;
    try std.testing.expectEqualStrings("linux-standalone-assembly/v1", assembly_object.get("policy").?.string);
    const source_ref = assembly_object.get("file").?.object;
    const scoped = try std.fmt.allocPrint(allocator, "compilations/0/{s}", .{source_ref.get("input").?.string});
    const captured_assembly = for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, scoped)) break entry;
    } else return error.MissingAssemblyInput;
    try std.testing.expectEqual(assembly_identity.bytes, captured_assembly.byte_length);
    try std.testing.expectEqualSlices(u8, &assembly_identity.sha256, &std.fmt.bytesToHex(captured_assembly.sha256, .lower));
    const locator_raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture.linked_locator, allocator, .limited(model.locatorBytesMax()));
    const located = try std.json.parseFromSlice(model.Locator, allocator, locator_raw, .{});
    try std.testing.expectEqualSlices(u8, &model.digest(try load(allocator, directory, "record.json", model.maximum_record_bytes)), &located.value.record.sha256);
}

const std = @import("std");
const model = @import("root.zig").model;
const expose = @import("expose.zig");
const transport = @import("transport.zig");
const fixture = @import("binding_fixture");
const api = @import("build_definition");

fn load(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit + 1));
    if (bytes.len > limit) return error.CompilerBindingLeafTooLarge;
    return bytes;
}

fn locator(allocator: std.mem.Allocator, path: []const u8) !model.Locator {
    const raw = try load(allocator, path, model.locatorBytesMax());
    const parsed = try std.json.parseFromSlice(model.Locator, allocator, raw, .{});
    try std.testing.expectEqualStrings(model.exposure_schema, parsed.value.schema);
    const record_bytes = try load(allocator, parsed.value.record.path, model.maximum_record_bytes);
    try std.testing.expectEqual(record_bytes.len, parsed.value.record.bytes);
    try std.testing.expectEqualSlices(u8, &model.digest(record_bytes), &parsed.value.record.sha256);
    const original = try load(allocator, parsed.value.source_record.path, model.maximum_record_bytes);
    try std.testing.expectEqualSlices(u8, original, record_bytes);
    return parsed.value;
}

test "binding exposure actual make prefix and DESTDIR preserve selected record identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try locator(allocator, fixture.first_locator);
    const second = try locator(allocator, fixture.second_locator);
    const mirror = try locator(allocator, fixture.mirror_locator);
    try std.testing.expectEqualStrings(fixture.first_installed_record, first.record.path);
    try std.testing.expectEqualStrings(fixture.second_installed_record, second.record.path);
    try std.testing.expectEqualStrings("primary", first.selection.role);
    try std.testing.expectEqualStrings("mirror", mirror.selection.role);
    try std.testing.expectEqualSlices(u8, &first.record.sha256, &mirror.record.sha256);
    try std.testing.expect(!std.mem.eql(u8, first.record.path, mirror.record.path));
    try std.testing.expect(!std.mem.eql(u8, &first.record.sha256, &second.record.sha256));
    const suffix = "/share/chic/compiled-bindings/fixture/0/record.json";
    try std.testing.expect(std.mem.endsWith(u8, first.record.path, suffix));
    const prefix = first.record.path[0 .. first.record.path.len - suffix.len];
    const expected = std.testing.environ.getAlloc(allocator, "BINDING_EXPECTED_PREFIX") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    if (expected) |value| try std.testing.expectEqualStrings(value, prefix);
    const installed_locator = try std.fmt.allocPrint(allocator, "{s}.locator.json", .{std.fs.path.dirname(first.record.path).?});
    try std.testing.expectEqualSlices(u8, try load(allocator, fixture.first_locator, model.locatorBytesMax()), try load(allocator, installed_locator, model.locatorBytesMax()));
}

fn request(allocator: std.mem.Allocator, temporary: std.Io.Dir) !expose.Request {
    const root = try temporary.realPathFileAlloc(std.testing.io, ".", allocator);
    return .{
        .source_record = fixture.first_record,
        .destination = try std.fs.path.join(allocator, &.{ root, "selected" }),
        .locator = try std.fs.path.join(allocator, &.{ root, "locator.json" }),
        .selection = .{ .aggregate = .fixture, .ordinal = 0 },
        .exposure_step = "expose compiled binding fixture/0/primary",
    };
}

fn absent(path: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, path, .{}));
}

test "binding exposure cached source replaces qualified destination with refusal and no stale payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var selected = try request(allocator, temporary.dir);
    const storage = try allocator.alloc(u8, model.scratch_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    try expose.publish(fixed.allocator(), std.testing.io, selected);
    fixed.reset();
    selected.source_record = fixture.native_record;
    try expose.publish(fixed.allocator(), std.testing.io, selected);
    _ = try locator(allocator, selected.locator);
    const record_path = try std.fs.path.join(allocator, &.{ selected.destination, "record.json" });
    const parsed = try std.json.parseFromSlice(model.Record, allocator, try load(allocator, record_path, model.maximum_record_bytes), .{});
    try std.testing.expectEqual(.refused, parsed.value.status);
    try std.testing.expectEqualStrings("UnqualifiedCompilerNativeDiscovery", parsed.value.refusal.?);
    for ([_][]const u8{ "manifest.bin", "invocation.json", "compilation.json", "record.json.tmp" }) |leaf| {
        try absent(try std.fs.path.join(allocator, &.{ selected.destination, leaf }));
    }
}

test "binding exposure unexpected entries and obstructed payload invalidate completion without recursive cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const selected = try request(allocator, temporary.dir);
    try expose.publish(allocator, std.testing.io, selected);
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, selected.destination, .{});
    defer directory.close(std.testing.io);
    try directory.writeFile(std.testing.io, .{ .sub_path = "unexpected", .data = "leave me" });
    try std.testing.expectError(error.UnexpectedCompilerBindingEntry, expose.publish(allocator, std.testing.io, selected));
    try absent(selected.locator);
    try absent(try std.fmt.allocPrint(allocator, "{s}.locator.json", .{selected.destination}));
    try absent(try std.fs.path.join(allocator, &.{ selected.destination, "record.json" }));
    try std.testing.expectEqualStrings("leave me", try directory.readFileAlloc(std.testing.io, "unexpected", allocator, .limited(64)));
    try directory.deleteFile(std.testing.io, "unexpected");
    try directory.createDir(std.testing.io, "manifest.bin", .default_dir);
    try std.testing.expectError(error.CompilerBindingExposureObstructed, expose.publish(allocator, std.testing.io, selected));
    var obstruction = try directory.openDir(std.testing.io, "manifest.bin", .{});
    obstruction.close(std.testing.io);
    try absent(selected.locator);
}

fn graphFixture(allocator: std.mem.Allocator) !*std.Build {
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
    return std.Build.create(graph, .cwd(), &.{});
}

fn artifact(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .root_source_file = b.path("fixture.zig"), .target = b.graph.host, .optimize = .debug }),
    });
}

test "binding exposure selected roles share only the same Compile and preserve timed and ordinary consumers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try graphFixture(arena.allocator());
    const first = artifact(b, "same-name");
    const other = artifact(b, "same-name");
    const excluded = artifact(b, "not-selected");
    const selected = api.exposeCompilerBinding(b, first, .{ .aggregate = .fixture, .ordinal = 0 });
    const again = api.exposeCompilerBinding(b, first, .{ .aggregate = .fixture, .ordinal = 0 });
    const mirror = api.exposeCompilerBinding(b, first, .{ .aggregate = .retained, .ordinal = 0 });
    const distinct = api.exposeCompilerBinding(b, other, .{ .aggregate = .fixture, .ordinal = 1 });
    try std.testing.expect(selected.step == again.step);
    try std.testing.expect(selected.step != mirror.step and selected.step != distinct.step);
    try std.testing.expectEqual(selected.step.argv.items[1].lazy_path.lazy_path.generated.index, mirror.step.argv.items[1].lazy_path.lazy_path.generated.index);
    try std.testing.expect(selected.step.argv.items[1].lazy_path.lazy_path.generated.index != distinct.step.argv.items[1].lazy_path.lazy_path.generated.index);
    try std.testing.expectEqual(.none, excluded.generated_bin);
    try std.testing.expect(selected.step.has_side_effects);
    for ([_]bool{ false, true }) |receipt| {
        if (receipt) try b.graph.environ_map.put("TINY_TIMING_RUNNER_RECEIPT_DIR", "/receipt");
        const run = b.addRunArtifact(first);
        (api.TestTimeout{ .milliseconds = 120000 }).apply(b, run);
        const report = api.addCachedTestRun(b, run, .{ .cwd = "fixture" });
        const argv_count = run.argv.items.len;
        const environment = run.environ_map;
        run.step.dependOn(&selected.step.step);
        try std.testing.expectEqual(argv_count, run.argv.items.len);
        try std.testing.expectEqual(environment, run.environ_map);
        try std.testing.expectEqual(receipt, report == null);
    }
    const ordinary = b.addRunArtifact(other);
    const argc = ordinary.argv.items.len;
    ordinary.step.dependOn(&distinct.step.step);
    try std.testing.expectEqual(argc, ordinary.argv.items.len);
}

test "binding exposure sharded handles preserve shared Compile and distinct merge edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try graphFixture(arena.allocator());
    const tests = artifact(b, "shard-fixture");
    const shard_rss = 32 * 1024 * 1024;
    const sharded = api.addShardedTestRun(b, tests, .{
        .cached = .{ .cwd = "fixture" },
        .shards = 4,
        .weights = b.path("weights.tsv"),
        .shard_rss = shard_rss,
        .merge_source = b.path("merge.zig"),
    });
    try std.testing.expectEqual(4, sharded.shard_runs.len);
    try std.testing.expect(sharded.merge_compile != tests);
    try std.testing.expect(sharded.merge_run.producer.? == sharded.merge_compile);
    for (sharded.shard_runs, 0..) |run, index| {
        try std.testing.expect(run.producer.? == tests);
        try std.testing.expectEqual(shard_rss, run.step.max_rss);
        const selected = api.exposeCompilerBinding(b, tests, .{ .aggregate = .host, .ordinal = @intCast(index) });
        run.step.dependOn(&selected.step.step);
    }
    const merged = api.exposeCompilerBinding(b, sharded.merge_compile, .{ .aggregate = .host, .ordinal = 4 });
    sharded.merge_run.step.dependOn(&merged.step.step);
    try std.testing.expectEqual(4, sharded.shard_reports.len);
}

test "binding exposure tuple and encoded locator bounds stay inside ordinary leaf capacity" {
    try (model.Selection{ .aggregate = .fixture, .ordinal = 63, .role = "semantic" }).validate();
    try std.testing.expectError(error.CompilerBindingOrdinalTooLarge, (model.Selection{ .aggregate = .fixture, .ordinal = 64 }).validate());
    try std.testing.expectError(error.InvalidCompilerBindingRole, (model.Selection{ .aggregate = .fixture, .ordinal = 0, .role = "../wrong" }).validate());
    try std.testing.expect(model.locatorSetBytesMax() < 4 * 1024 * 1024);
    try std.testing.expectEqual(21_069_824, model.exportedBytesMax());
}

test "binding exposure changed payload refuses before locator publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var selected = try request(allocator, temporary.dir);
    try expose.publish(allocator, io, selected);
    var source = try temporary.dir.createDirPathOpen(io, "source", .{});
    defer source.close(io);
    const original_directory = std.fs.path.dirname(fixture.first_record).?;
    for ([_][]const u8{ "record.json", "manifest.bin", "invocation.json", "compilation.json" }) |leaf| {
        const original = try std.fs.path.join(allocator, &.{ original_directory, leaf });
        try source.writeFile(io, .{ .sub_path = leaf, .data = try load(allocator, original, model.maximum_manifest_bytes) });
    }
    try source.writeFile(io, .{ .sub_path = "compilation.json", .data = "different compiler owner" });
    selected.source_record = try source.realPathFileAlloc(io, "record.json", allocator);
    try std.testing.expectError(error.CompilerBindingInputMismatch, expose.publish(allocator, io, selected));
    try absent(selected.locator);
    try absent(try std.fmt.allocPrint(allocator, "{s}.locator.json", .{selected.destination}));
    try absent(try std.fs.path.join(allocator, &.{ selected.destination, "record.json" }));
}

test "binding exposure one graph owns conflicts reuse and the sixty-fifth tuple across Build owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first_owner = try graphFixture(arena.allocator());
    const other_owner = try std.Build.create(first_owner.graph, .cwd(), &.{});
    const first = artifact(first_owner, "same-name");
    const other = artifact(other_owner, "same-name");
    const tuple = api.CompilerBindingSelection{ .aggregate = .fixture, .ordinal = 0 };
    const exposed = try api.tryExposeCompilerBinding(other_owner, first, tuple);
    const reused = try api.tryExposeCompilerBinding(first_owner, first, tuple);
    try std.testing.expect(exposed.step == reused.step);
    try std.testing.expectError(error.CompilerBindingSelectionConflict, api.tryExposeCompilerBinding(first_owner, other, tuple));
    for (1..model.maximum_exposures) |ordinal| {
        const caller = if (ordinal % 2 == 0) first_owner else other_owner;
        const compile = if (ordinal % 2 == 0) first else other;
        _ = try api.tryExposeCompilerBinding(caller, compile, .{ .aggregate = .fixture, .ordinal = @intCast(ordinal) });
    }
    try std.testing.expectError(error.CompilerBindingExposureCountExceeded, api.tryExposeCompilerBinding(other_owner, other, .{ .aggregate = .fixture, .ordinal = 0, .role = "overflow" }));
    try std.testing.expect(exposed.step == (try api.tryExposeCompilerBinding(other_owner, first, tuple)).step);
}

fn longAnnouncement(allocator: std.mem.Allocator, ordinal: u8) ![]const u8 {
    const path = try allocator.alloc(u8, 3500);
    @memset(path, 'a' + ordinal);
    for (0..path.len) |i| if (i % 200 == 0) {
        path[i] = '/';
    };
    try model.path(path);
    const value = model.ExposureAnnouncement{
        .locator = .{ .path = path, .bytes = 17200, .sha256 = @splat('0') },
        .generated_locator = path,
        .selection = .{ .aggregate = .fixture, .ordinal = ordinal },
        .exposure_step = "expose compiled binding fixture/long/primary",
    };
    const buffer = try allocator.alloc(u8, model.locatorBytesMax());
    var writer = std.Io.Writer.fixed(buffer);
    try std.json.Stringify.value(value, .{}, &writer);
    try writer.writeByte('\n');
    try std.testing.expect(writer.buffered().len > transport.atomic_bytes);
    return writer.buffered();
}

fn framedBytes(bytes: []const u8) !usize {
    var buffer: [transport.frameBytesMax()]u8 = undefined;
    var total: usize = 0;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = @min(transport.payload_bytes, bytes.len - offset);
        total += (try transport.frame(&buffer, model.digest(bytes), offset, bytes.len, bytes[offset..][0..count])).len;
        offset += count;
    }
    return total;
}

fn checkFrames(allocator: std.mem.Allocator, stream: []const u8, originals: []const []const u8) !void {
    const rebuilt = try allocator.alloc([]u8, originals.len);
    const seen = try allocator.alloc([transport.frameCountMax()]bool, originals.len);
    for (originals, rebuilt, seen) |original, *destination, *present| {
        destination.* = try allocator.alloc(u8, original.len);
        present.* = @splat(false);
    }
    var lines = std.mem.splitScalar(u8, stream, '\n');
    var observed: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, transport.prefix)) continue;
        var fields = std.mem.splitScalar(u8, line[transport.prefix.len..], ' ');
        const digest = fields.next() orelse return error.MissingFrameDigest;
        const offset = try std.fmt.parseInt(usize, fields.next() orelse return error.MissingFrameOffset, 10);
        const total = try std.fmt.parseInt(usize, fields.next() orelse return error.MissingFrameLength, 10);
        const hex = fields.next() orelse return error.MissingFramePayload;
        try std.testing.expect(fields.next() == null);
        var selected: ?usize = null;
        for (originals, 0..) |original, index| {
            if (std.mem.eql(u8, &model.digest(original), digest)) selected = index;
        }
        const index = selected orelse return error.UnexpectedFrame;
        try std.testing.expectEqual(originals[index].len, total);
        try std.testing.expect(offset < total and offset % transport.payload_bytes == 0);
        const chunk = offset / transport.payload_bytes;
        try std.testing.expect(!seen[index][chunk]);
        const count: usize = @min(transport.payload_bytes, total - offset);
        try std.testing.expectEqual(count * 2, hex.len);
        _ = try std.fmt.hexToBytes(rebuilt[index][offset..][0..count], hex);
        seen[index][chunk] = true;
        observed += 1;
        try std.testing.expect(observed <= originals.len * transport.frameCountMax());
    }
    for (originals, rebuilt, seen) |original, actual, present| {
        const count = try std.math.divCeil(usize, original.len, transport.payload_bytes);
        for (present[0..count]) |found| try std.testing.expect(found);
        try std.testing.expectEqualSlices(u8, original, actual);
        try std.testing.expectEqualSlices(u8, &model.digest(original), &model.digest(actual));
    }
}

test "binding exposure atomic frames preserve long paths beside concurrent unrelated pipe output" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const first = try longAnnouncement(allocator, 0);
    const second = try longAnnouncement(allocator, 1);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "first.json", .data = first });
    try temporary.dir.writeFile(io, .{ .sub_path = "second.json", .data = second });
    const first_path = try temporary.dir.realPathFileAlloc(io, "first.json", allocator);
    const second_path = try temporary.dir.realPathFileAlloc(io, "second.json", allocator);
    const drain_path = try std.fs.path.join(allocator, &.{ try temporary.dir.realPathFileAlloc(io, ".", allocator), "drained.json" });
    const maximum = 2 * transport.transportBytesMax() + 32 * 1024;
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ fixture.framing_binary, "coordinator", first_path, second_path, drain_path },
        .stdout_limit = .limited(maximum),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    });
    try std.testing.expect(result.term.success());
    try std.testing.expectEqual(0, result.stderr.len);
    try std.testing.expectEqual(try framedBytes(first) + try framedBytes(second) + 32 * 1024, result.stdout.len);
    try checkFrames(allocator, result.stdout, &.{ first, second });
    const normal_drain = try std.json.parseFromSlice(@import("framing.zig").Drain, allocator, try load(allocator, drain_path, 256), .{});
    try std.testing.expectEqual(3, normal_drain.value.started);
    try std.testing.expectEqual(3, normal_drain.value.reaped);
    try std.testing.expect(!normal_drain.value.timed_out);
    const old_interleaving = try std.mem.concat(allocator, u8, &.{ first[0..4096], second, first[4096..] });
    try std.testing.expect(!std.mem.eql(u8, old_interleaving[0..first.len], first));
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSlice(model.ExposureAnnouncement, allocator, old_interleaving, .{}));
}

test "binding exposure failed frame emission invalidates already published completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const selected = try request(allocator, temporary.dir);
    try temporary.dir.writeFile(io, .{ .sub_path = "readonly", .data = "" });
    const output = try temporary.dir.openFile(io, "readonly", .{});
    defer output.close(io);
    try std.testing.expectError(error.NotOpenForWriting, expose.publishAndAnnounce(allocator, io, selected, output, null));
    try absent(selected.locator);
    try absent(try std.fmt.allocPrint(allocator, "{s}.locator.json", .{selected.destination}));
    try absent(try std.fs.path.join(allocator, &.{ selected.destination, "record.json" }));
}

test "binding exposure fixture deadline reaps all blocked workers before its outer guard" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "gate", .data = "held" });
    const gate = try temporary.dir.realPathFileAlloc(std.testing.io, "gate", allocator);
    const receipt = try std.fs.path.join(allocator, &.{ try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator), "drained.json" });
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ fixture.framing_binary, "timeout", gate, gate, receipt },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    });
    try std.testing.expect(result.term.success());
    try std.testing.expectEqual(0, result.stdout.len);
    try std.testing.expectEqual(0, result.stderr.len);
    const drained = try std.json.parseFromSlice(@import("framing.zig").Drain, allocator, try load(allocator, receipt, 256), .{});
    try std.testing.expectEqual(3, drained.value.started);
    try std.testing.expectEqual(3, drained.value.reaped);
    try std.testing.expect(drained.value.timed_out);
}

fn helperArgs(selected: expose.Request) [8][]const u8 {
    return .{ fixture.exposure_binary, selected.source_record, selected.destination, selected.locator, "fixture", "0", "primary", selected.exposure_step };
}

fn publicationAbsent(allocator: std.mem.Allocator, selected: expose.Request) !void {
    try absent(selected.locator);
    try absent(try std.fmt.allocPrint(allocator, "{s}.locator.json", .{selected.destination}));
    for ([_][]const u8{ "record.json", "record.json.tmp", "manifest.bin", "invocation.json", "compilation.json" }) |leaf| {
        try absent(try std.fs.path.join(allocator, &.{ selected.destination, leaf }));
    }
}

test "binding exposure actual helper capture malformed and unreachable refuse with owned cleanup" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const selected = try request(allocator, temporary.dir);
    const arguments = helperArgs(selected);
    var environment = try std.testing.environ.createMap(allocator);
    defer environment.deinit();
    const missing = try std.fs.path.join(allocator, &.{ try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator), "missing" });
    const unreachable_capture = try std.fmt.allocPrint(allocator, "unix1:{s}:0101010101010101010101010101010101010101010101010101010101010101", .{missing});
    _ = try @import("lifetime.zig").Config.parse(unreachable_capture);
    for ([_][]const u8{ "malformed", unreachable_capture }, [_][]const u8{ "CompilerBindingLifetimeEnvironment", "CompilerBindingLifetimeObserver" }) |capture, diagnostic| {
        try environment.put(@import("lifetime.zig").environment_name, capture);
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &arguments,
            .environ_map = &environment,
            .stdout_limit = .limited(transport.transportBytesMax()),
            .stderr_limit = .limited(65536),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
        });
        try std.testing.expect(!result.term.success());
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, diagnostic) != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, transport.prefix) != null);
        try publicationAbsent(allocator, selected);
    }
}

const LifetimeMode = enum { retain, bad_ack };

const LifetimeReceipt = struct {
    held_before_ack: bool,
    retained_bytes: usize,
    executable_bytes: usize,
    announcement_bytes: usize,
    term: std.process.Child.Term,
};

/// Local Linux integration collector only. It serves the real helper's barrier
/// from this test process, the helper's parent, and retains the live
/// executable before its ACK. It is not the C7 admission collector.
fn lifetimeCollect(allocator: std.mem.Allocator, temporary: *const std.testing.TmpDir, mode: LifetimeMode, helper: []const []const u8) !LifetimeReceipt {
    const lifetime = @import("lifetime.zig");
    // The endpoint stays under /tmp so it fits the helper's socket path bound.
    const root = try std.fmt.allocPrint(allocator, "/tmp/tiny-lifetime-{s}", .{&temporary.sub_path});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/capture", .{root});
    var collector = try lifetime.TestCollector.listen(endpoint);
    defer collector.deinit();
    const session: [32]u8 = @splat(1);
    const epoch: [32]u8 = @splat(2);
    const nonce: [32]u8 = @splat(3);
    var environment = try std.testing.environ.createMap(allocator);
    defer environment.deinit();
    try environment.put(lifetime.environment_name, try std.fmt.allocPrint(allocator, "unix1:{s}:{x}", .{ endpoint, &session }));
    var child = try std.process.spawn(std.testing.io, .{
        .argv = helper,
        .environ_map = &environment,
        .stdin = .ignore,
        // The helper frames its announcement only onto a pipe or file. Its
        // bounded frames fit the pipe buffer, so nothing reads them.
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var reaped = false;
    defer if (!reaped) child.kill(std.testing.io);
    try collector.accept();
    const hello = try collector.receive();
    try std.testing.expectEqual(lifetime.Kind.hello, hello.kind);
    try std.testing.expectEqualSlices(u8, &session, &hello.capture);
    try collector.send(.{ .kind = .challenge, .capture = epoch, .challenge = nonce, .digest = hello.digest, .value = hello.value });
    const ready = try collector.receive();
    try std.testing.expectEqual(lifetime.Kind.ready, ready.kind);
    try std.testing.expectEqualSlices(u8, &nonce, &ready.challenge);
    // A zombie has no /proc exe, so reading it proves the helper is still held.
    const exe = try std.fmt.allocPrint(allocator, "/proc/{d}/exe", .{child.id.?});
    const executable = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, exe, allocator, .limited(model.maximum_binary_bytes + 1));
    var executable_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(executable, &executable_digest, .{});
    const snapshot = try std.fmt.allocPrint(allocator, "{{\"pid\":{d},\"executable_bytes\":{d},\"executable_sha256\":\"{x}\"}}", .{ child.id.?, executable.len, &executable_digest });
    var snapshot_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(snapshot, &snapshot_digest, .{});
    const answer: [32]u8 = if (mode == .retain) nonce else @splat(4);
    try collector.send(.{ .kind = .ack, .capture = epoch, .challenge = answer, .digest = snapshot_digest, .value = snapshot.len });
    const term = try child.wait(std.testing.io);
    reaped = true;
    return .{
        .held_before_ack = true,
        .retained_bytes = snapshot.len,
        .executable_bytes = executable.len,
        .announcement_bytes = hello.value,
        .term = term,
    };
}

fn lifetimeHelperCase(mode: LifetimeMode) !void {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const selected = try request(allocator, temporary.dir);
    const helper = helperArgs(selected);
    const receipt = try lifetimeCollect(allocator, &temporary, mode, &helper);
    try std.testing.expect(receipt.held_before_ack);
    try std.testing.expect(receipt.retained_bytes > 0 and receipt.retained_bytes <= @import("lifetime.zig").maximum_snapshot_bytes);
    try std.testing.expect(receipt.executable_bytes > 0 and receipt.executable_bytes <= model.maximum_binary_bytes);
    try std.testing.expect(receipt.announcement_bytes > 0 and receipt.announcement_bytes <= model.locatorBytesMax());
    if (mode == .retain) {
        try std.testing.expect(receipt.term.success());
        _ = try locator(allocator, selected.locator);
    } else {
        try std.testing.expect(!receipt.term.success());
        try publicationAbsent(allocator, selected);
    }
}

test "binding exposure actual helper remains live through retained snapshot ACK" {
    try lifetimeHelperCase(.retain);
}

test "binding exposure actual helper incorrect ACK refuses and invalidates publication" {
    try lifetimeHelperCase(.bad_ack);
}

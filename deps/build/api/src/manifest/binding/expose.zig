const std = @import("std");
const model = @import("root.zig").model;
const transport = @import("transport.zig");
const lifetime = @import("lifetime.zig");

pub const Request = struct {
    source_record: []const u8,
    destination: []const u8,
    locator: []const u8,
    selection: model.Selection,
    exposure_step: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const output = std.Io.File.stdout();
    if (@import("mode.zig").framing) return @import("framing.zig").run(init, output);
    const storage = try init.arena.allocator().alloc(u8, model.scratch_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    const allocator = fixed.allocator();
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    std.debug.assert(args.skip());
    const source_record = args.next() orelse return error.MissingCompilerBindingRecord;
    const destination = args.next() orelse return error.MissingCompilerBindingDestination;
    const locator = args.next() orelse return error.MissingCompilerBindingLocator;
    const aggregate = args.next() orelse return error.MissingCompilerBindingAggregate;
    const ordinal = args.next() orelse return error.MissingCompilerBindingOrdinal;
    const role = args.next() orelse return error.MissingCompilerBindingRole;
    const exposure_step = args.next() orelse return error.MissingCompilerBindingExposureStep;
    if (args.next() != null) return error.UnexpectedCompilerBindingArgument;
    const request = Request{
        .source_record = source_record,
        .destination = destination,
        .locator = locator,
        .selection = .{
            .aggregate = std.meta.stringToEnum(@FieldType(model.Selection, "aggregate"), aggregate) orelse return error.InvalidCompilerBindingAggregate,
            .ordinal = try std.fmt.parseInt(u8, ordinal, 10),
            .role = role,
        },
        .exposure_step = exposure_step,
    };
    try publishAndAnnounce(allocator, init.io, request, output, init.environ_map.get(lifetime.environment_name));
}

pub fn publishAndAnnounce(allocator: std.mem.Allocator, io: std.Io, request: Request, output: std.Io.File, capture: ?[]const u8) !void {
    try publish(allocator, io, request);
    announce(allocator, io, request, output, capture) catch |err| {
        invalidate(io, request);
        return err;
    };
}

/// The ordinary helper stdout transports one bounded actual-path receipt in
/// atomic frames. Missing or malformed transport never admits a locator.
fn announce(allocator: std.mem.Allocator, io: std.Io, request: Request, output: std.Io.File, capture: ?[]const u8) !void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, request.locator, allocator, .limited(model.locatorBytesMax() + 1));
    defer allocator.free(raw);
    if (raw.len > model.locatorBytesMax()) return error.CompilerBindingLocatorTooLarge;
    const path = try std.fmt.allocPrint(allocator, "{s}.locator.json", .{request.destination});
    defer allocator.free(path);
    try model.path(path);
    const value = model.ExposureAnnouncement{
        .locator = .{ .path = path, .bytes = raw.len, .sha256 = model.digest(raw) },
        .generated_locator = request.locator,
        .selection = request.selection,
        .exposure_step = request.exposure_step,
    };
    var buffer: [model.locatorBytesMax()]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(value, .{}, &writer) catch return error.CompilerBindingLocatorTooLarge;
    writer.writeByte('\n') catch return error.CompilerBindingLocatorTooLarge;
    try transport.write(io, output, writer.buffered());
    var workspace: lifetime.Workspace = undefined;
    try lifetime.barrier(capture, writer.buffered(), &workspace);
}

/// Always invoked even for a cached exporter. Only fixed owned leaves are
/// removed; no unknown entry or directory is traversed. Success publishes the
/// unchanged record then the persistent locator and identical generated locator.
pub fn publish(allocator: std.mem.Allocator, io: std.Io, request: Request) !void {
    return publishInner(allocator, io, request) catch |err| {
        if (err == error.OutOfMemory) return error.CompilerBindingScratchExceeded;
        return err;
    };
}

fn publishInner(allocator: std.mem.Allocator, io: std.Io, request: Request) !void {
    const cwd = std.Io.Dir.cwd();
    try model.path(request.destination);
    if (!std.unicode.utf8ValidateSlice(request.destination)) return error.InvalidCompilerBindingPath;
    try model.path(request.locator);
    if (!std.unicode.utf8ValidateSlice(request.locator)) return error.InvalidCompilerBindingPath;
    const installed_locator = try std.fmt.allocPrint(allocator, "{s}.locator.json", .{request.destination});
    defer allocator.free(installed_locator);
    try model.path(installed_locator);
    const temporary_locator = try std.fmt.allocPrint(allocator, "{s}.tmp", .{installed_locator});
    defer allocator.free(temporary_locator);
    try remove(cwd, io, request.locator);
    try remove(cwd, io, installed_locator);
    try remove(cwd, io, temporary_locator);
    errdefer {
        remove(cwd, io, request.locator) catch {};
        remove(cwd, io, installed_locator) catch {};
        remove(cwd, io, temporary_locator) catch {};
    }
    var destination = try cwd.createDirPathOpen(io, request.destination, .{
        .open_options = .{ .iterate = true, .follow_symlinks = false },
    });
    defer destination.close(io);
    try model.path(request.source_record);
    if (!std.unicode.utf8ValidateSlice(request.source_record)) return error.InvalidCompilerBindingPath;
    if (!std.mem.eql(u8, std.fs.path.basename(request.source_record), "record.json")) return error.InvalidCompilerBindingRecordPath;
    const source_path = std.fs.path.dirname(request.source_record) orelse return error.InvalidCompilerBindingRecordPath;
    var source = try cwd.openDir(io, source_path, .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    const source_real = try source.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_real);
    const destination_real = try destination.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_real);
    if (std.mem.eql(u8, source_real, destination_real)) return error.CompilerBindingExposureAliasesSource;
    errdefer for (owned) |leaf| remove(destination, io, leaf) catch {};
    try remove(destination, io, "record.json");
    try remove(destination, io, "record.json.tmp");
    try membership(destination, io, null);
    for (owned[2..]) |leaf| try remove(destination, io, leaf);
    try request.selection.validate();
    if (request.exposure_step.len == 0 or request.exposure_step.len > model.maximum_exposure_step_bytes) return error.CompilerBindingExposureStepTooLarge;
    for (request.exposure_step) |byte| if (byte < 32 or byte > 126) return error.InvalidCompilerBindingExposureStep;
    const bytes = try read(allocator, source, io, "record.json", model.maximum_record_bytes);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(model.Record, allocator, bytes, .{ .max_value_len = model.maximum_record_bytes });
    defer parsed.deinit();
    const record = parsed.value;
    try validateRecord(record);
    try membership(source, io, record.status == .qualified);
    if (record.status == .qualified) {
        const identities = [_]model.Identity{ record.manifest.?, record.invocation.?, record.compilation.? };
        const limits = [_]usize{ model.maximum_manifest_bytes, model.maximum_invocation_bytes, model.maximum_compilation_bytes };
        for (owned[2..], identities, limits) |leaf, expected, limit| {
            {
                const payload = try read(allocator, source, io, leaf, limit);
                defer allocator.free(payload);
                try matches(payload, expected);
                try destination.writeFile(io, .{ .sub_path = leaf, .data = payload });
            }
            const copied = try read(allocator, destination, io, leaf, limit);
            defer allocator.free(copied);
            try matches(copied, expected);
        }
    }
    try destination.writeFile(io, .{ .sub_path = "record.json.tmp", .data = bytes });
    try destination.rename("record.json.tmp", destination, "record.json", io);
    try membership(destination, io, record.status == .qualified);
    const current = try read(allocator, source, io, "record.json", model.maximum_record_bytes);
    defer allocator.free(current);
    if (!std.mem.eql(u8, bytes, current)) return error.CompilerBindingRecordChanged;
    const copied_record = try read(allocator, destination, io, "record.json", model.maximum_record_bytes);
    defer allocator.free(copied_record);
    if (!std.mem.eql(u8, bytes, copied_record)) return error.CompilerBindingRecordChanged;
    const record_path = try std.fs.path.join(allocator, &.{ request.destination, "record.json" });
    defer allocator.free(record_path);
    try model.path(record_path);
    const locator = model.Locator{
        .selection = request.selection,
        .source_record = .{ .path = request.source_record, .bytes = bytes.len, .sha256 = model.digest(bytes) },
        .record = .{ .path = record_path, .bytes = bytes.len, .sha256 = model.digest(bytes) },
        .exposure_step = request.exposure_step,
    };
    var buffer: [model.locatorBytesMax()]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(locator, .{}, &writer) catch return error.CompilerBindingLocatorTooLarge;
    writer.writeByte('\n') catch return error.CompilerBindingLocatorTooLarge;
    try cwd.writeFile(io, .{ .sub_path = temporary_locator, .data = writer.buffered() });
    try cwd.rename(temporary_locator, cwd, installed_locator, io);
    try cwd.writeFile(io, .{ .sub_path = request.locator, .data = writer.buffered() });
}

const owned = [_][]const u8{ "record.json", "record.json.tmp", "manifest.bin", "invocation.json", "compilation.json" };

fn remove(directory: std.Io.Dir, io: std.Io, path: []const u8) !void {
    const stat = directory.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    if (stat.kind != .file) return error.CompilerBindingExposureObstructed;
    try directory.deleteFile(io, path);
}

fn membership(directory: std.Io.Dir, io: std.Io, qualified: ?bool) !void {
    var iterator = directory.iterate();
    var found: [owned.len]bool = @splat(false);
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        count += 1;
        if (count > owned.len) return error.UnexpectedCompilerBindingEntry;
        var index: ?usize = null;
        for (owned, 0..) |name, i| if (std.mem.eql(u8, name, entry.name)) {
            index = i;
            break;
        };
        const i = index orelse return error.UnexpectedCompilerBindingEntry;
        const stat = try directory.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file or found[i]) return error.CompilerBindingExposureObstructed;
        found[i] = true;
    }
    if (qualified) |value| {
        if (!found[0] or found[1]) return error.CompilerBindingExposureMembership;
        for (found[2..]) |present| if (present != value) return error.CompilerBindingExposureMembership;
    }
}

fn read(allocator: std.mem.Allocator, directory: std.Io.Dir, io: std.Io, leaf: []const u8, limit: usize) ![]u8 {
    const stat = try directory.statFile(io, leaf, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.CompilerBindingExposureObstructed;
    if (stat.size > limit) return error.CompilerBindingLeafTooLarge;
    const bytes = try directory.readFileAlloc(io, leaf, allocator, .limited(limit + 1));
    if (bytes.len > limit) return error.CompilerBindingLeafTooLarge;
    return bytes;
}

fn matches(bytes: []const u8, expected: model.Identity) !void {
    if (bytes.len != expected.bytes or !std.mem.eql(u8, &model.digest(bytes), &expected.sha256)) return error.CompilerBindingInputMismatch;
}

fn validateRecord(record: model.Record) !void {
    if (!std.mem.eql(u8, record.schema, model.schema)) return error.InvalidCompilerBindingSchema;
    try model.compiler(record.compile);
    try model.path(record.binary.path);
    if (record.binary.bytes > model.maximum_binary_bytes) return error.CompilerBindingBinaryTooLarge;
    if (record.status == .qualified) {
        if (record.refusal != null or record.manifest == null or record.invocation == null or record.compilation == null) return error.AmbiguousCompilerBinding;
    } else {
        const refusal = record.refusal orelse return error.AmbiguousCompilerBinding;
        if (refusal.len == 0 or refusal.len > model.maximum_name_bytes or record.manifest != null or record.invocation != null or record.compilation != null) return error.AmbiguousCompilerBinding;
    }
}

fn invalidate(io: std.Io, request: Request) void {
    const cwd = std.Io.Dir.cwd();
    remove(cwd, io, request.locator) catch {};
    var buffer: [model.maximum_path_bytes + 32]u8 = undefined;
    const locator = std.fmt.bufPrint(&buffer, "{s}.locator.json", .{request.destination}) catch return;
    remove(cwd, io, locator) catch {};
    var directory = cwd.openDir(io, request.destination, .{ .follow_symlinks = false }) catch return;
    defer directory.close(io);
    for (owned) |leaf| remove(directory, io, leaf) catch {};
}

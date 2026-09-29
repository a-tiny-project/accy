const std = @import("std");
const runner_semantic = @import("semantic.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema = "tiny.build.capacity-witness-receipt/v2";
pub const runner_schema = runner_semantic.schema;
pub const test_runner_domain = "tiny.stardust.snapshot.test-runner/v1";
pub const artifact_domain = "tiny.build.capacity-witness-artifact/v1";
pub const run_token_domain = "tiny.build.capacity-witness-run/v1";
pub const semantic_domain = "tiny.build.capacity-witness-semantic/v1";
pub const obligation_bytes_max: usize = 64;

pub const Id = extern struct {
    bytes: [Sha256.digest_length]u8,

    pub fn eql(lhs: Id, rhs: Id) bool {
        return std.mem.eql(u8, &lhs.bytes, &rhs.bytes);
    }
};

pub const CompileUnit = struct {
    content_root: Id,
    binding: Id,
};

pub const Role = enum(u8) {
    capacity_model,
    acquisition,
    initialization_failure,
    overload,
    seal,
    teardown,
    work_bound,
    transitive_risk,
    foreign_risk,
    integration,
    custom,
};

pub const RunnerStatus = enum(u3) {
    ok,
    skip,
    fail,
    leak,
    fail_leak,
};

pub const Status = enum(u3) {
    ok,
    skip,
    fail,
    leak,
    fail_leak,
    not_selected,
    interrupted,

    pub fn satisfies(self: Status) bool {
        return self == .ok;
    }
};

pub const Annotation = struct {
    test_identity: Id,
    runner: Id,
    claim: Id,
    obligation: []const u8,
    role: Role,
};

pub const RunnerRow = struct {
    name: []const u8,
    status: RunnerStatus,
    leaked: bool = false,
};

pub const RunEvidence = struct {
    token: []const u8,
    completed: bool,
    interrupted_test: ?[]const u8 = null,
    rows: []const RunnerRow,
};

pub const Context = struct {
    registered_step: Id,
    profile: ?Id,
    artifact: Id,
    compile_unit: CompileUnit,
};

pub const Row = struct {
    test_identity: Id,
    claim: Id,
    obligation: []const u8,
    role: Role,
    status: Status,
};

pub const Receipt = struct {
    registered_step: Id,
    profile: ?Id,
    artifact: Id,
    compile_unit: CompileUnit,
    run_token: Id,
    semantic_digest: Id,
    rows: []const Row,

    pub fn validate(self: Receipt) !void {
        for (self.rows) |row| try validateObligation(row.obligation);
        const expected = semanticDigest(
            .{
                .registered_step = self.registered_step,
                .profile = self.profile,
                .artifact = self.artifact,
                .compile_unit = self.compile_unit,
            },
            self.run_token,
            self.rows,
        );
        if (!self.semantic_digest.eql(expected)) return error.DigestMismatch;
    }
};

pub const ArtifactHasher = struct {
    state: Sha256,
    remaining: u64,

    pub fn init(length: u64) ArtifactHasher {
        var builder = Builder.init(artifact_domain);
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, length, .little);
        builder.state.update(&encoded);
        return .{ .state = builder.state, .remaining = length };
    }

    pub fn update(self: *ArtifactHasher, bytes: []const u8) !void {
        const length: u64 = @intCast(bytes.len);
        if (length > self.remaining) return error.ArtifactLengthExceeded;
        self.state.update(bytes);
        self.remaining -= length;
    }

    pub fn finish(self: *ArtifactHasher) !Id {
        if (self.remaining != 0) return error.ArtifactLengthMismatch;
        var result: Id = undefined;
        self.state.final(&result.bytes);
        return result;
    }
};

pub fn join(
    context: Context,
    annotations: []const Annotation,
    run: RunEvidence,
    output: []Row,
) !Receipt {
    if (annotations.len > output.len) return error.RowCapacityExceeded;
    if (run.token.len == 0 or run.token.len > 128) return error.InvalidRunToken;
    if (run.completed and run.interrupted_test != null) {
        return error.InvalidRunEvidence;
    }
    try validateRunnerRows(run.rows);
    for (annotations, 0..) |annotation, index| {
        try validateObligation(annotation.obligation);
        for (annotations[0..index]) |earlier| {
            if (annotationEqual(annotation, earlier)) {
                return error.DuplicateAnnotation;
            }
        }
        output[index] = .{
            .test_identity = annotation.test_identity,
            .claim = annotation.claim,
            .obligation = annotation.obligation,
            .role = annotation.role,
            .status = statusFor(annotation.runner, run),
        };
    }
    const active = output[0..annotations.len];
    const run_token = textId(run_token_domain, run.token);
    return .{
        .registered_step = context.registered_step,
        .profile = context.profile,
        .artifact = context.artifact,
        .compile_unit = context.compile_unit,
        .run_token = run_token,
        .semantic_digest = semanticDigest(context, run_token, active),
        .rows = active,
    };
}

pub fn testRunnerId(name: []const u8) Id {
    return textId(test_runner_domain, name);
}

pub fn artifactId(bytes: []const u8) Id {
    var hasher = ArtifactHasher.init(@intCast(bytes.len));
    hasher.update(bytes) catch unreachable;
    return hasher.finish() catch unreachable;
}

pub fn validateRunDigest(rows: []const RunnerRow, encoded: []const u8) !void {
    if (encoded.len != Sha256.digest_length * 2) return error.InvalidRunDigest;
    var expected: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, encoded) catch return error.InvalidRunDigest;
    const actual = runner_semantic.digest(rows);
    if (!std.mem.eql(u8, &expected, &actual)) return error.RunDigestMismatch;
}

pub fn writeJson(writer: *std.Io.Writer, receipt: Receipt) !void {
    try receipt.validate();
    try writer.writeAll("{\"schema\":");
    try json(writer, schema);
    try writer.writeAll(",\"registered_step\":");
    try writeId(writer, receipt.registered_step);
    try writer.writeAll(",\"profile\":");
    if (receipt.profile) |value| {
        try writeId(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"artifact\":");
    try writeId(writer, receipt.artifact);
    try writer.writeAll(",\"compile_unit\":{\"content_root\":");
    try writeId(writer, receipt.compile_unit.content_root);
    try writer.writeAll(",\"binding\":");
    try writeId(writer, receipt.compile_unit.binding);
    try writer.writeAll("},\"run_token\":");
    try writeId(writer, receipt.run_token);
    try writer.writeAll(",\"semantic_digest\":");
    try writeId(writer, receipt.semantic_digest);
    try writer.writeAll(",\"rows\":[");
    for (receipt.rows, 0..) |row, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"test\":");
        try writeId(writer, row.test_identity);
        try writer.writeAll(",\"claim\":");
        try writeId(writer, row.claim);
        try writer.writeAll(",\"obligation\":");
        try json(writer, row.obligation);
        try writer.writeAll(",\"role\":");
        try json(writer, @tagName(row.role));
        try writer.writeAll(",\"status\":");
        try json(writer, @tagName(row.status));
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn statusFor(runner: Id, run: RunEvidence) Status {
    for (run.rows) |row| {
        if (!testRunnerId(row.name).eql(runner)) continue;
        return @fromBackingInt(@intCast(@backingInt(row.status)));
    }
    if (!run.completed) {
        if (run.interrupted_test) |name| {
            if (testRunnerId(name).eql(runner)) return .interrupted;
        }
    }
    return .not_selected;
}

fn validateRunnerRows(rows: []const RunnerRow) !void {
    for (rows, 0..) |row, index| {
        if (row.name.len == 0 or row.name.len > 4096) {
            return error.InvalidRunnerTestName;
        }
        const leaked = row.status == .leak or row.status == .fail_leak;
        if (row.leaked != leaked) return error.InvalidRunnerLeakStatus;
        const identity = testRunnerId(row.name);
        for (rows[0..index]) |earlier| {
            if (testRunnerId(earlier.name).eql(identity)) {
                return error.DuplicateRunnerRow;
            }
        }
    }
}

fn validateObligation(value: []const u8) !void {
    if (value.len == 0 or value.len > obligation_bytes_max) {
        return error.InvalidObligation;
    }
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and
            byte != '-' and byte != '.')
        {
            return error.InvalidObligation;
        }
    }
}

fn annotationEqual(lhs: Annotation, rhs: Annotation) bool {
    return lhs.test_identity.eql(rhs.test_identity) and lhs.claim.eql(rhs.claim) and
        lhs.role == rhs.role and
        std.mem.eql(u8, lhs.obligation, rhs.obligation);
}

fn semanticDigest(context: Context, run_token: Id, rows: []const Row) Id {
    var builder = Builder.init(semantic_domain);
    builder.addId(context.registered_step);
    if (context.profile) |value| {
        builder.addU8(1);
        builder.addId(value);
    } else {
        builder.addU8(0);
    }
    builder.addId(context.artifact);
    builder.addId(context.compile_unit.content_root);
    builder.addId(context.compile_unit.binding);
    builder.addId(run_token);
    builder.addU64(rows.len);
    for (rows) |row| {
        builder.addId(row.test_identity);
        builder.addId(row.claim);
        builder.addBytes(row.obligation);
        builder.addU8(@backingInt(row.role));
        builder.addU8(@backingInt(row.status));
    }
    return builder.finish();
}

fn textId(comptime domain: []const u8, text: []const u8) Id {
    var builder = Builder.init(domain);
    builder.addBytes(text);
    return builder.finish();
}

const Builder = struct {
    state: Sha256,

    fn init(comptime domain: []const u8) Builder {
        var result = Builder{ .state = Sha256.init(.{}) };
        result.addBytes(domain);
        return result;
    }

    fn addBytes(self: *Builder, value: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, value.len, .little);
        self.state.update(&length);
        self.state.update(value);
    }

    fn addId(self: *Builder, value: Id) void {
        self.addBytes(&value.bytes);
    }

    fn addU8(self: *Builder, value: u8) void {
        self.addInteger(u8, value);
    }

    fn addU64(self: *Builder, value: u64) void {
        self.addInteger(u64, value);
    }

    fn addInteger(self: *Builder, comptime T: type, value: T) void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .little);
        self.addBytes(&encoded);
    }

    fn finish(self: *Builder) Id {
        var result: Id = undefined;
        self.state.final(&result.bytes);
        return result;
    }
};

fn writeId(writer: *std.Io.Writer, value: Id) !void {
    const encoded = std.fmt.bytesToHex(value.bytes, .lower);
    try json(writer, &encoded);
}

fn json(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "witness merger preserves every runner terminal status" {
    const names = [_][]const u8{
        "fixture ok",
        "fixture skip",
        "fixture fail",
        "fixture leak",
        "fixture fail leak",
        "fixture not selected",
        "fixture interrupted",
    };
    var annotations: [names.len]Annotation = undefined;
    for (&annotations, names, 0..) |*annotation, name, index| {
        annotation.* = .{
            .test_identity = testId(@intCast(index + 1)),
            .runner = testRunnerId(name),
            .claim = testId(20),
            .obligation = "capacity",
            .role = .capacity_model,
        };
    }
    const runner_rows = [_]RunnerRow{
        .{ .name = names[0], .status = .ok },
        .{ .name = names[1], .status = .skip },
        .{ .name = names[2], .status = .fail },
        .{ .name = names[3], .status = .leak, .leaked = true },
        .{ .name = names[4], .status = .fail_leak, .leaked = true },
    };
    var rows: [names.len]Row = undefined;
    const receipt = try join(testContext(), &annotations, .{
        .token = "fixture-run",
        .completed = false,
        .interrupted_test = names[6],
        .rows = &runner_rows,
    }, &rows);
    const expected = [_]Status{
        .ok,
        .skip,
        .fail,
        .leak,
        .fail_leak,
        .not_selected,
        .interrupted,
    };
    for (receipt.rows, expected) |row, status| {
        try std.testing.expectEqual(status, row.status);
    }
    try std.testing.expect(receipt.rows[0].status.satisfies());
    for (receipt.rows[1..]) |row| try std.testing.expect(!row.status.satisfies());
    try receipt.validate();
}

test "witness receipt digest rejects a changed status and writes joined fields" {
    const annotation = Annotation{
        .test_identity = testId(1),
        .runner = testRunnerId("fixture ok"),
        .claim = testId(2),
        .obligation = "capacity",
        .role = .capacity_model,
    };
    const runner_row = RunnerRow{ .name = "fixture ok", .status = .ok };
    var rows: [1]Row = undefined;
    var receipt = try join(testContext(), &.{annotation}, .{
        .token = "fixture-run",
        .completed = true,
        .rows = &.{runner_row},
    }, &rows);
    var bytes: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writeJson(&writer, receipt);
    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, schema) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"status\":\"ok\"") != null);
    rows[0].status = .skip;
    try std.testing.expectError(error.DigestMismatch, receipt.validate());
}

test "one runner expands to one joined row for each obligation role" {
    const test_identity = testId(1);
    const runner = testRunnerId("fixture multi role");
    const claim = testId(2);
    const annotations = [_]Annotation{
        .{
            .test_identity = test_identity,
            .runner = runner,
            .claim = claim,
            .obligation = "capacity",
            .role = .capacity_model,
        },
        .{
            .test_identity = test_identity,
            .runner = runner,
            .claim = claim,
            .obligation = "overload",
            .role = .overload,
        },
        .{
            .test_identity = test_identity,
            .runner = runner,
            .claim = claim,
            .obligation = "work",
            .role = .work_bound,
        },
    };
    var rows: [annotations.len]Row = undefined;
    const receipt = try join(testContext(), &annotations, .{
        .token = "fixture-run",
        .completed = true,
        .rows = &.{.{ .name = "fixture multi role", .status = .ok }},
    }, &rows);
    try std.testing.expectEqual(@as(usize, 3), receipt.rows.len);
    for (receipt.rows) |row| {
        try std.testing.expect(row.test_identity.eql(test_identity));
        try std.testing.expectEqual(Status.ok, row.status);
    }
    try std.testing.expectEqual(Role.capacity_model, receipt.rows[0].role);
    try std.testing.expectEqual(Role.overload, receipt.rows[1].role);
    try std.testing.expectEqual(Role.work_bound, receipt.rows[2].role);
    try receipt.validate();
}

test "artifact commitment supports bounded streaming" {
    var hasher = ArtifactHasher.init(7);
    try hasher.update("wit");
    try hasher.update("ness");
    try std.testing.expect((try hasher.finish()).eql(artifactId("witness")));

    var short = ArtifactHasher.init(1);
    try std.testing.expectError(error.ArtifactLengthExceeded, short.update("no"));
    try std.testing.expectError(error.ArtifactLengthMismatch, short.finish());
}

test "runner digest validation shares the timing receipt authority" {
    const rows = [_]RunnerRow{
        .{ .name = "fixture ok", .status = .ok },
        .{ .name = "fixture leak", .status = .leak, .leaked = true },
    };
    const encoded = std.fmt.bytesToHex(runner_semantic.digest(&rows), .lower);
    try validateRunDigest(&rows, &encoded);
    var changed = encoded;
    changed[0] = if (changed[0] == '0') '1' else '0';
    try std.testing.expectError(error.RunDigestMismatch, validateRunDigest(&rows, &changed));
}

test "witness merger rejects an inconsistent runner leak status" {
    var output: [1]Row = undefined;
    const annotation = Annotation{
        .test_identity = testId(1),
        .runner = testRunnerId("fixture"),
        .claim = testId(2),
        .obligation = "capacity",
        .role = .capacity_model,
    };
    inline for ([_]RunnerRow{
        .{ .name = "fixture", .status = .ok, .leaked = true },
        .{ .name = "fixture", .status = .leak, .leaked = false },
    }) |runner_row| {
        try std.testing.expectError(
            error.InvalidRunnerLeakStatus,
            join(testContext(), &.{annotation}, .{
                .token = "fixture-run",
                .completed = true,
                .rows = &.{runner_row},
            }, &output),
        );
    }
}

fn testContext() Context {
    return .{
        .registered_step = testId(30),
        .profile = testId(31),
        .artifact = testId(32),
        .compile_unit = .{ .content_root = testId(33), .binding = testId(34) },
    };
}

fn testId(byte: u8) Id {
    return .{ .bytes = @splat(byte) };
}

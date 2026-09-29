const std = @import("std");
const choir = @import("choir");
const accy = @import("../../root.zig");
const tensor = @import("../root.zig");
const fixture = @import("../../fixture/root.zig");
const wire = @import("root.zig");

const Builder = tensor.Builder;
const ByteWriter = accy.artifact.wire.ByteWriter;
const Fingerprint = choir.product.incremental.Fingerprint;
const Operation = tensor.program.Operation;
const Program = tensor.program.Program;
const ScanScope = tensor.trace.builder.ScanScope;
const Tag = wire.format.Tag;
const Value = tensor.Value;

const Fixture = *const fn (std.mem.Allocator) anyerror!Program;

const fixtures = [_]Fixture{
    pointwiseProgram,
    shapeProgram,
    scanProgram,
    lossProgram,
    lossGradientProgram,
    deepestScanProgram,
};

test "tensor wire round trip preserves program fingerprints and bytes" {
    const allocator = std.testing.allocator;
    var covered: std.EnumSet(Tag) = .empty;
    for (fixtures) |build| {
        var source = try build(allocator);
        defer source.deinit();
        coverKinds(&covered, source.operations);

        const bytes = try wire.encode(allocator, &source);
        defer allocator.free(bytes);
        var decoded = try wire.decode(allocator, bytes);
        defer decoded.deinit();
        try std.testing.expectEqual(source.fingerprint(), decoded.fingerprint());

        const again = try wire.encode(allocator, &decoded);
        defer allocator.free(again);
        try std.testing.expectEqualSlices(u8, bytes, again);
    }
    try std.testing.expect(covered.eql(.full));
}

test "tensor wire rejects every truncated prefix" {
    const allocator = std.testing.allocator;
    var source = try scanProgram(allocator);
    defer source.deinit();
    const bytes = try wire.encode(allocator, &source);
    defer allocator.free(bytes);
    for (0..bytes.len) |len| {
        try std.testing.expectError(error.InvalidArtifact, wire.decode(allocator, bytes[0..len]));
    }
}

test "tensor wire rejects foreign headers unknown tags and trailing bytes" {
    const allocator = std.testing.allocator;
    var source = try pointwiseProgram(allocator);
    defer source.deinit();
    const bytes = try wire.encode(allocator, &source);
    defer allocator.free(bytes);
    const corrupt = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupt);

    const first_operation = 3 * @sizeOf(u32) + source.name.len + @sizeOf(u32);
    try expectPatchedError(corrupt, bytes, 0, wire.magic +% 1, error.BadMagic);
    try expectPatchedError(corrupt, bytes, 4, wire.version + 1, error.UnsupportedVersion);
    try expectPatchedError(corrupt, bytes, first_operation, 19, error.UnknownTag);
    try expectPatchedError(corrupt, bytes, first_operation + 4, 14, error.UnknownTag);

    const trailing = try std.mem.concat(allocator, u8, &.{ bytes, &.{0} });
    defer allocator.free(trailing);
    try std.testing.expectError(error.InvalidArtifact, wire.decode(allocator, trailing));
}

test "tensor wire rejects later references and oversized operand lists" {
    const allocator = std.testing.allocator;
    var writer = ByteWriter{};
    defer writer.deinit(allocator);

    try writeHeader(&writer, 1);
    try writer.writeU32(allocator, wire.format.kind_codes.code(.unary));
    try writer.writeU32(allocator, wire.format.unary_codes.code(.neg));
    try writer.writeU32(allocator, 0);
    try writer.writeU32(allocator, 0);
    try std.testing.expectError(error.InvalidReference, wire.decode(allocator, writer.bytes.items));

    writer.bytes.clearRetainingCapacity();
    try writeHeader(&writer, 1);
    try writer.writeU32(allocator, wire.format.kind_codes.code(.custom_call));
    try writer.writeU32(allocator, wire.format.dtype_codes.code(.f32));
    try writer.writeU32(allocator, 0);
    try writer.writeLengthPrefixedBytes(allocator, "accy.custom.double");
    try writer.writeU32(allocator, 1);
    const operand_count = tensor.program.max_custom_call_operands + 1;
    try writer.writeU32(allocator, operand_count);
    for (0..operand_count) |_| try writer.writeU32(allocator, 0);
    try std.testing.expectError(error.TooManyOperands, wire.decode(allocator, writer.bytes.items));
}

test "tensor wire bounds scan nesting when encoding and decoding" {
    const allocator = std.testing.allocator;
    var too_deep = try nestedScanProgram(allocator, wire.max_scan_depth + 1);
    defer too_deep.deinit();
    try std.testing.expectError(error.ScanTooDeep, wire.encode(allocator, &too_deep));

    const deepest = try nestedScanBytes(allocator, wire.max_scan_depth);
    defer allocator.free(deepest);
    var decoded = try wire.decode(allocator, deepest);
    decoded.deinit();

    const deeper = try nestedScanBytes(allocator, wire.max_scan_depth + 1);
    defer allocator.free(deeper);
    try std.testing.expectError(error.ScanTooDeep, wire.decode(allocator, deeper));
}

test "tensor wire encode and decode survive allocation failures" {
    const allocator = std.testing.allocator;
    var source = try nestedScanProgram(allocator, 2);
    defer source.deinit();
    const bytes = try wire.encode(allocator, &source);
    defer allocator.free(bytes);
    try fixture.checkAllAllocationFailures(encodeAll, .{&source});
    try fixture.checkAllAllocationFailures(decodeAll, .{ bytes, source.fingerprint() });
}

fn encodeAll(allocator: std.mem.Allocator, source: *const Program) !void {
    const bytes = try wire.encode(allocator, source);
    allocator.free(bytes);
}

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8, expected: Fingerprint) !void {
    var decoded = try wire.decode(allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(expected, decoded.fingerprint());
}

fn expectPatchedError(
    corrupt: []u8,
    bytes: []const u8,
    offset: usize,
    value: u32,
    expected: anyerror,
) !void {
    @memcpy(corrupt, bytes);
    std.mem.writeInt(u32, corrupt[offset..][0..4], value, .little);
    try std.testing.expectError(expected, wire.decode(std.testing.allocator, corrupt));
}

fn writeHeader(writer: *ByteWriter, operation_count: u32) !void {
    const allocator = std.testing.allocator;
    try writer.writeU32(allocator, wire.magic);
    try writer.writeU32(allocator, wire.version);
    try writer.writeLengthPrefixedBytes(allocator, "wire_crafted");
    try writer.writeU32(allocator, operation_count);
}

fn coverKinds(covered: *std.EnumSet(Tag), operations: []const Operation) void {
    for (operations) |op| {
        covered.insert(std.meta.activeTag(op.kind));
        switch (op.kind) {
            .scan => |scan| for (scan.body.operations) |body_op| {
                covered.insert(std.meta.activeTag(body_op.kind));
            },
            else => {},
        }
    }
}

fn pointwiseProgram(allocator: std.mem.Allocator) anyerror!Program {
    var builder = try Builder.init(allocator, "wire_pointwise");
    errdefer builder.deinit();
    const x = try builder.input(.f32, .{ .lane = 4 });
    const y = try builder.input(.f32, .{ .lane = 4 });
    const sum = try builder.binary(.add, x, try builder.unary(.neg, y));
    const floor = try builder.full(.f32, .{ .lane = 4 }, 0.5);
    const below = try builder.compare(.lt, sum, floor);
    const chosen = try builder.select(below, sum, try builder.unary(.exp, x));
    return builder.finish(&.{ chosen, below });
}

fn shapeProgram(allocator: std.mem.Allocator) anyerror!Program {
    var builder = try Builder.init(allocator, "wire_shapes");
    errdefer builder.deinit();
    const grid = try builder.input(.f32, .{ .row = 2, .col = 3 });
    const columns = try builder.iota(.i32, .{ .row = 2, .col = 3 }, .col);
    const flipped = try builder.transposeBy(grid, &.{ 1, 0 });
    const flat = try builder.reshapeTo(flipped, &.{.{ .name = "cell", .extent = 6 }});
    const scale = try builder.scalar(.f32, 2.0);
    const spread = try builder.broadcastOp(scale, &.{.{ .name = "cell", .extent = 6 }});
    const doubled = try builder.customCall("accy.custom.double", 1, &.{flat}, flat.ty);
    const product = try builder.binary(.mul, doubled, spread);
    return builder.finish(&.{ product, columns });
}

fn scanStep(_: *Builder, carry: anytype) !@TypeOf(carry) {
    const doubled = try carry.x.add(carry.x);
    return .{ .x = doubled, .acc = try carry.acc.add(doubled) };
}

fn scanProgram(allocator: std.mem.Allocator) anyerror!Program {
    var builder = try Builder.init(allocator, "wire_scan");
    errdefer builder.deinit();
    const x = try builder.input(.f32, .{ .lane = 2 });
    const acc = try builder.full(.f32, .{ .lane = 2 }, 0.0);
    const walked = try builder.scan(.{
        .length = 3,
        .init = .{ .x = x, .acc = acc },
        .body = scanStep,
    });
    return builder.finish(&.{ walked.x, walked.acc });
}

const loss_specs = [_]tensor.Spec{
    tensor.spec(.i32, .{ .batch = 2, .token = 3 }),
    tensor.spec(.i32, .{ .batch = 2, .token = 3 }),
    tensor.spec(.f32, .{ .vocab = 11, .channel = 4 }),
    tensor.spec(.f32, .{ .channel = 4, .vocab = 11 }),
};

fn lossBody(_: *Builder, args: []const Value) !Value {
    const hidden = try tensor.nn.embedding(args[2], args[0], .vocab);
    const flat_hidden = try hidden.merge(.{ .batch, .token }, .sample);
    const flat_targets = try args[1].merge(.{ .batch, .token }, .sample);
    const logits = try flat_hidden.contract(args[3], .channel);
    return tensor.nn.sparseCrossEntropyMean(logits, flat_targets, .vocab);
}

fn lossProgram(allocator: std.mem.Allocator) anyerror!Program {
    return tensor.define(allocator, "wire_loss", &loss_specs, lossBody);
}

fn lossGradientProgram(allocator: std.mem.Allocator) anyerror!Program {
    var loss = try lossProgram(allocator);
    defer loss.deinit();
    return tensor.grad(allocator, &loss, .{ .wrt = &.{ 2, 3 } });
}

fn deepestScanProgram(allocator: std.mem.Allocator) anyerror!Program {
    return nestedScanProgram(allocator, wire.max_scan_depth);
}

fn nestedScanProgram(allocator: std.mem.Allocator, depth: usize) anyerror!Program {
    std.debug.assert(depth <= wire.max_scan_depth + 1);
    var builder = try Builder.init(allocator, "wire_nested_scan");
    errdefer builder.deinit();
    var scopes: [wire.max_scan_depth + 1]ScanScope = undefined;
    var opened: usize = 0;
    errdefer for (scopes[0..opened]) |*scope| scope.abort();
    var carry = try builder.input(.f32, .{ .lane = 2 });
    var parent = &builder;
    while (opened < depth) : (opened += 1) {
        scopes[opened] = try parent.scanScope(2, &.{carry});
        parent = scopes[opened].body();
        carry = scopes[opened].carry(0);
    }
    var next = try carry.add(carry);
    while (opened != 0) : (opened -= 1) {
        next = try scopes[opened - 1].finish(&.{next});
    }
    return builder.finish(&.{next});
}

fn nestedScanBytes(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var writer = ByteWriter{};
    errdefer writer.deinit(allocator);
    try writer.writeU32(allocator, wire.magic);
    try writer.writeU32(allocator, wire.version);
    try writer.writeLengthPrefixedBytes(allocator, "wire_deep_scan");
    for (0..depth + 1) |level| {
        try writer.writeU32(allocator, if (level == depth) 1 else 2);
        try writer.writeU32(allocator, wire.format.kind_codes.code(.parameter));
        try writer.writeU32(allocator, wire.format.dtype_codes.code(.f32));
        try writer.writeU32(allocator, 0);
        if (level == depth) break;
        try writer.writeU32(allocator, wire.format.kind_codes.code(.scan));
        try writer.writeU64(allocator, 1);
        try writer.writeU32(allocator, 1);
        try writer.writeU32(allocator, 0);
    }
    for (0..depth + 1) |level| {
        try writer.writeU32(allocator, 1);
        try writer.writeU32(allocator, if (level == 0) 0 else 1);
    }
    return writer.toOwnedSlice(allocator);
}

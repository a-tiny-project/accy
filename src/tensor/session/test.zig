const std = @import("std");
const tensor = @import("../root.zig");
const fixture = @import("../../fixture/root.zig");
const session_mod = @import("root.zig");

const Builder = tensor.Builder;
const Descriptor = session_mod.Descriptor;
const Program = tensor.program.Program;
const Session = session_mod.Session;
const Status = session_mod.Status;

const ProgramFixture = *const fn (std.mem.Allocator) anyerror!Program;
const max_caller_buffers = 16;

test "tensor session matches cpu execution bit for bit on caller memory" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator);
    defer session.deinit();

    const programs = [_]ProgramFixture{ blendProgram, aliasProgram, scanProgram };
    for (programs) |build| {
        var source = try build(allocator);
        defer source.deinit();
        try expectSessionMatchesCpu(allocator, &session, &source);
    }
}

test "tensor session reports stable status codes for rejected calls" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator);
    defer session.deinit();

    var source = try blendProgram(allocator);
    defer source.deinit();
    const bytes = try tensor.wire.encode(allocator, &source);
    defer allocator.free(bytes);
    try expectStatus(.invalid_program, session.compile(bytes[0 .. bytes.len - 1]));
    const bumped = try allocator.dupe(u8, bytes);
    defer allocator.free(bumped);
    std.mem.writeInt(u32, bumped[4..8], tensor.wire.version + 1, .little);
    try expectStatus(.unsupported_version, session.compile(bumped));

    const handle = try session.compile(bytes);
    var memory: CallerMemory = .{};
    defer memory.deinit(allocator);
    const inputs = try memory.buffers(allocator, try session.inputDescriptors(handle));
    const outputs = try memory.buffers(allocator, try session.outputDescriptors(handle));
    try expectStatus(.invalid_buffer, session.invoke(handle, allocator, inputs[0..1], outputs));
    const overlapping = [_][]u8{ inputs[0], outputs[1] };
    try expectStatus(.invalid_buffer, session.invoke(handle, allocator, inputs, &overlapping));
    try session.invoke(handle, allocator, inputs, outputs);

    try session.release(handle);
    try expectStatus(.invalid_handle, session.invoke(handle, allocator, inputs, outputs));
    try expectStatus(.invalid_handle, session.release(handle));
    try expectStatus(.invalid_handle, session.inputDescriptors(handle));
    const reused = try session.compile(bytes);
    try std.testing.expectEqual(handle.index, reused.index);
    try std.testing.expect(handle.generation != reused.generation);

    const pinned = [_]Status{
        .ok,
        .invalid_program,
        .unsupported_version,
        .invalid_handle,
        .invalid_buffer,
        .too_many_programs,
        .out_of_memory,
        .compile_failed,
        .launch_failed,
    };
    for (pinned, 0..) |status, value| {
        try std.testing.expectEqual(@as(u32, @intCast(value)), @backingInt(status));
    }
}

fn expectSessionMatchesCpu(
    allocator: std.mem.Allocator,
    session: *Session,
    source: *const Program,
) !void {
    const bytes = try tensor.wire.encode(allocator, source);
    defer allocator.free(bytes);
    const handle = try session.compile(bytes);
    defer session.release(handle) catch unreachable;
    const input_descriptors = try session.inputDescriptors(handle);
    const output_descriptors = try session.outputDescriptors(handle);
    try std.testing.expectEqual(source.parameters.len, input_descriptors.len);
    try std.testing.expectEqual(source.outputs.len, output_descriptors.len);

    var memory: CallerMemory = .{};
    defer memory.deinit(allocator);
    const inputs = try memory.buffers(allocator, input_descriptors);
    for (inputs, 0..) |input, index| fillFloats(input, index);
    const snapshots = try memory.buffers(allocator, input_descriptors);
    for (snapshots, inputs) |snapshot, input| @memcpy(snapshot, input);
    const outputs = try memory.buffers(allocator, output_descriptors);
    for (outputs) |output| @memset(output, 0xa5);
    const expected = try memory.buffers(allocator, output_descriptors);

    try session.invoke(handle, allocator, inputs, outputs);
    try tensor.runCpu(allocator, source, inputs, expected);
    for (expected, outputs, output_descriptors) |want, got, descriptor| {
        try std.testing.expectEqual(descriptor.byte_size, got.len);
        try std.testing.expectEqualSlices(u8, want, got);
    }
    for (snapshots, inputs) |snapshot, input| {
        try std.testing.expectEqualSlices(u8, snapshot, input);
    }
}

fn expectStatus(expected: Status, result: anytype) !void {
    if (result) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(expected, Status.fromError(err));
    }
}

fn fillFloats(bytes: []u8, seed: usize) void {
    const values = std.mem.bytesAsSlice(f32, bytes);
    for (values, 0..) |*value, index| {
        const step: f32 = @floatFromInt(seed * 7 + index);
        value.* = 0.375 * step - 1.5;
    }
}

const CallerMemory = struct {
    slots: [max_caller_buffers][]u8 = undefined,
    alignments: [max_caller_buffers]std.mem.Alignment = undefined,
    count: usize = 0,

    fn buffers(
        self: *CallerMemory,
        allocator: std.mem.Allocator,
        descriptors: []const Descriptor,
    ) ![]const []u8 {
        const start = self.count;
        for (descriptors) |descriptor| {
            if (self.count == max_caller_buffers) return error.OutOfMemory;
            const alignment = std.mem.Alignment.fromByteUnits(descriptor.alignment);
            const size = descriptor.byte_size;
            const memory = allocator.rawAlloc(size, alignment, @returnAddress()) orelse {
                return error.OutOfMemory;
            };
            self.slots[self.count] = memory[0..size];
            self.alignments[self.count] = alignment;
            self.count += 1;
        }
        return self.slots[start..self.count];
    }

    fn deinit(self: *CallerMemory, allocator: std.mem.Allocator) void {
        for (self.slots[0..self.count], self.alignments[0..self.count]) |bytes, alignment| {
            allocator.rawFree(bytes, alignment, @returnAddress());
        }
    }
};

fn blendProgram(allocator: std.mem.Allocator) anyerror!Program {
    var builder = try Builder.init(allocator, "session_blend");
    errdefer builder.deinit();
    const x = try builder.input(.f32, .{ .lane = 8 });
    const y = try builder.input(.f32, .{ .lane = 8 });
    const bias = try builder.full(.f32, .{ .lane = 8 }, 0.5);
    const scaled = try builder.binary(.mul, try builder.unary(.tanh, x), y);
    const mixed = try builder.binary(.add, scaled, bias);
    const larger = try builder.binary(.max, x, y);
    return builder.finish(&.{ mixed, larger });
}

fn aliasProgram(allocator: std.mem.Allocator) anyerror!Program {
    var builder = try Builder.init(allocator, "session_alias");
    errdefer builder.deinit();
    const x = try builder.input(.f32, .{ .lane = 8 });
    const y = try builder.input(.f32, .{ .lane = 8 });
    const sum = try builder.binary(.add, x, y);
    return builder.finish(&.{ x, sum, sum });
}

fn scanProgram(allocator: std.mem.Allocator) anyerror!Program {
    var builder = try Builder.init(allocator, "session_scan");
    errdefer builder.deinit();
    const x = try builder.input(.f32, .{ .lane = 8 });
    const c = try builder.input(.f32, .{ .lane = 8 });
    const acc = try builder.full(.f32, .{ .lane = 8 }, 0.0);
    const walked = try builder.scan(.{
        .length = 5,
        .init = .{ .x = x, .acc = acc, .c = c },
        .body = scanStep,
    });
    return builder.finish(&.{ walked.x, walked.acc });
}

fn scanStep(builder: *Builder, carry: anytype) !@TypeOf(carry) {
    const half = try builder.scalar(.f32, 0.5);
    const next_x = try (try (try carry.x.mul(carry.x)).mul(half)).add(carry.c);
    return .{ .x = next_x, .acc = try carry.acc.add(next_x), .c = carry.c };
}

const std = @import("std");
const accy = @import("accy");

pub fn main() !void {
    try exerciseProgram();
}

test "Accy records a program and runs it where the host has a CPU backend" {
    try exerciseProgram();
}

fn scaleShift(_: *accy.tensor.Builder, args: []const accy.tensor.Value) !accy.tensor.Value {
    const doubled = try args[0].add(args[0]);
    return doubled.add(args[1]);
}

fn exerciseProgram() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    const allocator = heap.allocator();

    var program = try accy.tensor.define(allocator, "scale_shift", &.{
        accy.tensor.spec(.f32, .{ .lane = 4 }),
        accy.tensor.spec(.f32, .{ .lane = 4 }),
    }, scaleShift);
    defer program.deinit();
    try std.testing.expectEqual(2, program.parameters.len);
    try std.testing.expectEqual(1, program.outputs.len);
    if (!accy.target.native_cpu_artifacts_supported) return;

    const x = [_]f32{ 1, 2, 3, 4 };
    const y = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var out: [4]f32 = @splat(0);
    try accy.tensor.runCpu(allocator, &program, &.{
        std.mem.sliceAsBytes(&x),
        std.mem.sliceAsBytes(&y),
    }, &.{std.mem.sliceAsBytes(&out)});
    try std.testing.expectEqualSlices(f32, &.{ 2.5, 4.5, 6.5, 8.5 }, &out);
}

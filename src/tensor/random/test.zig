const std = @import("std");
const gpu_abi = @import("gpu_abi");
const accy = @import("../../root.zig");
const tensor = @import("../root.zig");
const namespace = @import("root.zig");
const DType = tensor.DType;
const Builder = tensor.Builder;
const Key = namespace.Key;
const seed = namespace.seed;
const uniform = namespace.uniform;

test "tensor random seed creates scalar key constants" {
    var builder = try Builder.init(std.testing.allocator, "random_seed");
    defer builder.deinit();

    const seeded = try seed(&builder, 0x01234567_89abcdef, .{});
    try std.testing.expectEqual(DType.key, seeded.value.ty.dtype);
    try std.testing.expectEqual(@as(usize, 0), seeded.value.ty.rank());
    const payload = builder.operations.items[seeded.value.id.index].kind.constant.payload;
    const keys = std.mem.bytesAsSlice(gpu_abi.Key, @constCast(payload));
    try std.testing.expectEqual(@as(u64, 0x01234567_89abcdef), keys[0].bits);
}

test "tensor random split names the sample axis and lowers to custom calls" {
    var builder = try Builder.init(std.testing.allocator, "random_split_uniform");
    defer builder.deinit();

    const seeded = try seed(&builder, 7, .{ .threads = 64 });
    const keys = try seeded.split(.{ .sample = 8 });
    const out = try keys.uniform(.f32);

    try std.testing.expectEqual(DType.key, keys.value.ty.dtype);
    try tensor.types.expectExtents(&.{8}, keys.value.ty);
    try std.testing.expectEqualStrings("sample", keys.value.ty.dims[0].name);
    try std.testing.expectEqual(DType.f32, out.ty.dtype);
    try std.testing.expectEqualStrings("sample", out.ty.dims[0].name);

    const split_call = builder.operations.items[keys.value.id.index].kind.custom_call;
    try std.testing.expectEqualStrings("accy.kernel.random.philox_key_split_family_10r_64_key", split_call.target);
    try std.testing.expectEqual(accy.kernel.library.random.philox_key_split_family_version, split_call.version);

    const uniform_call = builder.operations.items[out.id.index].kind.custom_call;
    try std.testing.expectEqualStrings("accy.kernel.random.philox_key_uniform_family_10r_64_f32", uniform_call.target);
    try std.testing.expectEqual(accy.kernel.library.random.philox_key_uniform_family_version, uniform_call.version);

    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try tensor.toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
}

test "tensor random counter uniform lowers to key and counter custom call" {
    var builder = try Builder.init(std.testing.allocator, "random_counter_uniform");
    defer builder.deinit();

    const seeded = try seed(&builder, 7, .{ .threads = 64 });
    const counter = try builder.scalar(.i32, 3);
    const out = try seeded.counterUniform(counter, .{ .draw = 8 }, .f32);

    try std.testing.expectEqual(DType.f32, out.ty.dtype);
    try tensor.types.expectExtents(&.{8}, out.ty);
    try std.testing.expectEqualStrings("draw", out.ty.dims[0].name);

    const uniform_call = builder.operations.items[out.id.index].kind.custom_call;
    try std.testing.expectEqualStrings("accy.kernel.random.philox_key_counter_uniform_family_10r_64_f32", uniform_call.target);
    try std.testing.expectEqual(accy.kernel.library.random.philox_key_counter_uniform_family_version, uniform_call.version);
    try std.testing.expectEqual(@as(usize, 2), uniform_call.operands.len);

    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try tensor.toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
}

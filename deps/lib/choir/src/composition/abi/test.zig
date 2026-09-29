const std = @import("std");
const abi = @import("root.zig");

test "composition ABI rejects incompatible owners before resource access" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(abi.Context));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(abi.Resource));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(abi.Frame));

    var value_context = abi.Context.init(0x1000, 0x2000);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var resources = [_]abi.Resource{abi.Resource.init(value_context.owner_cookie, 7, &bytes, .read_write)};
    var value_frame = abi.Frame.init(value_context.owner_cookie, 7, &resources);

    try std.testing.expectEqual(abi.Status.ok, value_context.validate());
    try std.testing.expectEqual(abi.Status.ok, value_frame.validate(&value_context));
    const resolved = value_frame.resources(&value_context);
    try std.testing.expect(resolved == .value);
    try std.testing.expectEqual(@as(usize, 1), resolved.value.len);

    const original_version = value_frame.version;
    value_frame.version = abi.version + 1;
    try std.testing.expectEqual(abi.Status.incompatible_frame, value_frame.validate(&value_context));
    value_frame.version = original_version;

    const original_size = value_frame.byte_size;
    value_frame.byte_size = @sizeOf(abi.Frame) - 1;
    try std.testing.expectEqual(abi.Status.incompatible_frame, value_frame.validate(&value_context));
    value_frame.status = 0xfeed;
    value_frame.setStatusIfCompatible(.fragment_failure);
    try std.testing.expectEqual(@as(u32, 0xfeed), value_frame.status);
    value_frame.byte_size = original_size;

    resources[0].invocation_id = 8;
    const foreign = value_frame.resources(&value_context);
    try std.testing.expect(foreign == .status);
    try std.testing.expectEqual(abi.Status.invalid_resource, foreign.status);
    resources[0].invocation_id = 7;
    resources[0].access = 0xfeed;
    const invalid_access = value_frame.resources(&value_context);
    try std.testing.expect(invalid_access == .status);
    try std.testing.expectEqual(abi.Status.invalid_resource, invalid_access.status);

    value_context.version = abi.version + 1;
    try std.testing.expectEqual(abi.Status.incompatible_context, value_context.validate());

    try std.testing.expectEqual(abi.Status.ok, abi.decodeStatus(@as(i64, @backingInt(abi.Status.ok))));
    try std.testing.expectEqual(abi.Status.fragment_failure, abi.decodeStatus(@as(i64, -1)));
    try std.testing.expectEqual(abi.Status.fragment_failure, abi.decodeStatus(@as(u64, std.math.maxInt(u32)) + 1));
}

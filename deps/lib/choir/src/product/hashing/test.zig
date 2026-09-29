const std = @import("std");
const alloc_arena = @import("alloc_arena");
const hashing = @import("root.zig");
const ir = @import("../../core/root.zig");

test {
    std.testing.refAllDecls(hashing);
}

test "operation fingerprint exposes initialization failure" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const operation = try context.createOperation(ir.Operation.State.init(
        "test.fingerprint",
        ir.Location.getUnknown(),
    ));
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        hashing.operationFingerprint(failing.allocator(), operation),
    );
}

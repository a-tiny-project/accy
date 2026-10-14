const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

pub fn write(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!void {
    try common.writeSectionHeader(out, .type, plan.sections.type);
    try writeBody(out, plan, module);
}

pub fn countBody(
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!usize {
    var count = wasm.binary.Count{};
    try writeBody(&count, plan, module);
    return common.requireU32(count.len);
}

fn writeBody(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!void {
    const math_types: usize = @intFromBool(plan.math.count() != 0);
    _ = try common.requireU32(plan.functionCount() + math_types);
    try wasm.binary.writeUleb(out, plan.functionCount() + math_types);
    var functions = try emission.walk.Functions.init(module);
    while (try functions.next()) |function| {
        try out.writeByte(0x60);
        try common.writeTypeVector(out, function.getInputTypes() orelse &.{});
        try common.writeTypeVector(out, function.getResultTypes());
    }
    // (f64) -> f64, the one type every math import shares, at `plan.mathType()`.
    if (math_types != 0) try out.writeAll(&.{ 0x60, 0x01, 0x7c, 0x01, 0x7c });
}

const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

pub fn write(out: anytype, plan: *const emission.Plan) emission.Error!void {
    try common.writeSectionHeader(out, .memory, plan.sections.memory);
    try writeBody(out, plan);
}

pub fn countBody(plan: *const emission.Plan) emission.Error!usize {
    var count = wasm.binary.Count{};
    try writeBody(&count, plan);
    return count.len;
}

/// One memory with no maximum, at least as many pages as the globals need.
fn writeBody(out: anytype, plan: *const emission.Plan) emission.Error!void {
    try wasm.binary.writeUleb(out, @as(u32, 1));
    try out.writeByte(0x00);
    try wasm.binary.writeUleb(out, plan.data.pages());
}

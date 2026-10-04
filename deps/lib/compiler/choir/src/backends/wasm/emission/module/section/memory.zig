const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

pub fn write(out: anytype, plan: *const emission.Plan) emission.Error!void {
    try common.writeSectionHeader(out, .memory, plan.sections.memory);
    try writeBody(out);
}

pub fn countBody() emission.Error!usize {
    var count = wasm.binary.Count{};
    try writeBody(&count);
    return count.len;
}

fn writeBody(out: anytype) emission.Error!void {
    try wasm.binary.writeUleb(out, @as(u32, 1));
    try out.writeByte(0x00);
    try wasm.binary.writeUleb(out, @as(u32, 1));
}

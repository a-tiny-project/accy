const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

pub fn write(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!void {
    try common.writeSectionHeader(out, .import, plan.sections.import);
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
    _ = try common.requireU32(plan.importCount());
    try wasm.binary.writeUleb(out, plan.importCount());
    var symbols = try emission.symbols.Iterator.init(module, .{});
    while (try symbols.next()) |symbol| {
        if (symbol.role != .required) continue;
        try common.writeName(out, "env");
        try common.writeName(out, symbol.name);
        try out.writeByte(@backingInt(wasm.binary.ExternalKind.function));
        _ = try common.requireU32(symbol.function_ordinal);
        try wasm.binary.writeUleb(out, symbol.function_ordinal);
    }
}

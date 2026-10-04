const std = @import("std");
const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

const memory_export_name = "memory";

pub fn write(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
    options: emission.Options,
) emission.Error!void {
    try common.writeSectionHeader(out, .export_, plan.sections.export_);
    try writeBody(out, plan, module, options);
}

pub fn countBody(
    plan: *const emission.Plan,
    module: *common.ir.Operation,
    options: emission.Options,
) emission.Error!usize {
    var count = wasm.binary.Count{};
    try writeBody(&count, plan, module, options);
    return common.requireU32(count.len);
}

pub fn entryCount(
    module: *common.ir.Operation,
    options: emission.Options,
    needs_memory: bool,
) emission.Error!usize {
    var count: usize = if (needs_memory) 1 else 0;
    var symbols = try emission.symbols.Iterator.init(module, options);
    while (try symbols.next()) |symbol| {
        if (symbol.role != .provided) continue;
        if (needs_memory and std.mem.eql(u8, symbol.name, memory_export_name)) {
            return error.CodeGenFailed;
        }
        count = std.math.add(usize, count, 1) catch return error.CapacityOverflow;
    }
    return count;
}

fn writeBody(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
    options: emission.Options,
) emission.Error!void {
    const count = try entryCount(module, options, plan.needsMemory());
    _ = try common.requireU32(count);
    try wasm.binary.writeUleb(out, count);
    var symbols = try emission.symbols.Iterator.init(module, options);
    while (try symbols.next()) |symbol| {
        if (symbol.role != .provided) continue;
        const function_index = plan.functionIndex(symbol.name) orelse
            return error.FunctionNotFound;
        try common.writeName(out, symbol.name);
        try out.writeByte(@backingInt(wasm.binary.ExternalKind.function));
        try wasm.binary.writeUleb(out, function_index);
    }
    if (plan.needsMemory()) {
        try common.writeName(out, memory_export_name);
        try out.writeByte(@backingInt(wasm.binary.ExternalKind.memory));
        try wasm.binary.writeUleb(out, @as(u32, 0));
    }
}

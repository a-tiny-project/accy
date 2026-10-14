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
    plan: *const emission.Plan,
) emission.Error!usize {
    const needs_memory = plan.needsMemory();
    const has_data = plan.data.globals != 0;
    var count: usize = @as(usize, @intFromBool(needs_memory)) + @intFromBool(has_data);
    var symbols = try emission.symbols.Iterator.init(module, options);
    while (try symbols.next()) |symbol| {
        if (symbol.role != .provided) continue;
        if (needs_memory and std.mem.eql(u8, symbol.name, memory_export_name)) {
            return error.CodeGenFailed;
        }
        if (has_data and std.mem.eql(u8, symbol.name, emission.data.end_export_name)) {
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
    const count = try entryCount(module, options, plan);
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
    if (plan.data.globals != 0) {
        try common.writeName(out, emission.data.end_export_name);
        try out.writeByte(@backingInt(wasm.binary.ExternalKind.global));
        try wasm.binary.writeUleb(out, @as(u32, 0));
    }
}

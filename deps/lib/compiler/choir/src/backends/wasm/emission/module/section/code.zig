const std = @import("std");
const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

pub fn prepareBodies(
    plan: *emission.Plan,
    module: *common.ir.Operation,
    frames: []emission.function.Frame,
) emission.Error!void {
    const module_op = try common.moduleOperation(module);
    var ordinal: usize = 0;
    var operations = module_op.getBodyBlock().getOperations();
    while (operations.next()) |operation| : (ordinal += 1) {
        const function = try common.functionOperation(operation);
        if (function.isDeclaration()) continue;
        var count = wasm.binary.Count{};
        try emission.function.writeContent(
            &count,
            plan,
            function,
            ordinal,
            plan.localCount(ordinal),
            frames,
        );
        _ = try common.requireU32(count.len);
        plan.functions[ordinal].body_bytes = count.len;
    }
}

pub fn write(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
    frames: []emission.function.Frame,
) emission.Error!void {
    try common.writeSectionHeader(out, .code, plan.sections.code);
    try writeBody(out, plan, module, frames);
}

pub fn countBody(
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!usize {
    var count = wasm.binary.Count{};
    _ = try common.requireU32(plan.definitionCount());
    try wasm.binary.writeUleb(&count, plan.definitionCount());
    const module_op = try common.moduleOperation(module);
    var ordinal: usize = 0;
    var operations = module_op.getBodyBlock().getOperations();
    while (operations.next()) |operation| : (ordinal += 1) {
        const function = try common.functionOperation(operation);
        if (function.isDeclaration()) continue;
        const body_bytes = plan.bodyBytes(ordinal);
        _ = try common.requireU32(body_bytes);
        try wasm.binary.writeUleb(&count, body_bytes);
        count.len = std.math.add(usize, count.len, body_bytes) catch
            return error.CapacityOverflow;
    }
    return common.requireU32(count.len);
}

fn writeBody(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
    frames: []emission.function.Frame,
) emission.Error!void {
    _ = try common.requireU32(plan.definitionCount());
    try wasm.binary.writeUleb(out, plan.definitionCount());
    const module_op = try common.moduleOperation(module);
    var ordinal: usize = 0;
    var operations = module_op.getBodyBlock().getOperations();
    while (operations.next()) |operation| : (ordinal += 1) {
        const function = try common.functionOperation(operation);
        if (function.isDeclaration()) continue;
        const body_bytes = plan.bodyBytes(ordinal);
        _ = try common.requireU32(body_bytes);
        try wasm.binary.writeUleb(out, body_bytes);
        try emission.function.writeContent(
            out,
            plan,
            function,
            ordinal,
            plan.localCount(ordinal),
            frames,
        );
    }
}

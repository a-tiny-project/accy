const std = @import("std");
const wasm = @import("../../root.zig");
const emission = @import("../root.zig");
const section = @import("section/root.zig");

pub const common = @import("common.zig");

pub fn preparePlan(
    plan: *emission.Plan,
    module: *common.ir.Operation,
    options: emission.Options,
    frames: []emission.function.Frame,
) emission.Error!usize {
    _ = try common.moduleOperation(module);
    if (options.entry) |entry| {
        if (plan.functionIndex(entry) == null) return error.FunctionNotFound;
    }

    try section.code.prepareBodies(plan, module, frames);
    plan.sections.type = try section.type_section.countBody(plan, module);
    if (plan.importCount() > 0) {
        plan.sections.import = try section.import_section.countBody(plan, module);
    }
    if (plan.definitionCount() > 0) {
        plan.sections.function = try section.function_section.countBody(plan, module);
        plan.sections.code = try section.code.countBody(plan, module);
    }
    if (plan.needsMemory()) {
        plan.sections.memory = try section.memory.countBody(plan);
    }
    if (try section.export_section.entryCount(module, options, plan) > 0) {
        plan.sections.export_ = try section.export_section.countBody(plan, module, options);
    }
    return moduleByteSize(plan, module);
}

pub fn write(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
    options: emission.Options,
    frames: []emission.function.Frame,
) emission.Error!void {
    _ = try common.moduleOperation(module);
    try wasm.binary.writeHeader(out);
    try section.type_section.write(out, plan, module);
    if (plan.importCount() > 0) {
        try section.import_section.write(out, plan, module);
    }
    if (plan.definitionCount() > 0) {
        try section.function_section.write(out, plan, module);
    }
    if (plan.needsMemory()) {
        try section.memory.write(out, plan);
    }
    if (plan.data.globals != 0) try emission.data.writeGlobalSection(out, plan.data);
    if (plan.sections.export_ > 0) {
        try section.export_section.write(out, plan, module, options);
    }
    if (plan.definitionCount() > 0) {
        try section.code.write(out, plan, module, frames);
    }
    if (plan.data.globals != 0) try emission.data.writeSection(out, module, plan.data);
}

fn moduleByteSize(plan: *const emission.Plan, module: *common.ir.Operation) emission.Error!usize {
    var count = wasm.binary.Count{};
    try wasm.binary.writeHeader(&count);
    try addSectionSize(&count, .type, plan.sections.type);
    if (plan.importCount() > 0) {
        try addSectionSize(&count, .import, plan.sections.import);
    }
    if (plan.definitionCount() > 0) {
        try addSectionSize(&count, .function, plan.sections.function);
    }
    if (plan.needsMemory()) {
        try addSectionSize(&count, .memory, plan.sections.memory);
    }
    if (plan.sections.export_ > 0) {
        try addSectionSize(&count, .export_, plan.sections.export_);
    }
    if (plan.definitionCount() > 0) {
        try addSectionSize(&count, .code, plan.sections.code);
    }
    if (plan.data.globals != 0) {
        try emission.data.writeGlobalSection(&count, plan.data);
        try emission.data.writeSection(&count, module, plan.data);
    }
    return count.len;
}

fn addSectionSize(
    count: *wasm.binary.Count,
    section_id: wasm.binary.Section,
    body_bytes: usize,
) emission.Error!void {
    try common.writeSectionHeader(count, section_id, body_bytes);
    count.len = std.math.add(usize, count.len, body_bytes) catch
        return error.CapacityOverflow;
}

//! Where each `memref.global` lives in linear memory.
//!
//! Globals carrying bytes come first, in module order, then zeroed ones, each at its declared
//! alignment from address 0. One active segment carries the initialized extent: a fresh
//! instance's memory is already zero past it, so a zeroed global costs no module bytes. `end`,
//! rounded up to 16, is exported as `__data_end`, and a host places its workspace at or above it.

const std = @import("std");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");
const wasm = @import("../root.zig");
const emission = @import("root.zig");

const GlobalOp = dialects.MemrefDialect.GlobalOp;

pub const end_alignment = 16;
pub const end_export_name = "__data_end";

pub const Layout = struct {
    globals: usize = 0,
    /// Bytes the active segment carries, from address 0.
    initialized_end: u32 = 0,
    /// `__data_end`, where a host's workspace may begin.
    end: u32 = 0,

    /// The pages memory declares at least, so every global lies inside it.
    pub fn pages(self: Layout) u32 {
        return @max(1, std.math.divCeil(u32, self.end, 65536) catch unreachable);
    }
};

const Placement = struct { global: GlobalOp, start: u32, size: u32 };

/// Each global with its address, in layout order: two passes over the module body, bounded by
/// its length.
const Placements = struct {
    block: *ir.Block,
    operations: ir.Block.OperationIterator,
    initialized: bool = true,
    cursor: u64 = 0,

    fn init(module: *ir.Operation) emission.Error!Placements {
        const block = (try emission.module_encoding.common.moduleOperation(module)).getBodyBlock();
        return .{ .block = block, .operations = block.getOperations() };
    }

    fn next(self: *Placements) emission.Error!?Placement {
        while (true) {
            const operation = self.operations.next() orelse {
                if (!self.initialized) return null;
                self.initialized = false;
                self.operations = self.block.getOperations();
                continue;
            };
            if (!std.mem.eql(u8, operation.name.name, GlobalOp.operation_name)) continue;
            const global = GlobalOp{ .op = operation };
            if ((global.getInitial() != null) != self.initialized) continue;
            const memref_type = global.getType() orelse return error.CodeGenFailed;
            const size = dialects.memref.staticByteSize(memref_type) orelse return error.CodeGenFailed;
            const alignment = global.getAlignment() orelse return error.CodeGenFailed;
            if (alignment == 0 or alignment > dialects.memref.max_global_alignment) return error.CodeGenFailed;
            const start = std.mem.alignForward(u64, self.cursor, alignment);
            self.cursor = std.math.add(u64, start, size) catch return error.CapacityOverflow;
            _ = try fit(self.cursor);
            return .{ .global = global, .start = @intCast(start), .size = @intCast(size) };
        }
    }
};

pub fn layout(module: *ir.Operation) emission.Error!Layout {
    var result: Layout = .{};
    var placements = try Placements.init(module);
    while (try placements.next()) |placement| {
        result.globals += 1;
        if (placements.initialized) result.initialized_end = placement.start + placement.size;
    }
    result.end = try fit(std.mem.alignForward(u64, placements.cursor, end_alignment));
    return result;
}

/// The address `layout` gives `global`.
pub fn offset(global: GlobalOp) emission.Error!u32 {
    const module = global.op.getParentOp() orelse return error.CodeGenFailed;
    var placements = try Placements.init(module);
    while (try placements.next()) |placement| {
        if (placement.global.op == global.op) return placement.start;
    }
    return error.CodeGenFailed;
}

/// One active segment at address 0 holding `data.initialized_end` bytes, or none.
pub fn writeSection(out: anytype, module: *ir.Operation, data: Layout) emission.Error!void {
    var count = wasm.binary.Count{};
    try writeSegments(&count, module, data);
    try wasm.binary.writeSectionHeader(out, .data, count.len);
    try writeSegments(out, module, data);
}

fn writeSegments(out: anytype, module: *ir.Operation, data: Layout) emission.Error!void {
    try out.writeAll(&.{ 0x01, 0x00, 0x41, 0x00, 0x0b }); // one active segment at i32.const 0
    try wasm.binary.writeUleb(out, data.initialized_end);
    var written: u32 = 0;
    var placements = try Placements.init(module);
    while (try placements.next()) |placement| {
        if (!placements.initialized) break;
        while (written < placement.start) : (written += 1) try out.writeByte(0);
        try out.writeAll(placement.global.getInitial() orelse return error.CodeGenFailed);
        written += placement.size;
    }
    if (written != data.initialized_end) return error.InputChanged;
}

/// The immutable i32 global holding `__data_end`, exported under that name.
pub fn writeGlobalSection(out: anytype, data: Layout) emission.Error!void {
    var count = wasm.binary.Count{};
    try writeGlobal(&count, data);
    try wasm.binary.writeSectionHeader(out, .global, count.len);
    try writeGlobal(out, data);
}

fn writeGlobal(out: anytype, data: Layout) emission.Error!void {
    try out.writeAll(&.{ 0x01, @backingInt(wasm.binary.ValueType.i32), 0x00, 0x41 });
    try wasm.binary.writeSleb(out, @as(i32, @bitCast(data.end))); // i32.const reads signed
    try out.writeByte(0x0b);
}

fn fit(bytes: u64) emission.Error!u32 {
    if (bytes > std.math.maxInt(u32)) return error.CapacityOverflow;
    return @intCast(bytes);
}

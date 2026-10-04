//! Pure projection of a `memref.global` declaration into a machine data symbol.
//!
//! Target owners decide which declarations they admit. This mapping preserves the
//! dialect's section and size semantics for both object and native producers.

const std = @import("std");
const memref = @import("../dialects/memref.zig");
const machine = @import("machine.zig");

pub const Error = error{InvalidDataSymbol};

comptime {
    if (memref.max_global_alignment != machine.max_data_alignment) {
        @compileError("memref global alignment bound must match the data symbol bound");
    }
}

pub fn symbolOfGlobal(global: memref.MemrefDialect.GlobalOp) Error!machine.DataSymbol {
    const name = global.getSymName() orelse return error.InvalidDataSymbol;
    const placement = global.getPlacement() orelse return error.InvalidDataSymbol;
    const memref_type = global.getType() orelse return error.InvalidDataSymbol;
    const size = memref.staticByteSize(memref_type) orelse return error.InvalidDataSymbol;
    const alignment = global.getAlignment() orelse return error.InvalidDataSymbol;
    if (alignment > machine.max_data_alignment) return error.InvalidDataSymbol;
    if (size > std.math.maxInt(usize)) return error.InvalidDataSymbol;
    const symbol: machine.DataSymbol = switch (placement) {
        .read_only, .writable => .{
            .name = name,
            .bytes = global.getInitial() orelse return error.InvalidDataSymbol,
            .alignment = @intCast(alignment),
            .binding = .global,
            .section = if (placement == .read_only) .rodata else .data,
        },
        .zeroed => .{
            .name = name,
            .reserved_size = @intCast(size),
            .alignment = @intCast(alignment),
            .binding = .global,
            .section = .bss,
        },
    };
    if (!symbol.isValid()) return error.InvalidDataSymbol;
    return symbol;
}

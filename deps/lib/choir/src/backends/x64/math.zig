const std = @import("std");
const sys = @import("sys");

pub fn registerSymbols(
    runtime: anytype,
) (std.mem.Allocator.Error || error{JitRuntimeFull})!void {
    for (sys.math.symbols) |symbol| {
        try runtime.registerExternalSymbol(symbol.name(), symbol.address());
    }
}

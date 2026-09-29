const std = @import("std");
const coo = @import("coo.zig");
const csr = @import("csr.zig");
const descriptor = @import("descriptor.zig");
const ell = @import("ell.zig");
const operation = @import("operation.zig");
const schedule = @import("schedule.zig");
const sell = @import("sell.zig");
const sparse = @import("root.zig");
const spmm = @import("spmm.zig");
const structure = @import("structure.zig");

test {
    @import("test_discovery").discover(sparse);
    @import("test_discovery").discover(coo);
    @import("test_discovery").discover(csr);
    @import("test_discovery").discover(descriptor);
    @import("test_discovery").discover(ell);
    @import("test_discovery").discover(operation);
    @import("test_discovery").discover(schedule);
    @import("test_discovery").discover(sell);
    @import("test_discovery").discover(spmm);
    @import("test_discovery").discover(structure);
}

test "accy kernel library catalog match sparse declaration coverage" {
    std.testing.refAllDecls(sparse);
    std.testing.refAllDecls(coo);
    std.testing.refAllDecls(csr);
    std.testing.refAllDecls(descriptor);
    std.testing.refAllDecls(ell);
    std.testing.refAllDecls(operation);
    std.testing.refAllDecls(schedule);
    std.testing.refAllDecls(sell);
    std.testing.refAllDecls(spmm);
    std.testing.refAllDecls(structure);
}

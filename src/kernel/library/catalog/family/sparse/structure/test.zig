const std = @import("std");
const coo = @import("coo.zig");
const csr = @import("csr.zig");
const ell = @import("ell.zig");
const sell = @import("sell.zig");
const spmm = @import("spmm.zig");

test {
    @import("test_discovery").discover(coo);
    @import("test_discovery").discover(csr);
    @import("test_discovery").discover(ell);
    @import("test_discovery").discover(sell);
    @import("test_discovery").discover(spmm);
}

test "accy kernel library catalog family sparse structure declaration coverage" {
    std.testing.refAllDecls(coo);
    std.testing.refAllDecls(csr);
    std.testing.refAllDecls(ell);
    std.testing.refAllDecls(sell);
    std.testing.refAllDecls(spmm);
}

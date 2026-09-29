const std = @import("std");
const bench = @import("root.zig");
const instrumentation = @import("instrumentation.zig");
const stats = @import("stats/root.zig");
const event = @import("event.zig");
const evidence = @import("evidence.zig");
const output = @import("output.zig");
const suite = @import("suite.zig");
const allocation = @import("allocation.zig");
const parse = @import("parse.zig");
const jsonl_mod = @import("jsonl.zig");
const recovery = @import("recovery.zig");
const compare_mod = @import("compare/root.zig");
const metadata_mod = @import("metadata.zig");
const summary_mod = @import("summary.zig");

test "bench package namespace" {
    _ = bench;
    _ = bench.floor;
    _ = @import("compare/test.zig");
    _ = @import("stats/test.zig");
    std.testing.refAllDecls(instrumentation);
    std.testing.refAllDecls(stats);
    std.testing.refAllDecls(event);
    std.testing.refAllDecls(evidence);
    std.testing.refAllDecls(output);
    std.testing.refAllDecls(suite);
    std.testing.refAllDecls(allocation);
    std.testing.refAllDecls(parse);
    std.testing.refAllDecls(jsonl_mod);
    std.testing.refAllDecls(recovery);
    std.testing.refAllDecls(compare_mod);
    std.testing.refAllDecls(metadata_mod);
    std.testing.refAllDecls(summary_mod);
}

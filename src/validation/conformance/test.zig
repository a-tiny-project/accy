const run = @import("run.zig");
const namespace = @import("root.zig");
const cases = namespace.cases;
const harness = namespace.harness;
const records = namespace.records;

test "accy validation conformance namespace" {
    _ = cases;
    _ = harness;
    _ = records;
    _ = run;
}

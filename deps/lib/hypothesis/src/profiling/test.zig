pub const corpus = @import("corpus.zig");
pub const database = @import("database.zig");
pub const draw = @import("draw.zig");
pub const engine = @import("engine.zig");
pub const shrink = @import("shrink.zig");
pub const suite = @import("suite.zig");

test "bench: profiling suite imports" {
    _ = suite;
    _ = corpus;
    _ = database;
    _ = shrink;
    _ = engine;
}

const topology = @import("../root.zig");

extern "c" fn emscripten_has_threading_support() c_int;
extern "c" fn emscripten_num_logical_cores() c_int;

pub fn haveThreadingSupport() bool {
    return emscripten_has_threading_support() != 0;
}

pub fn totalLogicalProcessors() usize {
    const count = emscripten_num_logical_cores();
    if (count <= 0) return 1;
    return @min(@as(usize, @intCast(count)), topology.max_logical_processors);
}

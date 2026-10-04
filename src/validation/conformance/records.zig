pub const Case = struct {
    kind: []const u8 = "accy.conformance.case",
    backend: []const u8 = "cuda",
    name: []const u8,
    status: []const u8,
    detail: []const u8 = "",
    ptxas: []const u8 = "skip",
    kernels: usize,
    compile_ns: u64,
    launch_read_ns: u64,
    checksum: f32,
    max_abs_error: f32,
    tolerance: f32,
};

pub const Summary = struct {
    kind: []const u8 = "accy.conformance.summary",
    backend: []const u8 = "cuda",
    status: []const u8,
    mode: []const u8,
    cases: usize,
    failures: usize,
    unsupported: usize,
    invalid: usize,
    assembled: usize,
    total_compile_ns: u64,
    total_launch_read_ns: u64,
};

pub const Skip = struct {
    kind: []const u8 = "accy.conformance.skip",
    backend: []const u8 = "cuda",
    reason: []const u8,
};

const backends = @import("../../root.zig");
const data = @import("data.zig");
const math = @import("math.zig");

pub const Options = backends.interface.EmitOptions;

pub const Error = error{
    AlreadyActive,
    AlreadyEmitted,
    CapacityOverflow,
    CodeGenFailed,
    FunctionNotFound,
    InputChanged,
    NestingLimitExceeded,
    NotActive,
    OutOfMemory,
    OutputOverflow,
    OutputUnderflow,
    UnsupportedOperation,
};

pub const max_nesting_depth: usize = 256;

pub const Facts = struct {
    function_count: usize,
    import_count: usize,
    definition_count: usize,
    value_count: usize,
    local_count: usize,
    nesting_depth: usize,
    needs_memory: bool,
    data: data.Layout = .{},
    /// Every f64 math operation the module uses, imported only when the caller opts in.
    math: math.Set = .{},
};

pub const SectionSizes = struct {
    type: usize = 0,
    import: usize = 0,
    function: usize = 0,
    memory: usize = 0,
    export_: usize = 0,
    code: usize = 0,
};

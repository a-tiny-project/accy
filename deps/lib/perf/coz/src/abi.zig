pub const CounterKind = enum(c_int) {
    throughput = 1,
    begin = 2,
    end = 3,
};

pub const Counter = extern struct {
    count: usize = 0,
    backoff: usize = 0,
};

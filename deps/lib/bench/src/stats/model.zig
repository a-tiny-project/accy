pub const default_bootstrap_iterations: u32 = 1000;
pub const default_bootstrap_seed: u64 = 0x5449_4e59_4245_4e43;

pub const BootstrapConfig = struct {
    iterations: u32 = default_bootstrap_iterations,
    seed: u64 = default_bootstrap_seed,
    confidence_per_mille: u16 = 950,
};

pub const ConfidenceInterval = struct {
    low_ns: f64,
    high_ns: f64,
};

pub const BootstrapConfidenceIntervals = struct {
    confidence: f64,
    iterations: u32,
    seed: u64,
    mean_ns: ConfidenceInterval,
    median_ns: ConfidenceInterval,
    p75_ns: ConfidenceInterval,
    p95_ns: ConfidenceInterval,
    p99_ns: ConfidenceInterval,
};

pub const SampleStats = struct {
    min_ns: u64,
    max_ns: u64,
    mean_ns: f64,
    median_ns: u64,
    p75_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    total_ns: u64,
    confidence_intervals: ?BootstrapConfidenceIntervals = null,
};

pub const Exhaustion = error{
    SampleCapacityExceeded,
    BootstrapIterationCapacityExceeded,
    StatisticsStorageInUse,
};

pub const InputError = error{
    EmptySampleSet,
    InvalidBootstrapConfidence,
};

pub const ComputeError = Exhaustion || InputError;

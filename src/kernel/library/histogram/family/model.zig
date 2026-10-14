const gpu_abi = @import("gpu_abi");
const binning = @import("binning.zig");

const DType = gpu_abi.DType;

pub const HistogramBinningPolicy = binning.Policy;

pub const HistogramVariant = enum {
    direct,
    shared_bins,
};

pub const Histogram = struct {
    bins: u64,
    count: u64,
    lo: f32 = 0,
    width: f32 = 1,
    dtype: DType = .f32,
    binning: HistogramBinningPolicy = .lower_inclusive_upper_exclusive,
    variant: HistogramVariant = .direct,
    threads: u32 = 256,
    bin_axis: []const u8 = "b",
    element_axis: []const u8 = "n",
};

pub const histogram_family_version: u32 = 2;
pub const histogram_shared_bins_cap: u64 = 4096;
pub const histogram_binning_policy_parameter = binning.policy_parameter_name;

pub fn histogramDTypeSupported(dtype: DType) bool {
    return dtype == .f32;
}

pub fn histogramInstanceValid(instance: Histogram) bool {
    if (!histogramDTypeSupported(instance.dtype)) return false;
    if (instance.bins == 0 or instance.count == 0) return false;
    if (!(instance.width > 0)) return false;
    if (instance.variant == .shared_bins and instance.bins > histogram_shared_bins_cap) {
        return false;
    }
    return instance.threads != 0;
}

pub fn histogramBinningPolicyCode(policy: HistogramBinningPolicy) u64 {
    return binning.code(policy);
}

pub fn histogramBinningPolicyFromCode(value: u64) ?HistogramBinningPolicy {
    return binning.fromCode(value);
}

pub fn histogramBinForValue(instance: Histogram, value: f32) ?usize {
    return switch (instance.binning) {
        .lower_inclusive_upper_exclusive => {
            const relative = (value - instance.lo) / instance.width;
            const bins_float: f32 = @floatFromInt(instance.bins);
            if (!(relative >= 0) or !(relative < bins_float)) return null;
            return @intFromFloat(relative);
        },
    };
}

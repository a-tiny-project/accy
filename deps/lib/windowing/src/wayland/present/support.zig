const buffer = @import("buffer.zig");
const windowing = @import("../../root.zig");

pub fn swapchainPresentError(failure: buffer.SwapchainError) windowing.PresentError {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.DimensionsTooLarge => error.UnsupportedFormat,
        error.CreateFailed => error.Unexpected,
        error.RetiredCapacityExceeded => error.CapacityExceeded,
    };
}

pub fn admitFrame(byte_count: usize, capacity: usize, rejection_count: *u64) bool {
    if (byte_count <= capacity) return true;
    rejection_count.* +|= 1;
    return false;
}

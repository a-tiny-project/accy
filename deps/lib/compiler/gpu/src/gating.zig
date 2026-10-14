//! Skip policy for tests that need a live device. A device test runs only
//! when its build flag is on, and it skips with a named reason when the host
//! lacks the platform, the driver, or the device.

const std = @import("std");
const build_options = @import("build_options");
const sys = @import("sys");

pub const Device = enum(u8) {
    cuda,
    vulkan,
    metal,

    /// Build option that enables this device's live tests.
    pub fn flag(self: Device) []const u8 {
        return switch (self) {
            .cuda => "-Dgpu-tests=true",
            .vulkan => "-Dvulkan-tests=true",
            .metal => "-Dmetal-tests=true",
        };
    }
};

pub const SkipReason = enum(u8) {
    build_flag_disabled,
    unsupported_platform,
    cuda_driver_missing,
    cuda_device_missing,
    cuda_runtime_unavailable,
    vulkan_loader_missing,
    vulkan_device_missing,
    vulkan_timeline_missing,
    metal_runtime_missing,
    metal_device_missing,
    backend_not_implemented,

    pub fn label(self: SkipReason) []const u8 {
        return switch (self) {
            .build_flag_disabled => "build flag disabled",
            .unsupported_platform => "unsupported platform",
            .cuda_driver_missing => "CUDA driver missing",
            .cuda_device_missing => "CUDA device missing",
            .cuda_runtime_unavailable => "CUDA runtime unavailable",
            .vulkan_loader_missing => "Vulkan loader missing",
            .vulkan_device_missing => "Vulkan device missing",
            .vulkan_timeline_missing => "Vulkan timeline semaphore support missing",
            .metal_runtime_missing => "Metal runtime missing",
            .metal_device_missing => "Metal device missing",
            .backend_not_implemented => "backend not implemented yet",
        };
    }
};

pub fn enabledByBuildOptions(device: Device) bool {
    return switch (device) {
        .cuda => build_options.gpu_tests,
        .vulkan => build_options.vulkan_tests,
        .metal => build_options.metal_tests,
    };
}

pub fn appleMetalPlatform() bool {
    return sys.capabilities.current.supportsAppleMetal();
}

pub fn skip(device: Device, reason: SkipReason) error{SkipZigTest} {
    std.log.scoped(.gpu_device_test).info(
        "skipping {s} device test ({s}); enable with {s}",
        .{ @tagName(device), reason.label(), device.flag() },
    );
    return error.SkipZigTest;
}

pub fn skipIfBuildFlagDisabled(device: Device) error{SkipZigTest}!void {
    if (!enabledByBuildOptions(device)) return skip(device, .build_flag_disabled);
}

pub fn skipIfNotAppleMetalHost(device: Device) error{SkipZigTest}!void {
    if (!appleMetalPlatform()) return skip(device, .unsupported_platform);
}

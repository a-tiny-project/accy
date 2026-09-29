//! The Vulkan readback witness. It runs `gpu.readback.run` on device 0 of the Vulkan loader the
//! process opens: a kernel writes a known word into every word of a buffer that holds the
//! pattern's complement, the device is synchronized, and `readBuffer` must return the pattern
//! byte for byte.
//!
//! The build's C library decides which drivers the loader reaches, as for the raster witness:
//! `-Dtarget=native-linux-gnu` reads the system driver manifests, and the default build reaches
//! the pinned Mesa's lavapipe or RADV through `VK_DRIVER_FILES`.

const std = @import("std");
const gpu = @import("gpu");
const pretty = @import("pretty");

/// Workgroups of the pattern kernel: 256 KiB of words, more than one page on every driver.
const groups: u32 = 1024;

pub fn main(init: std.process.Init) !void {
    var state = try gpu.vulkan.State.initDevice(init.gpa, 0);
    defer state.deinit();
    const handle = state.handle();
    const device = (try handle.queryCapabilities()).identity.name;

    const bytes = gpu.readback.byteCount(groups);
    const arena = init.arena.allocator();
    const storage: gpu.readback.Storage = .{
        .expected = try arena.alloc(u8, bytes),
        .readback = try arena.alloc(u8, bytes),
    };
    const comparison = try gpu.readback.run(handle, groups, storage);
    if (comparison.first) |first| {
        pretty.diagnostic.writeStderrText(
            "readback witness: {d} of {d} bytes differ on {s}, first at byte {d}: expected 0x{x:0>2}, read 0x{x:0>2}\n",
            .{ comparison.differing, comparison.bytes, device, first.offset, first.expected, first.actual },
        );
        return error.ReadbackMismatch;
    }
    pretty.diagnostic.writeStdoutText("readback witness: {d} bytes match on {s}\n", .{ comparison.bytes, device });
}

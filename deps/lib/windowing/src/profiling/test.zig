const std = @import("std");
const bench = @import("bench");
const sys = @import("sys");
const native_wayland = @import("wayland");
const windowing = @import("windowing");

const frame_width: u32 = 192;
const frame_height: u32 = 128;
const frames_per_sample = 128;
const clipboard_source_bytes: usize = 64 * 1024;
const clipboard_replacements_per_sample: usize = 32;

var clipboard_source_workload: ?*windowing.clipboard.Source = null;
var clipboard_payload: [clipboard_source_bytes]u8 = undefined;

fn benchmarkAllocator() std.mem.Allocator {
    return sys.allocator.benchmarkAllocator();
}

fn benchMinTimeNs(allocator: std.mem.Allocator, default: u64) !u64 {
    const value = try sys.env.getOwned(allocator, "BENCH_MIN_TIME_NS");
    defer if (value) |text| allocator.free(text);
    return if (value) |text| try std.fmt.parseUnsigned(u64, text, 10) else default;
}

const present_width: u32 = 3840;
const present_height: u32 = 2160;
const present_bytes: usize = @as(usize, present_width) * present_height * 4;
const present_slot_count: usize = (windowing.presentation.Limits{}).active_buffer_count;
const damage_large: windowing.PresentRegion = .{ .x = 1024, .y = 768, .width = 512, .height = 512 };
const damage_small: windowing.PresentRegion = .{ .x = 1888, .y = 1048, .width = 64, .height = 64 };
const damage_corners = [_]windowing.PresentRegion{
    .{ .x = 0, .y = 0, .width = 64, .height = 64 },
    .{ .x = present_width - 64, .y = present_height - 64, .width = 64, .height = 64 },
};

const present_full_name = "windowing present full 3840x2160";
const present_large_name = "windowing present damage 512x512";
const present_small_name = "windowing present damage 64x64";
const present_corners_name = "windowing present damage 2x64x64";

var present_source: []const u8 = &.{};
var present_slots: []native_wayland.shm.Buffer = &.{};
var present_cursor: usize = 0;

/// The three constants give the per-core first and second level cache sizes and
/// the shared third level cache size of the machine the benchmark was recorded
/// on. That machine is an AMD 7800X3D, which reports 256 KiB of first level
/// data cache and 8 MiB of second level cache over its eight cores, and one 96
/// MiB third level cache. `rungFor` compares a row's working set against these
/// sizes to pick its rung. The throughput each rung stands for lives in
/// lib/bench/src/floor/rung.zig.
const l1_capacity: usize = 32 * 1024;
const l2_capacity: usize = 1024 * 1024;
const l3_capacity: usize = 96 * 1024 * 1024;

fn rungFor(working_set_bytes: usize) bench.floor.Rung {
    if (working_set_bytes <= l1_capacity) return .l1;
    if (working_set_bytes <= l2_capacity) return .l2;
    if (working_set_bytes <= l3_capacity) return .l3;
    return .dram;
}

/// A row names one present benchmark, the scope its measurement is filed under,
/// and the bytes its damage covers, so each present benchmark turns its damage
/// into the byte counts the floor needs. A present reads its damaged bytes from
/// the caller's frame once and writes them into a buffer once, so the streamed
/// bytes are twice the damaged bytes. The benchmark writes into its buffers in
/// turn, so the working set is the damaged bytes of the source plus the same
/// count in each of the `present_slot_count` buffers.
const PresentRow = struct {
    name: []const u8,
    scope: []const u8,
    damaged_bytes: usize,

    fn streamedBytes(self: PresentRow) usize {
        return 2 * self.damaged_bytes;
    }

    fn workingSetBytes(self: PresentRow) usize {
        return (present_slot_count + 1) * self.damaged_bytes;
    }
};

const present_rows = [_]PresentRow{
    .{
        .name = present_full_name,
        .scope = "windowing.presentation.wayland.write.full",
        .damaged_bytes = present_bytes,
    },
    .{
        .name = present_large_name,
        .scope = "windowing.presentation.wayland.write.damage_512",
        .damaged_bytes = damage_large.pixelCount() * 4,
    },
    .{
        .name = present_small_name,
        .scope = "windowing.presentation.wayland.write.damage_64",
        .damaged_bytes = damage_small.pixelCount() * 4,
    },
    .{
        .name = present_corners_name,
        .scope = "windowing.presentation.wayland.write.damage_2x64",
        .damaged_bytes = damagedByteCount(&damage_corners),
    },
};

fn damagedByteCount(regions: []const windowing.PresentRegion) usize {
    var total: usize = 0;
    for (regions) |region| total += region.pixelCount() * 4;
    return total;
}

/// Picks the buffer each present sample writes. The call hands back the next of
/// the benchmark's buffers in turn and moves the cursor on, wrapping after the
/// last. Taking the buffers in turn spreads a run of samples over every buffer,
/// so the bytes the run touches match the working set its row assumes. The call
/// stops the process with a panic when the benchmark holds no buffers.
fn nextPresentSlot() *native_wayland.shm.Buffer {
    if (present_slots.len == 0) {
        @panic("windowing presentation benchmark shared memory slots unavailable");
    }
    const slot = &present_slots[present_cursor];
    present_cursor = (present_cursor + 1) % present_slots.len;
    return slot;
}

fn acquirePresentSlots(
    allocator: std.mem.Allocator,
) ![]native_wayland.shm.Buffer {
    const slots = try allocator.alloc(native_wayland.shm.Buffer, present_slot_count);
    for (slots, 0..) |*slot, index| {
        const mapping = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            present_bytes,
        );
        @memset(mapping, 0);
        slot.* = .{
            .object_id = @intCast(index + 1),
            .mapping = mapping,
            .byte_len = present_bytes,
            .width = present_width,
            .height = present_height,
            .stride = present_width * 4,
            .format = .xrgb8888,
        };
    }
    return slots;
}

fn releasePresentSlots(
    allocator: std.mem.Allocator,
    slots: []native_wayland.shm.Buffer,
) void {
    for (slots) |slot| allocator.free(slot.mapping);
    allocator.free(slots);
}

fn shmRegion(region: windowing.PresentRegion) native_wayland.shm.Region {
    return .{
        .x = region.x,
        .y = region.y,
        .width = region.width,
        .height = region.height,
    };
}

fn writeFullFrame(_: std.mem.Allocator) void {
    const target = nextPresentSlot();
    const phase = bench.phaseAt("windowing.presentation.wayland.write.full", @src());
    defer phase.end();
    target.writeRgba8(present_source, target.fullRegion()) catch
        @panic("windowing presentation benchmark full frame write failed");
    bench.coz.progressNamed("windowing.presentation.wayland.write.full.complete");
}

fn writeLargeDamage(_: std.mem.Allocator) void {
    const target = nextPresentSlot();
    const phase = bench.phaseAt("windowing.presentation.wayland.write.damage_512", @src());
    defer phase.end();
    target.writeRgba8(present_source, shmRegion(damage_large)) catch
        @panic("windowing presentation benchmark 512x512 damage write failed");
    bench.coz.progressNamed("windowing.presentation.wayland.write.damage_512.complete");
}

fn writeSmallDamage(_: std.mem.Allocator) void {
    const target = nextPresentSlot();
    const phase = bench.phaseAt("windowing.presentation.wayland.write.damage_64", @src());
    defer phase.end();
    target.writeRgba8(present_source, shmRegion(damage_small)) catch
        @panic("windowing presentation benchmark 64x64 damage write failed");
    bench.coz.progressNamed("windowing.presentation.wayland.write.damage_64.complete");
}

/// Writes two 64 by 64 rectangles at opposite corners of a 3840 by 2160 frame
/// into one buffer, one `writeRgba8` call per rectangle. The sample measures
/// the cost of a present whose damage is two small rectangles far apart, the
/// case a blinking caret and a ticking clock produce. Those are the calls
/// `Acquired.write` makes for an accumulator listing the two rectangles, so the
/// sample times the walk over the list and leaves the accumulator out of the
/// measurement. The benchmark makes those calls itself because the `windowing`
/// package keeps its Wayland presenter out of its public namespace, leaving
/// `Acquired.write` out of reach.
fn writeCornerDamage(_: std.mem.Allocator) void {
    const target = nextPresentSlot();
    const phase = bench.phaseAt("windowing.presentation.wayland.write.damage_2x64", @src());
    defer phase.end();
    for (damage_corners) |region| {
        target.writeRgba8(present_source, shmRegion(region)) catch
            @panic("windowing presentation benchmark two corner damage write failed");
    }
    bench.coz.progressNamed("windowing.presentation.wayland.write.damage_2x64.complete");
}

fn writePresentGates(results: []const bench.Result) !void {
    for (results) |result| {
        for (present_rows) |row| {
            if (!std.mem.eql(u8, result.name, row.name)) continue;
            const floor_ns = try (bench.floor.Bytes{
                .count = row.streamedBytes(),
                .throughput = .{ .measured = .{
                    .rung = rungFor(row.workingSetBytes()),
                    .pattern = .streaming,
                } },
            }).nanoseconds(null);
            std.debug.assert(floor_ns > 0);
            const gate = bench.floor.Gate{
                .scope = row.scope,
                .floor_ns = floor_ns,
                .measured_ns = result.median_ns,
            };
            bench.pretty.diagnostic.writeStdoutText("{f}", .{gate});
        }
    }
}

fn presentRegionOscillation(sample_allocator: std.mem.Allocator) void {
    const phase = bench.phaseAt("windowing.presentation.x11.region_oscillation", @src());
    defer phase.end();

    var window = windowing.Window.create(sample_allocator, .{
        .title = "windowing-presentation-bench",
        .width = frame_width,
        .height = frame_height,
        .visible = true,
        .backend = .x11,
    }) catch |err| std.debug.panic("windowing presentation benchmark window creation failed: {s}", .{@errorName(err)});
    defer window.destroy();

    const frame = sample_allocator.alloc(u8, frame_width * frame_height * 4) catch
        @panic("windowing presentation benchmark frame allocation failed");
    defer sample_allocator.free(frame);
    for (frame, 0..) |*byte, index| byte.* = @truncate(index *% 17);

    const large = windowing.PresentRegion{ .x = 4, .y = 6, .width = 160, .height = 96 };
    const small = windowing.PresentRegion{ .x = 31, .y = 19, .width = 48, .height = 32 };
    var iteration: usize = 0;
    while (iteration < frames_per_sample) : (iteration += 1) {
        const region = if (iteration % 2 == 0) large else small;
        window.presentRgba8Region(frame, frame_width, frame_height, region) catch
            @panic("windowing presentation benchmark frame failed");
    }
    synchronizeX11(&window);
    bench.coz.progressNamed("windowing.presentation.x11.region_oscillation.complete");
}

fn synchronizeX11(window: *windowing.Window) void {
    const native = window.getNativeSurface();
    const connection = native.x11.connection;
    const request = connection.beginRequest();
    sys.x11.protocol.getImage(request, .{
        .drawable = native.x11.window,
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    }) catch @panic("windowing presentation benchmark synchronization request failed");
    connection.sendRequest() catch @panic("windowing presentation benchmark synchronization send failed");
    _ = connection.waitReply() catch @panic("windowing presentation benchmark synchronization reply failed");
}

fn replaceClipboardSource(_: std.mem.Allocator) void {
    const source = clipboard_source_workload orelse
        @panic("windowing clipboard source benchmark workload unavailable");
    const phase = bench.phaseAt("windowing.clipboard.source.replace", @src());
    defer phase.end();
    for (0..clipboard_replacements_per_sample) |iteration| {
        clipboard_payload[0] = @truncate(iteration);
        source.replace(&clipboard_payload) catch
            @panic("windowing clipboard source benchmark replacement failed");
    }
    std.mem.doNotOptimizeAway(source.text());
    bench.coz.progressNamed("windowing.clipboard.source.replace.complete");
}

test "bench: windowing bounded owners" {
    const present_allocator = benchmarkAllocator();
    const pixels = try present_allocator.alloc(u8, present_bytes);
    defer present_allocator.free(pixels);
    for (pixels, 0..) |*byte, index| byte.* = @truncate(index *% 23 +% 5);
    present_source = pixels;
    defer present_source = &.{};
    const slots = try acquirePresentSlots(present_allocator);
    defer releasePresentSlots(present_allocator, slots);
    present_slots = slots;
    defer present_slots = &.{};

    const clipboard_capacity = try windowing.clipboard.Capacity.derive(.{
        .published_text_byte_count = clipboard_source_bytes,
    });
    var source = try windowing.clipboard.Source.init(
        benchmarkAllocator(),
        clipboard_capacity,
    );
    defer source.deinit();
    clipboard_source_workload = &source;
    defer clipboard_source_workload = null;
    for (&clipboard_payload, 0..) |*byte, index| byte.* = @truncate(index *% 31);

    const allocator = benchmarkAllocator();
    const filter = try sys.env.getOwned(allocator, "BENCH_FILTER");
    defer if (filter) |value| allocator.free(value);

    var suite = bench.Suite.init(allocator, .{
        .min_time_ns = try benchMinTimeNs(allocator, 5_000_000),
        .min_iterations = 5,
        .max_iterations = 20,
        .warmup_iterations = 1,
        .allocation_attribution = .sample_call,
    });
    defer suite.deinit();
    suite.setFilter(filter);

    try suite.add(
        "windowing clipboard source replace 64KiB x32",
        replaceClipboardSource,
        .{ .max_median_ns = 500_000, .max_allocations = 0, .max_frees = 0 },
    );
    if (comptime sys.capabilities.current.os == .linux) {
        if (sys.env.get("DISPLAY") != null) {
            try suite.add("windowing X11 present 128 alternating regions", presentRegionOscillation, .{});
        }
    }
    try suite.add(present_full_name, writeFullFrame, .{ .max_allocations = 0, .max_frees = 0 });
    try suite.add(present_large_name, writeLargeDamage, .{ .max_allocations = 0, .max_frees = 0 });
    try suite.add(present_small_name, writeSmallDamage, .{ .max_allocations = 0, .max_frees = 0 });
    try suite.add(present_corners_name, writeCornerDamage, .{
        .max_allocations = 0,
        .max_frees = 0,
    });
    try suite.run();
    try writePresentGates(suite.results.items);
}

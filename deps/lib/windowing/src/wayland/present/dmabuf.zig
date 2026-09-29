//! Buffers another device renders, handed to the compositor as dma-bufs with explicit
//! synchronization. The compositor describes which formats and modifiers it can import, and from
//! which device, through dma-buf feedback (`zwp_linux_dmabuf_feedback_v1`). The caller imports each
//! of its images once as a `wl_buffer` and each image's DRM timeline syncobj once as a
//! `wp_linux_drm_syncobj_timeline_v1`. Every commit then names an acquire point the compositor
//! waits for before reading the buffer and a release point it signals once it has stopped.
//!
//! The package keeps no GPU state. The caller owns the dma-bufs and timelines. Each descriptor it
//! passes is duplicated for the compositor, and the caller keeps its own.

const builtin = @import("builtin");
const std = @import("std");
const sys = @import("sys");
const native = @import("wayland");
const windowing = @import("../../root.zig");

const core = native.protocol.core;
const desktop = native.protocol.desktop;
const runtime = native.runtime;

const linux_dmabuf = desktop.zwp_linux_dmabuf_v1;
const buffer_params = desktop.zwp_linux_buffer_params_v1;
const feedback_protocol = desktop.zwp_linux_dmabuf_feedback_v1;
const syncobj_manager = desktop.wp_linux_drm_syncobj_manager_v1;
const syncobj_surface = desktop.wp_linux_drm_syncobj_surface_v1;
const syncobj_timeline = desktop.wp_linux_drm_syncobj_timeline_v1;

/// The lowest `zwp_linux_dmabuf_v1` version with feedback, and the highest this module speaks.
pub const minimum_dmabuf_version: u32 = 4;
pub const maximum_dmabuf_version: u32 = 5;

/// Memory planes one buffer may have.
pub const max_planes: u32 = 4;
/// Buffers imported at once, enough for two rings of four.
pub const max_buffers: u32 = 8;
/// Timelines imported at once, one per buffer.
pub const max_timelines: u32 = max_buffers;
/// Tranches one feedback update may carry.
pub const max_tranches: u32 = 8;
/// Entries of the format table kept. The table's wire form spends 16 bytes on each.
pub const max_table_entries: u32 = 4096;
/// Table indices kept across all tranches of one update.
pub const max_tranche_indices: u32 = 4096;

pub const Error = error{
    /// The compositor lacks dma-buf feedback or explicit synchronization.
    Unsupported,
    /// Every buffer or timeline slot is in use.
    CapacityExceeded,
    /// A plane count, extent or descriptor the request cannot carry.
    InvalidBuffer,
    Unexpected,
};

/// One format table entry: a DRM fourcc and a modifier.
pub const FormatModifier = extern struct {
    format: u32,
    pad: u32 = 0,
    modifier: u64,
};

/// A preference group of the compositor's feedback, highest preference first.
pub const Tranche = struct {
    /// The device, as a Linux `dev_t`, whose buffers the tranche describes.
    device: u64,
    /// `scanout` (1) when the compositor can put buffers of this tranche straight on screen.
    flags: u32,
    first_index: u32,
    index_count: u32,
};

/// The compositor's latest complete dma-buf feedback for the surface.
pub const Feedback = struct {
    main_device: u64 = 0,
    table: []FormatModifier = &.{},
    table_len: u32 = 0,
    indices: []u16 = &.{},
    index_count: u32 = 0,
    tranches: [max_tranches]Tranche = undefined,
    tranche_count: u32 = 0,
    /// Updates received whole, so a caller can see when the compositor changed its mind.
    generation: u64 = 0,
    /// Whether a table entry, index or tranche was dropped because it exceeded the capacity.
    truncated: bool = false,

    pub fn trancheSlice(self: *const Feedback) []const Tranche {
        return self.tranches[0..self.tranche_count];
    }

    pub fn entries(self: *const Feedback, tranche: Tranche) []const u16 {
        return self.indices[tranche.first_index..][0..tranche.index_count];
    }

    pub fn entry(self: *const Feedback, index: u16) ?FormatModifier {
        if (index >= self.table_len) return null;
        return self.table[index];
    }

    /// The modifiers of `format` in every tranche for `device`, in preference order and without
    /// repeats. Returns how many it wrote to `out`.
    pub fn modifiers(self: *const Feedback, format: u32, device: u64, out: []u64) usize {
        var count: usize = 0;
        for (self.trancheSlice()) |tranche| {
            if (tranche.device != device) continue;
            for (self.entries(tranche)) |index| {
                const value = self.entry(index) orelse continue;
                if (value.format != format) continue;
                if (std.mem.indexOfScalar(u64, out[0..count], value.modifier) != null) continue;
                if (count == out.len) return count;
                out[count] = value.modifier;
                count += 1;
            }
        }
        return count;
    }
};

pub const Plane = struct {
    /// Borrowed. The request carries a duplicate.
    fd: sys.fd.Descriptor,
    offset: u32,
    stride: u32,
};

pub const BufferDesc = struct {
    width: u32,
    height: u32,
    /// DRM fourcc.
    format: u32,
    modifier: u64,
    planes: []const Plane,
};

/// An imported dma-buf, named by its `wl_buffer` object.
pub const Buffer = struct { id: u32 };

/// An imported DRM timeline syncobj.
pub const Timeline = struct { id: u32 };

/// The points one commit names on a timeline.
pub const SyncPoints = struct {
    timeline: Timeline,
    acquire: u64,
    release: u64,
};

/// One dma-buf frame: the buffer, its extent, the changed rectangle and its sync points.
pub const Frame = struct {
    buffer: Buffer,
    width: u32,
    height: u32,
    region: windowing.PresentRegion,
    sync: SyncPoints,
};

pub const PresentError = Error || error{
    SubmissionIdsExhausted,
    /// The compositor has not asked for a frame since the last one.
    FrameNotReady,
    /// The window is hidden, so the compositor would not show the frame.
    NotVisible,
    /// The frame's extent is not the window's framebuffer extent.
    UnsupportedFormat,
};

/// Feedback being received, which replaces `Feedback` when its `done` arrives.
const PendingFeedback = struct {
    open: bool = false,
    main_device: u64 = 0,
    table_len: ?u32 = null,
    index_count: u32 = 0,
    tranche_count: u32 = 0,
    tranche: Tranche = .{ .device = 0, .flags = 0, .first_index = 0, .index_count = 0 },
};

pub const Dmabuf = struct {
    allocator: std.mem.Allocator,
    client: *runtime.Client,
    dmabuf_id: u32,
    manager_id: u32,
    surface_id: u32,
    feedback_id: ?u32 = null,
    /// Made at the first explicit commit. Afterwards every commit of the surface needs sync points.
    sync_surface_id: ?u32 = null,
    feedback: Feedback = .{},
    pending: PendingFeedback = .{},
    pending_tranches: [max_tranches]Tranche = undefined,
    pending_table: []FormatModifier = &.{},
    pending_indices: []u16 = &.{},
    buffers: [max_buffers]?u32 = @splat(null),
    timelines: [max_timelines]?u32 = @splat(null),

    /// Asks the compositor for the surface's feedback, which arrives with the next roundtrip.
    pub fn open(
        allocator: std.mem.Allocator,
        client: *runtime.Client,
        dmabuf_id: u32,
        manager_id: u32,
        surface_id: u32,
    ) (Error || error{OutOfMemory})!Dmabuf {
        const dmabuf_object = client.object(dmabuf_id) orelse return error.Unsupported;
        if (dmabuf_object.version < minimum_dmabuf_version) return error.Unsupported;
        var self = Dmabuf{
            .allocator = allocator,
            .client = client,
            .dmabuf_id = dmabuf_id,
            .manager_id = manager_id,
            .surface_id = surface_id,
        };
        self.feedback.table = try allocator.alloc(FormatModifier, max_table_entries);
        errdefer allocator.free(self.feedback.table);
        self.feedback.indices = try allocator.alloc(u16, max_tranche_indices);
        errdefer allocator.free(self.feedback.indices);
        self.pending_table = try allocator.alloc(FormatModifier, max_table_entries);
        errdefer allocator.free(self.pending_table);
        self.pending_indices = try allocator.alloc(u16, max_tranche_indices);
        errdefer allocator.free(self.pending_indices);
        var created: [1]u32 = undefined;
        client.request(
            dmabuf_id,
            linux_dmabuf.requests.get_surface_feedback.opcode,
            &.{ .{ .new_id = .fixed }, .{ .object = surface_id } },
            &created,
        ) catch return error.Unexpected;
        self.feedback_id = created[0];
        return self;
    }

    pub fn deinit(self: *Dmabuf) void {
        for (&self.buffers) |*slot| if (slot.*) |id| {
            self.destroyObject(id, core.wl_buffer.requests.destroy.opcode);
            slot.* = null;
        };
        for (&self.timelines) |*slot| if (slot.*) |id| {
            self.destroyObject(id, syncobj_timeline.requests.destroy.opcode);
            slot.* = null;
        };
        if (self.sync_surface_id) |id| self.destroyObject(id, syncobj_surface.requests.destroy.opcode);
        if (self.feedback_id) |id| self.destroyObject(id, feedback_protocol.requests.destroy.opcode);
        self.allocator.free(self.feedback.table);
        self.allocator.free(self.feedback.indices);
        self.allocator.free(self.pending_table);
        self.allocator.free(self.pending_indices);
        self.* = undefined;
    }

    /// The `zwp_linux_dmabuf_v1` version bound, 4 or later.
    pub fn version(self: *const Dmabuf) u32 {
        const object = self.client.object(self.dmabuf_id) orelse return 0;
        return object.version;
    }

    /// The latest complete feedback, or null before the first one arrives.
    pub fn currentFeedback(self: *const Dmabuf) ?*const Feedback {
        if (self.feedback.generation == 0) return null;
        return &self.feedback;
    }

    /// Imports a dma-buf as a `wl_buffer`. The compositor refuses a buffer it cannot import with a
    /// protocol error, so a caller picks the format and modifier from the feedback.
    pub fn importBuffer(self: *Dmabuf, desc: BufferDesc) Error!Buffer {
        if (desc.planes.len == 0 or desc.planes.len > max_planes) return error.InvalidBuffer;
        if (desc.width == 0 or desc.height == 0) return error.InvalidBuffer;
        if (desc.width > std.math.maxInt(i32) or desc.height > std.math.maxInt(i32)) return error.InvalidBuffer;
        const slot = freeSlot(&self.buffers) orelse return error.CapacityExceeded;
        var params: [1]u32 = undefined;
        self.client.request(self.dmabuf_id, linux_dmabuf.requests.create_params.opcode, &.{.{ .new_id = .fixed }}, &params) catch
            return error.Unexpected;
        defer self.destroyObject(params[0], buffer_params.requests.destroy.opcode);
        const modifier_hi: u32 = @truncate(desc.modifier >> 32);
        const modifier_lo: u32 = @truncate(desc.modifier);
        for (desc.planes, 0..) |plane, index| {
            const duplicate = sys.fd.duplicate(plane.fd) catch return error.InvalidBuffer;
            self.client.request(params[0], buffer_params.requests.add.opcode, &.{
                .{ .descriptor_owned = duplicate },
                .{ .uint = @intCast(index) },
                .{ .uint = plane.offset },
                .{ .uint = plane.stride },
                .{ .uint = modifier_hi },
                .{ .uint = modifier_lo },
            }, &.{}) catch {
                sys.fd.close(duplicate);
                return error.Unexpected;
            };
        }
        var created: [1]u32 = undefined;
        self.client.request(params[0], buffer_params.requests.create_immed.opcode, &.{
            .{ .new_id = .fixed },
            .{ .int = @intCast(desc.width) },
            .{ .int = @intCast(desc.height) },
            .{ .uint = desc.format },
            .{ .uint = 0 },
        }, &created) catch return error.Unexpected;
        slot.* = created[0];
        return .{ .id = created[0] };
    }

    pub fn releaseBuffer(self: *Dmabuf, buffer: Buffer) void {
        const slot = findSlot(&self.buffers, buffer.id) orelse return;
        self.destroyObject(buffer.id, core.wl_buffer.requests.destroy.opcode);
        slot.* = null;
    }

    /// Imports a DRM timeline syncobj from its descriptor.
    pub fn importTimeline(self: *Dmabuf, fd: sys.fd.Descriptor) Error!Timeline {
        const slot = freeSlot(&self.timelines) orelse return error.CapacityExceeded;
        const duplicate = sys.fd.duplicate(fd) catch return error.InvalidBuffer;
        var created: [1]u32 = undefined;
        self.client.request(self.manager_id, syncobj_manager.requests.import_timeline.opcode, &.{
            .{ .new_id = .fixed },
            .{ .descriptor_owned = duplicate },
        }, &created) catch {
            sys.fd.close(duplicate);
            return error.Unexpected;
        };
        slot.* = created[0];
        return .{ .id = created[0] };
    }

    pub fn destroyTimeline(self: *Dmabuf, timeline: Timeline) void {
        const slot = findSlot(&self.timelines, timeline.id) orelse return;
        self.destroyObject(timeline.id, syncobj_timeline.requests.destroy.opcode);
        slot.* = null;
    }

    pub fn ownsBuffer(self: *const Dmabuf, buffer: Buffer) bool {
        return std.mem.indexOfScalar(?u32, &self.buffers, buffer.id) != null;
    }

    pub fn ownsTimeline(self: *const Dmabuf, timeline: Timeline) bool {
        return std.mem.indexOfScalar(?u32, &self.timelines, timeline.id) != null;
    }

    /// Sends the sync points of the next commit, making the surface's syncobj object first.
    pub fn setSyncPoints(self: *Dmabuf, sync: SyncPoints) Error!void {
        if (sync.acquire >= sync.release) return error.InvalidBuffer;
        if (!self.ownsTimeline(sync.timeline)) return error.InvalidBuffer;
        const surface = self.sync_surface_id orelse blk: {
            var created: [1]u32 = undefined;
            self.client.request(self.manager_id, syncobj_manager.requests.get_surface.opcode, &.{
                .{ .new_id = .fixed },
                .{ .object = self.surface_id },
            }, &created) catch return error.Unexpected;
            self.sync_surface_id = created[0];
            break :blk created[0];
        };
        inline for (.{
            .{ syncobj_surface.requests.set_acquire_point.opcode, sync.acquire },
            .{ syncobj_surface.requests.set_release_point.opcode, sync.release },
        }) |point| {
            self.client.request(surface, point[0], &.{
                .{ .object = sync.timeline.id },
                .{ .uint = @truncate(point[1] >> 32) },
                .{ .uint = @truncate(point[1]) },
            }, &.{}) catch return error.Unexpected;
        }
    }

    /// Handles feedback events and the events of imported buffers. The compositor's
    /// `wl_buffer.release` means nothing under explicit synchronization and is dropped.
    pub fn dispatch(self: *Dmabuf, event: *runtime.RoutedView) !bool {
        if (self.feedback_id == event.object_id) {
            try self.dispatchFeedback(event);
            return true;
        }
        return std.mem.indexOfScalar(?u32, &self.buffers, event.object_id) != null;
    }

    fn dispatchFeedback(self: *Dmabuf, event: *runtime.RoutedView) !void {
        const events = feedback_protocol.events;
        const pending = &self.pending;
        if (!pending.open) {
            pending.* = .{ .open = true, .main_device = self.feedback.main_device };
        }
        var decoder = try event.borrowedDecoder();
        switch (event.metadata.opcode) {
            events.format_table.opcode => {
                _ = try decoder.descriptor();
                const size = try decoder.unsigned();
                try decoder.finish();
                const fd = try event.takeDescriptor(0);
                defer sys.fd.close(fd);
                pending.table_len = try self.readTable(fd, size);
            },
            events.main_device.opcode => {
                pending.main_device = try deviceNumber(try decoder.array());
                try decoder.finish();
            },
            events.tranche_target_device.opcode => {
                pending.tranche.device = try deviceNumber(try decoder.array());
                try decoder.finish();
            },
            events.tranche_flags.opcode => {
                pending.tranche.flags = try decoder.unsigned();
                try decoder.finish();
            },
            events.tranche_formats.opcode => {
                const bytes = try decoder.array();
                try decoder.finish();
                if (bytes.len % 2 != 0) return error.InvalidEvent;
                var offset: usize = 0;
                while (offset < bytes.len) : (offset += 2) {
                    if (pending.index_count == max_tranche_indices) {
                        self.feedback.truncated = true;
                        break;
                    }
                    self.pending_indices[pending.index_count] = std.mem.readInt(u16, bytes[offset..][0..2], native_endian);
                    pending.index_count += 1;
                    pending.tranche.index_count += 1;
                }
            },
            events.tranche_done.opcode => {
                try decoder.finish();
                if (pending.tranche_count == max_tranches) {
                    self.feedback.truncated = true;
                } else {
                    self.pending_tranches[pending.tranche_count] = pending.tranche;
                    pending.tranche_count += 1;
                }
                pending.tranche = .{ .device = 0, .flags = 0, .first_index = pending.index_count, .index_count = 0 };
            },
            events.done.opcode => {
                try decoder.finish();
                self.commitFeedback();
            },
            else => return error.InvalidEvent,
        }
    }

    fn commitFeedback(self: *Dmabuf) void {
        const pending = &self.pending;
        const feedback = &self.feedback;
        if (pending.table_len) |len| {
            @memcpy(feedback.table[0..len], self.pending_table[0..len]);
            feedback.table_len = len;
        }
        feedback.main_device = pending.main_device;
        @memcpy(feedback.indices[0..pending.index_count], self.pending_indices[0..pending.index_count]);
        feedback.index_count = pending.index_count;
        @memcpy(feedback.tranches[0..pending.tranche_count], self.pending_tranches[0..pending.tranche_count]);
        feedback.tranche_count = pending.tranche_count;
        feedback.generation += 1;
        pending.* = .{};
    }

    /// Copies the format table the compositor shares through `fd` into pending storage.
    fn readTable(self: *Dmabuf, fd: sys.fd.Descriptor, size: u32) !u32 {
        if (size == 0 or size % @sizeOf(FormatModifier) != 0) return error.InvalidEvent;
        const mapping = sys.memory.mapPrivateFile(fd, size, .{ .read = true }, 0) catch return error.InvalidEvent;
        defer sys.memory.unmap(mapping);
        const available: u32 = size / @sizeOf(FormatModifier);
        const kept = @min(available, max_table_entries);
        if (kept < available) self.feedback.truncated = true;
        @memcpy(std.mem.sliceAsBytes(self.pending_table[0..kept]), mapping[0 .. kept * @sizeOf(FormatModifier)]);
        return kept;
    }

    fn destroyObject(self: *Dmabuf, id: u32, opcode: u16) void {
        self.client.request(id, opcode, &.{}, &.{}) catch {};
    }
};

const native_endian = builtin.cpu.arch.endian();

/// A `dev_t` the compositor sends as an array in native byte order.
fn deviceNumber(bytes: []const u8) !u64 {
    if (bytes.len != @sizeOf(u64)) return error.InvalidEvent;
    return std.mem.readInt(u64, bytes[0..8], native_endian);
}

fn freeSlot(slots: []?u32) ?*?u32 {
    for (slots) |*slot| if (slot.* == null) return slot;
    return null;
}

fn findSlot(slots: []?u32, id: u32) ?*?u32 {
    for (slots) |*slot| if (slot.* == id) return slot;
    return null;
}

test "feedback lists a format's modifiers for a device in tranche order without repeats" {
    var table = [_]FormatModifier{
        .{ .format = 0x34324258, .modifier = 0 },
        .{ .format = 0x34324258, .modifier = 0x0200000000401b03 },
        .{ .format = 0x34325258, .modifier = 0 },
    };
    var indices = [_]u16{ 1, 0, 2, 0, 9 };
    var feedback = Feedback{ .table = &table, .table_len = table.len, .indices = &indices, .index_count = indices.len, .generation = 1 };
    feedback.tranches[0] = .{ .device = 0xE280, .flags = 1, .first_index = 0, .index_count = 3 };
    feedback.tranches[1] = .{ .device = 0xE280, .flags = 0, .first_index = 3, .index_count = 2 };
    feedback.tranche_count = 2;
    var out: [4]u64 = undefined;
    const count = feedback.modifiers(0x34324258, 0xE280, &out);
    try std.testing.expectEqualSlices(u64, &.{ 0x0200000000401b03, 0 }, out[0..count]);
    try std.testing.expectEqual(@as(usize, 0), feedback.modifiers(0x34324258, 0xE281, &out));
    try std.testing.expectEqual(@as(?FormatModifier, null), feedback.entry(9));
}

test "a device number decodes from the native-order array" {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, 0xE280, native_endian);
    try std.testing.expectEqual(@as(u64, 0xE280), try deviceNumber(&encoded));
    try std.testing.expectError(error.InvalidEvent, deviceNumber(&.{ 0x80, 0xE2 }));
}

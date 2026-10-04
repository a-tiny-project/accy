const std = @import("std");
const payload = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const Payload = struct {
    allocator: Allocator,
    debug_records: std.ArrayListUnmanaged(payload.DebugRecord) = .empty,
    buffers: std.ArrayListUnmanaged(payload.ArtifactBuffer) = .empty,
    text_dumps: std.ArrayListUnmanaged(payload.TextDump) = .empty,

    pub fn init(allocator: Allocator) Payload {
        return .{ .allocator = allocator };
    }

    pub fn addDebugRecord(self: *Payload, record: payload.DebugRecord) Allocator.Error!void {
        try self.debug_records.ensureTotalCapacity(self.allocator, self.debug_records.items.len + 1);
        const owned = try record.dupe(self.allocator);
        self.debug_records.appendAssumeCapacity(owned);
    }

    pub fn addBuffer(self: *Payload, buffer: payload.ArtifactBuffer) Allocator.Error!void {
        try self.buffers.ensureTotalCapacity(self.allocator, self.buffers.items.len + 1);
        const owned = try buffer.dupe(self.allocator);
        self.buffers.appendAssumeCapacity(owned);
    }

    pub fn addTextDump(self: *Payload, dump: payload.TextDump) Allocator.Error!void {
        try self.text_dumps.ensureTotalCapacity(self.allocator, self.text_dumps.items.len + 1);
        const owned = try dump.dupe(self.allocator);
        self.text_dumps.appendAssumeCapacity(owned);
    }

    pub fn cloneInto(self: Payload, target: *Payload) Allocator.Error!void {
        for (self.debug_records.items) |record| try target.addDebugRecord(record);
        for (self.buffers.items) |buffer| try target.addBuffer(buffer);
        for (self.text_dumps.items) |dump| try target.addTextDump(dump);
    }

    pub fn deinit(self: *Payload) void {
        for (self.debug_records.items) |record| record.deinit(self.allocator);
        self.debug_records.deinit(self.allocator);
        for (self.buffers.items) |buffer| buffer.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        for (self.text_dumps.items) |dump| dump.deinit(self.allocator);
        self.text_dumps.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn eql(self: Payload, other: Payload) bool {
        if (self.debug_records.items.len != other.debug_records.items.len or
            self.buffers.items.len != other.buffers.items.len or
            self.text_dumps.items.len != other.text_dumps.items.len)
        {
            return false;
        }
        for (self.debug_records.items, other.debug_records.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        for (self.buffers.items, other.buffers.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        for (self.text_dumps.items, other.text_dumps.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

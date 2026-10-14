const std = @import("std");
const product = @import("../../../product/root.zig");
const serialization = @import("root.zig");
const format = serialization.format;

/// Distinct compiler manifests in order of first use. A record names one by
/// index, so a stream carries each manifest once and mirrors the interning the
/// import store performs, instead of repeating those bytes per record.
pub const Manifests = struct {
    values: [format.max_compiler_manifests][]const u8 = undefined,
    count: usize = 0,

    pub fn intern(self: *Manifests, bytes: []const u8) format.WriteError!usize {
        std.debug.assert(self.count <= self.values.len);
        for (self.values[0..self.count], 0..) |value, index| {
            if (std.mem.eql(u8, value, bytes)) return index;
        }
        if (self.count == self.values.len) return error.LimitExceeded;
        self.values[self.count] = bytes;
        self.count += 1;
        return self.count - 1;
    }

    pub fn at(self: *const Manifests, index: usize) serialization.DeserializeError![]const u8 {
        if (index >= self.count) return error.InvalidProductRecord;
        return self.values[index];
    }
};

pub fn writeManifests(
    writer: *format.Writer,
    manifests: *const Manifests,
) serialization.SerializeError!void {
    try writer.writeCount(manifests.count);
    for (manifests.values[0..manifests.count]) |bytes| try writer.writeBlob(bytes);
}

pub fn readManifests(reader: *format.Reader) serialization.DeserializeError!Manifests {
    var manifests = Manifests{};
    const count = try reader.readCount();
    if (count > format.max_compiler_manifests) return error.LimitExceeded;
    for (0..count) |index| manifests.values[index] = try reader.readBlob();
    manifests.count = count;
    return manifests;
}

pub fn createStore(
    allocator: std.mem.Allocator,
    fragments: usize,
) serialization.DeserializeError!*product.revision.Store {
    if (fragments > format.max_collection_entries) return error.LimitExceeded;
    const owner = product.revision.Store.create(allocator, .{
        .revisions = @intCast(@max(fragments, 1)),
        .kinds = 1,
        .builders = 1,
        .compiler_manifests = format.max_compiler_manifests,
        .record_bytes = format.max_blob_bytes,
        .gate_scratch_bytes = 0,
        .candidate_count = 1,
        .screening_bytes = 0,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProductRecordCapacityExceeded,
    };
    owner.freeze();
    return owner;
}

pub fn writeAddress(
    writer: *format.Writer,
    address: product.ProductRef,
) serialization.SerializeError!void {
    inline for (@typeInfo(product.ProductRef).@"struct".field_names) |field| {
        try writer.writeString(@field(address, field));
    }
}

pub fn readAddress(reader: *format.Reader) serialization.DeserializeError!product.ProductRef {
    var address: product.ProductRef = undefined;
    inline for (@typeInfo(product.ProductRef).@"struct".field_names) |field| {
        @field(address, field) = try reader.readString();
    }
    return address;
}

/// The result borrows metadata from the store. Deserialization cannot recreate
/// a sealed revision or the in-process entitlement attached to its receipt.
pub fn readRecord(
    owner: *product.revision.Store,
    reader: *format.Reader,
    manifests: *const Manifests,
) serialization.DeserializeError!product.ProductKey {
    const blob = try reader.readBlob();
    const manifest = try manifests.at(try reader.readInt(u32));
    const imported = owner.importRecord(blob, manifest, .{
        .bytes = format.max_blob_bytes,
        .records = format.max_total_entries,
        .depth = 64,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProductRecord,
    };
    imported.release();
    return product.productKey(imported);
}

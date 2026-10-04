const std = @import("std");
const sys = @import("sys");
const incremental = @import("incremental/root.zig");
const model = @import("model.zig");

const Target = model.Target;

pub const LinkedImage = struct {
    bytes: []u8,
    storage: Storage = .heap,
    manifest: incremental.Manifest,

    pub const Storage = union(enum) {
        heap,
        mapped_file: []align(std.heap.page_size_min) u8,

        pub const Allocation = struct {
            bytes: []u8,
            storage: Storage,

            pub fn deinit(self: *Allocation, allocator: std.mem.Allocator) void {
                switch (self.storage) {
                    .heap => allocator.free(self.bytes),
                    .mapped_file => |mapping| sys.memory.unmap(mapping),
                }
                self.* = undefined;
            }

            pub fn needsZeroFill(self: Allocation) bool {
                return switch (self.storage) {
                    .heap => true,
                    .mapped_file => false,
                };
            }
        };

        pub fn allocate(
            allocator: std.mem.Allocator,
            len: usize,
            options: model.LinkOptions,
        ) model.Error!Allocation {
            if (options.mapped_output_file) |file| {
                if (len >= options.mapped_output_min_size) {
                    const file_len = std.math.cast(u64, len) orelse return error.OutputFileError;
                    file.setLength(sys.fs.debugIo(), 0) catch return error.OutputFileError;
                    file.setLength(sys.fs.debugIo(), file_len) catch return error.OutputFileError;
                    const mapping = sys.memory.mapSharedFile(file.handle, len, .{ .read = true, .write = true }, 0) catch |err| switch (err) {
                        error.UnsupportedPlatform => return heapAllocation(allocator, len),
                        else => return error.OutputFileError,
                    };
                    return .{
                        .bytes = mapping[0..len],
                        .storage = .{ .mapped_file = mapping },
                    };
                }
            }
            return heapAllocation(allocator, len);
        }

        fn heapAllocation(allocator: std.mem.Allocator, len: usize) model.Error!Allocation {
            return .{
                .bytes = try allocator.alloc(u8, len),
                .storage = .heap,
            };
        }
    };

    pub fn deinit(self: *LinkedImage, allocator: std.mem.Allocator) void {
        switch (self.storage) {
            .heap => allocator.free(self.bytes),
            .mapped_file => |mapping| sys.memory.unmap(mapping),
        }
        self.manifest.deinit(allocator);
        self.* = undefined;
    }

    pub fn isMaterialized(self: LinkedImage) bool {
        return switch (self.storage) {
            .heap => false,
            .mapped_file => true,
        };
    }

    pub fn prepareIncrementalState(
        self: *LinkedImage,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!incremental.PreparedState {
        return try incremental.PreparedState.fromOwnedManifest(allocator, self.manifest.take());
    }
};

pub const Object = struct {
    target: Target,
    sections: []ObjectSection,
    symbols: []ObjectSymbol,

    pub fn deinit(self: *Object, allocator: std.mem.Allocator) void {
        if (self.sections.len != 0) allocator.free(self.sections);
        if (self.symbols.len != 0) allocator.free(self.symbols);
        self.* = undefined;
    }
};

pub const ObjectSection = struct {
    segment_name: []const u8 = "",
    name: []const u8,
    address: u64 = 0,
    size: u64,
    offset: u64,
    alignment: u64,
    flags: u64,
    section_type: u32 = 0,
    relocation_count: u32,
};

pub const ObjectSymbol = struct {
    name: []const u8,
    section_index: i32,
    value: u64,
    size: u64 = 0,
    kind: u32,
    binding: u32 = 0,
    external: bool,
    undefined: bool,
};

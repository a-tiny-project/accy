const std = @import("std");
const Allocator = std.mem.Allocator;
const artifact = @import("root.zig");
const slice = artifact.slice;

pub const Architecture = enum(u8) {
    unknown = 1,
    x86_64 = 2,
    aarch64 = 3,
    wasm = 4,
};

pub const Endianness = enum(u8) {
    little = 1,
    big = 2,
};

pub const ArtifactKind = enum(u8) {
    unknown = 1,
    machine_code = 2,
    object_file = 3,
    webassembly_module = 4,
    assembly = 5,
    source_text = 6,
    debug_info = 7,
    container = 8,
};

pub const Target = struct {
    architecture: Architecture = .unknown,
    triple: ?[]const u8 = null,
    vendor: ?[]const u8 = null,
    os: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    features: []const []const u8 = &.{},

    pub fn dupe(self: Target, allocator: Allocator) Allocator.Error!Target {
        var out = Target{ .architecture = self.architecture };
        errdefer out.deinit(allocator);
        out.triple = try slice.dupeOptional(allocator, self.triple);
        out.vendor = try slice.dupeOptional(allocator, self.vendor);
        out.os = try slice.dupeOptional(allocator, self.os);
        out.environment = try slice.dupeOptional(allocator, self.environment);
        out.cpu = try slice.dupeOptional(allocator, self.cpu);
        out.features = try slice.dupeList(allocator, self.features);
        return out;
    }

    pub fn deinit(self: *Target, allocator: Allocator) void {
        slice.freeOptional(allocator, self.triple);
        slice.freeOptional(allocator, self.vendor);
        slice.freeOptional(allocator, self.os);
        slice.freeOptional(allocator, self.environment);
        slice.freeOptional(allocator, self.cpu);
        slice.freeList(allocator, self.features);
        self.* = .{};
    }

    pub fn eql(self: Target, other: Target) bool {
        if (self.architecture != other.architecture or
            !slice.optionalEqual(self.triple, other.triple) or
            !slice.optionalEqual(self.vendor, other.vendor) or
            !slice.optionalEqual(self.os, other.os) or
            !slice.optionalEqual(self.environment, other.environment) or
            !slice.optionalEqual(self.cpu, other.cpu) or
            self.features.len != other.features.len)
        {
            return false;
        }
        for (self.features, other.features) |left, right| {
            if (!std.mem.eql(u8, left, right)) return false;
        }
        return true;
    }
};

pub const Abi = struct {
    name: ?[]const u8 = null,
    calling_convention: ?[]const u8 = null,
    object_format: ?[]const u8 = null,
    pointer_width_bits: ?u16 = null,
    endianness: ?Endianness = null,

    pub fn dupe(self: Abi, allocator: Allocator) Allocator.Error!Abi {
        var out = Abi{
            .pointer_width_bits = self.pointer_width_bits,
            .endianness = self.endianness,
        };
        errdefer out.deinit(allocator);
        out.name = try slice.dupeOptional(allocator, self.name);
        out.calling_convention = try slice.dupeOptional(allocator, self.calling_convention);
        out.object_format = try slice.dupeOptional(allocator, self.object_format);
        return out;
    }

    pub fn deinit(self: *Abi, allocator: Allocator) void {
        slice.freeOptional(allocator, self.name);
        slice.freeOptional(allocator, self.calling_convention);
        slice.freeOptional(allocator, self.object_format);
        self.* = .{};
    }

    pub fn eql(self: Abi, other: Abi) bool {
        return slice.optionalEqual(self.name, other.name) and
            slice.optionalEqual(self.calling_convention, other.calling_convention) and
            slice.optionalEqual(self.object_format, other.object_format) and
            self.pointer_width_bits == other.pointer_width_bits and
            self.endianness == other.endianness;
    }
};

pub const Metadata = struct {
    kind: ArtifactKind = .unknown,
    producer: ?[]const u8 = null,
    target: Target = .{},
    abi: Abi = .{},

    pub fn dupe(self: Metadata, allocator: Allocator) Allocator.Error!Metadata {
        var out = Metadata{ .kind = self.kind };
        errdefer out.deinit(allocator);
        out.producer = try slice.dupeOptional(allocator, self.producer);
        out.target = try self.target.dupe(allocator);
        out.abi = try self.abi.dupe(allocator);
        return out;
    }

    pub fn deinit(self: *Metadata, allocator: Allocator) void {
        slice.freeOptional(allocator, self.producer);
        self.target.deinit(allocator);
        self.abi.deinit(allocator);
        self.* = .{};
    }

    pub fn eql(self: Metadata, other: Metadata) bool {
        return self.kind == other.kind and
            slice.optionalEqual(self.producer, other.producer) and
            self.target.eql(other.target) and
            self.abi.eql(other.abi);
    }
};

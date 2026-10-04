const std = @import("std");
const source = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const ElementType = enum(u8) {
    i1 = 1,
    i8 = 2,
    i16 = 3,
    i32 = 4,
    i64 = 5,
    u8 = 6,
    u16 = 7,
    u32 = 8,
    u64 = 9,
    f16 = 10,
    bf16 = 11,
    f32 = 12,
    f64 = 13,
    key = 14,

    pub fn byteSize(self: ElementType) u64 {
        return switch (self) {
            .i1, .i8, .u8 => 1,
            .i16, .u16, .f16, .bf16 => 2,
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64, .key => 8,
        };
    }
};

/// A logical value crossing partition boundaries before physical placement is chosen.
/// The byte size must match the static shape, and ownership and alias facts are mandatory.
pub const BoundarySpec = struct {
    id: source.BoundaryId,
    name: []const u8,
    element_type: ElementType,
    dimensions: []const u64,
    byte_size: u64,
    access: source.Access,
    ownership: source.Ownership,
    alias: Alias,
    provenance: source.ProvenanceSpec,
};

pub const Alias = union(enum(u8)) {
    disjoint,
    boundary: source.BoundaryId,

    pub fn eql(self: Alias, other: Alias) bool {
        const Tag = std.meta.Tag(Alias);
        if (@as(Tag, self) != @as(Tag, other)) return false;
        return switch (self) {
            .disjoint => true,
            .boundary => |id| id.value == other.boundary.value,
        };
    }
};

/// An owned, context-independent boundary descriptor.
pub const Boundary = struct {
    id: source.BoundaryId,
    name: []const u8,
    element_type: ElementType,
    dimensions: []const u64,
    byte_size: u64,
    access: source.Access,
    ownership: source.Ownership,
    alias: Alias,
    provenance: source.Provenance,

    pub fn init(allocator: Allocator, spec: BoundarySpec) Allocator.Error!Boundary {
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const dimensions = try source.slice.dupeOrEmpty(u64, allocator, spec.dimensions);
        errdefer source.slice.freeOrEmpty(u64, allocator, dimensions);
        return .{
            .id = spec.id,
            .name = name,
            .element_type = spec.element_type,
            .dimensions = dimensions,
            .byte_size = spec.byte_size,
            .access = spec.access,
            .ownership = spec.ownership,
            .alias = spec.alias,
            .provenance = try source.Provenance.init(allocator, spec.provenance),
        };
    }

    pub fn clone(self: Boundary, allocator: Allocator) Allocator.Error!Boundary {
        return try init(allocator, .{
            .id = self.id,
            .name = self.name,
            .element_type = self.element_type,
            .dimensions = self.dimensions,
            .byte_size = self.byte_size,
            .access = self.access,
            .ownership = self.ownership,
            .alias = self.alias,
            .provenance = .{
                .path = self.provenance.path,
                .symbol = self.provenance.symbol,
                .line = self.provenance.line,
                .column = self.provenance.column,
            },
        });
    }

    pub fn deinit(self: *Boundary, allocator: Allocator) void {
        self.provenance.deinit(allocator);
        source.slice.freeOrEmpty(u64, allocator, self.dimensions);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub fn staticByteSize(element_type: ElementType, dimensions: []const u64) ?u64 {
    var byte_size = element_type.byteSize();
    for (dimensions) |dimension| {
        if (dimension == 0) return null;
        byte_size = std.math.mul(u64, byte_size, dimension) catch return null;
    }
    return byte_size;
}

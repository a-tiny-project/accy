const std = @import("std");

pub const type_names = struct {
    pub const tma_desc = "gpu.tma_desc";
    pub const mbarrier = "gpu.mbarrier";
    /// A 2D float texture and the sampler that reads it, bound together as
    /// one sampled-texture binding.
    pub const sampled_texture = "gpu.sampled_texture";
};

pub const attr_names = struct {
    /// The stage of a vertex or fragment function, held where a compute
    /// function holds `kernel`.
    pub const stage = "gpu.stage";
    /// The workgroup shape a kernel declares, held beside `kernel`.
    pub const workgroup_size = "gpu.workgroup_size";
    /// Byte offset of a dynamic shared `memref.alloc` inside the launch's
    /// dynamic shared-memory window.
    pub const dynamic_shared_byte_offset = "gpu.dynamic_shared_byte_offset";
};

pub const Dimension = enum {
    x,
    y,
    z,

    pub fn toString(self: Dimension) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Dimension {
        if (std.mem.eql(u8, s, "x")) return .x;
        if (std.mem.eql(u8, s, "y")) return .y;
        if (std.mem.eql(u8, s, "z")) return .z;
        return null;
    }
};

/// The programmable raster stage a function runs as.
pub const Stage = enum {
    vertex,
    fragment,

    pub fn toString(self: Stage) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Stage {
        if (std.mem.eql(u8, s, "vertex")) return .vertex;
        if (std.mem.eql(u8, s, "fragment")) return .fragment;
        return null;
    }
};

pub const Scope = enum {
    thread,
    warp,
    block,
    cluster,
    device,
    system,

    pub fn toString(self: Scope) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Scope {
        inline for (
            @typeInfo(Scope).@"enum".field_names,
            @typeInfo(Scope).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            if (std.mem.eql(u8, s, field.name)) {
                return @fromBackingInt(@intCast(field.value));
            }
        }
        return null;
    }
};

pub const MemoryOrder = enum {
    relaxed,
    acquire,
    release,
    acq_rel,
    seq_cst,

    pub fn toString(self: MemoryOrder) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?MemoryOrder {
        inline for (
            @typeInfo(MemoryOrder).@"enum".field_names,
            @typeInfo(MemoryOrder).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            if (std.mem.eql(u8, s, field.name)) {
                return @fromBackingInt(@intCast(field.value));
            }
        }
        return null;
    }
};

pub const ShuffleMode = enum {
    sync,
    down,
    up,
    xor,

    pub fn toString(self: ShuffleMode) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?ShuffleMode {
        inline for (
            @typeInfo(ShuffleMode).@"enum".field_names,
            @typeInfo(ShuffleMode).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            if (std.mem.eql(u8, s, field.name)) {
                return @fromBackingInt(@intCast(field.value));
            }
        }
        return null;
    }
};

pub const WarpOpKind = enum {
    add,
    max,
    min,
    and_,
    or_,
    xor,

    pub fn toString(self: WarpOpKind) []const u8 {
        return switch (self) {
            .and_ => "and",
            .or_ => "or",
            else => @tagName(self),
        };
    }

    pub fn fromString(s: []const u8) ?WarpOpKind {
        if (std.mem.eql(u8, s, "add")) return .add;
        if (std.mem.eql(u8, s, "max")) return .max;
        if (std.mem.eql(u8, s, "min")) return .min;
        if (std.mem.eql(u8, s, "and")) return .and_;
        if (std.mem.eql(u8, s, "or")) return .or_;
        if (std.mem.eql(u8, s, "xor")) return .xor;
        return null;
    }
};

pub const MmaShape = struct {
    m: u32,
    n: u32,
    k: u32,

    pub fn toString(self: MmaShape, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{d}x{d}x{d}", .{ self.m, self.n, self.k });
    }

    pub fn parse(s: []const u8) ?MmaShape {
        var iter = std.mem.splitScalar(u8, s, 'x');
        const m_str = iter.next() orelse return null;
        const n_str = iter.next() orelse return null;
        const k_str = iter.next() orelse return null;
        if (iter.next() != null) return null;

        const m = std.fmt.parseInt(u32, m_str, 10) catch return null;
        const n = std.fmt.parseInt(u32, n_str, 10) catch return null;
        const k = std.fmt.parseInt(u32, k_str, 10) catch return null;
        return .{ .m = m, .n = n, .k = k };
    }
};

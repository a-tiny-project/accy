const builder = @import("../../root.zig").builder;
const program = @import("../../program/root.zig");

pub fn Index1DContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        name: []const u8,
        extent: u64,
        threads_per_block: u32,

        pub fn default(self: *@This()) !program.Index1D {
            return self.next.index1D(self.name, self.extent, self.threads_per_block);
        }
    };
}

pub fn Index2DContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        domain: program.Domain2D,

        pub fn default(self: *@This()) !program.Index2D {
            return self.next.index2D(self.domain);
        }
    };
}

pub fn Index3DContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        domain: program.Domain3D,

        pub fn default(self: *@This()) !program.Index3D {
            return self.next.index3D(self.domain);
        }
    };
}

pub fn GlobalIdContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dim: builder.Dimension,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.globalId(self.dim);
        }
    };
}

pub fn ThreadIdContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dim: builder.Dimension,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.threadId(self.dim);
        }
    };
}

pub fn BlockIdContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dim: builder.Dimension,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.blockId(self.dim);
        }
    };
}

pub fn BlockDimContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dim: builder.Dimension,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.blockDim(self.dim);
        }
    };
}

pub fn GridDimContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dim: builder.Dimension,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.gridDim(self.dim);
        }
    };
}

const gpu_abi = @import("gpu_abi");
const builder = @import("../../root.zig").builder;

const DType = gpu_abi.DType;

pub fn LoadContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        memref: builder.Value,
        index: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.load(self.memref, self.index);
        }
    };
}

pub fn LoadIndexContext(comptime Handle: type, comptime Index: type) type {
    return struct {
        next: Handle,
        memref: builder.Value,
        index: Index,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.loadIndex(self.memref, self.index);
        }
    };
}

pub fn StoreContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        value: builder.Value,
        memref: builder.Value,
        index: builder.Value,

        pub fn default(self: *@This()) !void {
            try self.next.store(self.value, self.memref, self.index);
        }
    };
}

pub fn StoreIndexContext(comptime Handle: type, comptime Index: type) type {
    return struct {
        next: Handle,
        value: builder.Value,
        memref: builder.Value,
        index: Index,

        pub fn default(self: *@This()) !void {
            try self.next.storeIndex(self.value, self.memref, self.index);
        }
    };
}

pub fn AtomicRmwContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        kind: builder.AtomicRmwKind,
        value: builder.Value,
        memref: builder.Value,
        index: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.atomicRmw(self.kind, self.value, self.memref, self.index);
        }
    };
}

pub fn AtomicCasContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        expected: builder.Value,
        desired: builder.Value,
        memref: builder.Value,
        index: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.atomicCas(self.expected, self.desired, self.memref, self.index);
        }
    };
}

pub fn SharedBufferContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dtype: DType,
        size: u64,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.sharedBuffer(self.dtype, self.size);
        }
    };
}

pub fn BarrierContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        scope: builder.Scope,

        pub fn default(self: *@This()) !void {
            try self.next.barrier(self.scope);
        }
    };
}

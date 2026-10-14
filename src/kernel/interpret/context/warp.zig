const builder = @import("../../root.zig").builder;

pub fn LaneIdContext(comptime Handle: type) type {
    return struct {
        next: Handle,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.laneId();
        }
    };
}

pub fn WarpIdContext(comptime Handle: type) type {
    return struct {
        next: Handle,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.warpId();
        }
    };
}

pub fn ActiveMaskContext(comptime Handle: type) type {
    return struct {
        next: Handle,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.activeMask();
        }
    };
}

pub fn SyncWarpContext(comptime Handle: type) type {
    return struct {
        next: Handle,

        pub fn default(self: *@This()) !void {
            try self.next.syncWarp();
        }
    };
}

pub fn AllSyncContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        predicate: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.allSync(self.predicate);
        }
    };
}

pub fn AnySyncContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        predicate: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.anySync(self.predicate);
        }
    };
}

pub fn BallotSyncContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        predicate: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.ballotSync(self.predicate);
        }
    };
}

pub fn WarpReduceContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        op_kind: builder.WarpOpKind,
        value: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.warpReduce(self.op_kind, self.value);
        }
    };
}

pub fn WarpScanContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        op_kind: builder.WarpOpKind,
        mode: builder.WarpScanMode,
        value: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.warpScan(self.op_kind, self.mode, self.value);
        }
    };
}

pub fn ShuffleSyncContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        mode: builder.ShuffleMode,
        value: builder.Value,
        lane_or_delta: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.shuffleSync(self.mode, self.value, self.lane_or_delta);
        }
    };
}

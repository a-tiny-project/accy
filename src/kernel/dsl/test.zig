const std = @import("std");
const kernel = @import("../root.zig");
const namespace = @import("root.zig");
const body = namespace.body;
const Program = namespace.Program;
const Family = namespace.Family;

fn scale_each(inner: anytype, index: kernel.Index1D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    const scaled = try value.mul(inner, args.param(.scale));
    try args.param(.dst).store(inner, scaled, index);
}

fn scaleFamilyBody(k: anytype, extent: u64, args: anytype) !void {
    _ = try k.forEach1D("i", extent, 4, args, scale_each);
}

const ScaleFamily = Family(.{
    .name = "kernel_dsl_scale_family_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .Instance = u64,
    .body = scaleFamilyBody,
});

test "kernel Family builds checked graphs from runtime instances" {
    try std.testing.expectEqual(@as(usize, 0), ScaleFamily.arg(.src));
    try std.testing.expectEqual(@as(usize, 2), ScaleFamily.arg(.scale));
    try std.testing.expectEqual(@as(usize, 3), ScaleFamily.schema().len);

    var graph = try ScaleFamily.build(std.testing.allocator, ScaleFamily.Limits.testing, 5);
    defer graph.deinit();
    try graph.verify();

    const narrow_launch = try graph.launch();
    try std.testing.expectEqual(@as(u32, 2), narrow_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), narrow_launch.block[0]);

    const wide_launch = try ScaleFamily.launch(std.testing.allocator, ScaleFamily.Limits.testing, 9);
    try std.testing.expectEqual(@as(u32, 3), wide_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), wide_launch.block[0]);

    var plan = try ScaleFamily.createCheckedPlan(std.testing.allocator, ScaleFamily.Limits.testing, 9, .{});
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 3), plan.argument_count);
    try std.testing.expectEqualStrings("kernel_dsl_scale_family_f32", plan.entry_name);

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try ScaleFamily.runCpu(std.testing.allocator, ScaleFamily.Limits.testing, 5, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 2.0, -4.0, 7.0, 8.0, -0.5 }, output[0..]);

    var wide_input = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0 };
    var wide_output = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try ScaleFamily.runCpu(std.testing.allocator, ScaleFamily.Limits.testing, 9, &.{
        kernel.argumentBuffer(f32, wide_input[0..]),
        kernel.argumentBuffer(f32, wide_output[0..]),
        kernel.argumentF32(-1.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ -1.0, -2.0, -3.0, -4.0, -5.0, -6.0, -7.0, -8.0, -9.0 }, wide_output[0..]);
}

fn scaleBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 5, 4, args, scale_each);
}

const Scale = Program(.{
    .name = "kernel_dsl_scale_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .body = scaleBody,
});

test "kernel Program builds named typed arguments into a checked graph" {
    try std.testing.expectEqual(@as(usize, 0), Scale.arg(.src));
    try std.testing.expectEqual(@as(usize, 1), Scale.arg(.dst));
    try std.testing.expectEqual(@as(usize, 2), Scale.arg(.scale));
    try std.testing.expectEqual(@as(usize, 3), Scale.schema().len);

    var graph = try Scale.build(std.testing.allocator, Scale.Limits.testing);
    defer graph.deinit();
    try graph.verify();

    var interpreted_graph = try Scale.interpret(std.testing.allocator, Scale.Limits.testing, kernel.interpret.graph());
    defer interpreted_graph.deinit();
    try interpreted_graph.verify();

    const launch_value = try graph.launch();
    const interpreted_launch = try interpreted_graph.launch();
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(launch_value.grid, interpreted_launch.grid);
    try std.testing.expectEqual(launch_value.block, interpreted_launch.block);

    var out = try Scale.createCheckedPlan(std.testing.allocator, Scale.Limits.testing, .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(u32, 3), out.argument_count);
    try std.testing.expectEqualStrings("kernel_dsl_scale_f32", out.entry_name);

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try Scale.runCpu(std.testing.allocator, Scale.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 2.0, -4.0, 7.0, 8.0, -0.5 }, output[0..]);
}

fn interpreted_scale_each(inner: anytype, index: kernel.Index1D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    const scaled = try value.mul(inner, args.param(.scale));
    const shifted = try scaled.add(inner, 1.0);
    try args.param(.dst).store(inner, shifted, index);
}

fn interpretedScaleBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 5, 4, args, interpreted_scale_each);
}

const InterpretedScale = Program(.{
    .name = "kernel_dsl_interpreted_scale_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .body = interpretedScaleBody,
});

const DropAdd = struct {
    pub fn add(_: *@This(), ctx: anytype) !kernel.Value {
        return ctx.lhs;
    }
};

const DropMul = struct {
    pub fn mul(_: *@This(), ctx: anytype) !kernel.Value {
        return ctx.lhs;
    }
};

const MulAsAdd = struct {
    pub fn mul(_: *@This(), ctx: anytype) !kernel.Value {
        return ctx.next.add(ctx.lhs, ctx.rhs);
    }
};

const TransformedScale = InterpretedScale.transform(DropAdd{});
const TwiceTransformedScale = TransformedScale.transform(DropMul{});
const AdditiveScale = InterpretedScale.transform(kernel.interpret.bindIndexed(MulAsAdd{}));

fn add_before_mul_each(inner: anytype, index: kernel.Index1D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    const shifted = try value.add(inner, 1.0);
    const scaled = try shifted.mul(inner, args.param(.scale));
    try args.param(.dst).store(inner, scaled, index);
}

fn addBeforeMulBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 5, 4, args, add_before_mul_each);
}

const AddBeforeMul = Program(.{
    .name = "kernel_dsl_add_before_mul_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .body = addBeforeMulBody,
});

fn add_only_each(inner: anytype, index: kernel.Index1D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    const shifted = try value.add(inner, args.param(.scale));
    try args.param(.dst).store(inner, shifted, index);
}

fn addOnlyBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 5, 4, args, add_only_each);
}

const AddOnly = Program(.{
    .name = "kernel_dsl_add_only_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .body = addOnlyBody,
});

const MulPresence = struct {
    has_mul: bool = false,

    pub const Result = struct {
        graph: kernel.Graph,
        has_mul: bool,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        self.has_mul = true;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .has_mul = self.has_mul,
        };
    }
};

const DropAddWhenMulPresent = struct {
    enabled: bool,

    pub fn add(self: *@This(), ctx: anytype) !kernel.Value {
        if (self.enabled) return ctx.lhs;
        return ctx.default();
    }
};

fn dropAddFromMulPresence(analysis: *const MulPresence.Result) DropAddWhenMulPresent {
    return .{ .enabled = analysis.has_mul };
}

const AddPresence = struct {
    has_add: bool = false,

    pub const Result = struct {
        graph: kernel.Graph,
        has_add: bool,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn add(self: *@This(), ctx: anytype) !kernel.Value {
        self.has_add = true;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .has_add = self.has_add,
        };
    }
};

const DropMulWhenAddMissing = struct {
    enabled: bool,

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        if (self.enabled) return ctx.lhs;
        return ctx.default();
    }
};

fn dropMulFromAddPresence(analysis: *const AddPresence.Result) DropMulWhenAddMissing {
    return .{ .enabled = !analysis.has_add };
}

const BorrowedAddFlags = struct {
    add_count: usize = 0,

    pub const Result = struct {
        graph: kernel.Graph,
        allocator: std.mem.Allocator,
        flags: []const bool,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.allocator.free(self.flags);
            self.* = undefined;
        }
    };

    pub fn add(self: *@This(), ctx: anytype) !kernel.Value {
        self.add_count += 1;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        const flags = try std.testing.allocator.alloc(bool, 1);
        errdefer std.testing.allocator.free(flags);
        flags[0] = self.add_count != 0;
        return .{
            .graph = try ctx.default(),
            .allocator = std.testing.allocator,
            .flags = flags,
        };
    }
};

const DropMulFromBorrowedFlags = struct {
    flags: []const bool,

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        if (self.flags[0]) return ctx.lhs;
        return ctx.default();
    }
};

fn borrowDropMulFlags(analysis: *const BorrowedAddFlags.Result) DropMulFromBorrowedFlags {
    return .{ .flags = analysis.flags };
}

const AddBeforeMulAnalysis = AddBeforeMul.analyze(MulPresence{});
const AddOnlyAnalysis = AddOnly.analyze(MulPresence{});
const DropAddAfterMulAnalysis = AddBeforeMulAnalysis.transform(dropAddFromMulPresence);
const KeepAddAfterMulAnalysis = AddOnlyAnalysis.transform(dropAddFromMulPresence);
const DropMulAfterAnalyzedDropAdd = DropAddAfterMulAnalysis.transform(DropMul{});
const AnalyzeAfterDroppedMul = AddBeforeMul.transform(DropMul{}).analyze(MulPresence{}).transform(dropAddFromMulPresence);
const DropMulAfterAnalyzedAddRemoval = DropAddAfterMulAnalysis.analyze(AddPresence{}).transform(dropMulFromAddPresence);
const DropMulWithBorrowedAnalysisFlags = AddBeforeMul.analyze(BorrowedAddFlags{}).transform(borrowDropMulFlags);

const RequireStore = struct {
    store_count: usize = 0,

    pub const Result: type = kernel.Graph;

    pub fn store(self: *@This(), ctx: anytype) !void {
        self.store_count += 1;
        try ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        if (self.store_count == 0) return error.KernelProgramRequiresStore;
        return ctx.default();
    }
};

const StoreCheckedScale = InterpretedScale.transform(RequireStore{});

fn no_store_each(inner: anytype, index: kernel.Index1D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    _ = try value.add(inner, args.param(.scale));
}

fn noStoreBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 5, 4, args, no_store_each);
}

const NoStore = Program(.{
    .name = "kernel_dsl_no_store_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .body = noStoreBody,
});

const StoreCheckedNoStore = NoStore.transform(RequireStore{});

const ArithmeticCounter = struct {
    mul_count: usize = 0,
    add_count: usize = 0,
    store_count: usize = 0,

    pub const Result = struct {
        graph: kernel.Graph,
        mul_count: usize,
        add_count: usize,
        store_count: usize,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        self.mul_count += 1;
        return ctx.default();
    }

    pub fn add(self: *@This(), ctx: anytype) !kernel.Value {
        self.add_count += 1;
        return ctx.default();
    }

    pub fn store(self: *@This(), ctx: anytype) !void {
        self.store_count += 1;
        try ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .mul_count = self.mul_count,
            .add_count = self.add_count,
            .store_count = self.store_count,
        };
    }
};

const WhileCountdownCarry = struct {
    remaining: kernel.TypedValue(.i32),
    total: kernel.TypedValue(.i32),
};

fn while_countdown_continue(
    inner: anytype,
    carry: WhileCountdownCarry,
    _: void,
) !kernel.TypedValue(.i1) {
    return carry.remaining.compare(inner, .gt, 0);
}

fn while_countdown_step(
    inner: anytype,
    carry: WhileCountdownCarry,
    _: void,
) !WhileCountdownCarry {
    return .{
        .remaining = try carry.remaining.sub(inner, 1),
        .total = try carry.total.add(inner, carry.remaining),
    };
}

fn while_countdown_each(inner: anytype, index: kernel.Index1D, args: anytype) !void {
    const start = try args.param(.src).load(inner, index);
    const zero = try inner.constantValue(.i32, 0);
    const walked = try inner.whileLoop(
        WhileCountdownCarry{ .remaining = start, .total = zero },
        {},
        while_countdown_continue,
        while_countdown_step,
    );
    try args.param(.dst).store(inner, walked.total, index);
}

fn whileCountdownBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 4, 4, args, while_countdown_each);
}

const WhileCountdown = Program(.{
    .name = "kernel_dsl_while_countdown_i32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.i32),
        .dst = kernel.dynamicBuffer(.i32),
    },
    .body = whileCountdownBody,
});

const WhileLoopCounter = struct {
    while_loop_count: usize = 0,

    pub const Result = struct {
        graph: kernel.Graph,
        while_loop_count: usize,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn whileLoop(self: *@This(), ctx: anytype) !@TypeOf(ctx.initial) {
        self.while_loop_count += 1;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .while_loop_count = self.while_loop_count,
        };
    }
};

fn tiled_launch_each(inner: anytype, index: kernel.Index2D, args: anytype) !void {
    const global = try inner.globalIdValue(.i32, .x);
    const thread = try inner.threadIdValue(.i32, .x);
    const block = try inner.blockIdValue(.i32, .y);
    const block_dim = try inner.blockDimValue(.i32, .x);
    const grid_dim = try inner.gridDimValue(.i32, .y);
    const global_thread = try global.add(inner, thread);
    const with_block = try global_thread.add(inner, block);
    const with_block_dim = try with_block.add(inner, block_dim);
    const value = try with_block_dim.add(inner, grid_dim);
    try args.param(.dst).store(inner, value, index);
}

fn tiledLaunchBody(k: anytype, args: anytype) !void {
    _ = try k.forEach2D(.{
        .x = kernel.domainAxis("x", 5, 2),
        .y = kernel.domainAxis("y", 3, 2),
    }, args, tiled_launch_each);
}

const TiledLaunch = Program(.{
    .name = "kernel_dsl_tiled_launch_i32",
    .parameters = .{
        .dst = kernel.dynamicBuffer(.i32),
    },
    .body = tiledLaunchBody,
});

const DomainCounter = struct {
    index2d_count: usize = 0,
    global_id_count: usize = 0,
    thread_id_count: usize = 0,
    block_id_count: usize = 0,
    block_dim_count: usize = 0,
    grid_dim_count: usize = 0,
    compare_count: usize = 0,
    constant_index_count: usize = 0,
    mul_count: usize = 0,
    add_count: usize = 0,
    store_count: usize = 0,

    pub const Result = struct {
        graph: kernel.Graph,
        index2d_count: usize,
        global_id_count: usize,
        thread_id_count: usize,
        block_id_count: usize,
        block_dim_count: usize,
        grid_dim_count: usize,
        compare_count: usize,
        constant_index_count: usize,
        mul_count: usize,
        add_count: usize,
        store_count: usize,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn index2D(self: *@This(), ctx: anytype) !kernel.Index2D {
        self.index2d_count += 1;
        return ctx.default();
    }

    pub fn globalId(self: *@This(), ctx: anytype) !kernel.Value {
        self.global_id_count += 1;
        return ctx.default();
    }

    pub fn threadId(self: *@This(), ctx: anytype) !kernel.Value {
        self.thread_id_count += 1;
        return ctx.default();
    }

    pub fn blockId(self: *@This(), ctx: anytype) !kernel.Value {
        self.block_id_count += 1;
        return ctx.default();
    }

    pub fn blockDim(self: *@This(), ctx: anytype) !kernel.Value {
        self.block_dim_count += 1;
        return ctx.default();
    }

    pub fn gridDim(self: *@This(), ctx: anytype) !kernel.Value {
        self.grid_dim_count += 1;
        return ctx.default();
    }

    pub fn compare(self: *@This(), ctx: anytype) !kernel.Value {
        self.compare_count += 1;
        return ctx.default();
    }

    pub fn constantIndex(self: *@This(), ctx: anytype) !kernel.Value {
        self.constant_index_count += 1;
        return ctx.default();
    }

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        self.mul_count += 1;
        return ctx.default();
    }

    pub fn add(self: *@This(), ctx: anytype) !kernel.Value {
        self.add_count += 1;
        return ctx.default();
    }

    pub fn store(self: *@This(), ctx: anytype) !void {
        self.store_count += 1;
        try ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .index2d_count = self.index2d_count,
            .global_id_count = self.global_id_count,
            .thread_id_count = self.thread_id_count,
            .block_id_count = self.block_id_count,
            .block_dim_count = self.block_dim_count,
            .grid_dim_count = self.grid_dim_count,
            .compare_count = self.compare_count,
            .constant_index_count = self.constant_index_count,
            .mul_count = self.mul_count,
            .add_count = self.add_count,
            .store_count = self.store_count,
        };
    }
};

fn matrix_copy_each(inner: anytype, index: kernel.Index2D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    try args.param(.dst).store(inner, value, index);
}

fn matrixCopyBody(k: anytype, args: anytype) !void {
    _ = try k.forEach2D(.{
        .x = kernel.domainAxis("x", 3, 2),
        .y = kernel.domainAxis("y", 2, 2),
    }, args, matrix_copy_each);
}

const MatrixCopy = Program(.{
    .name = "kernel_dsl_matrix_copy_i32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.i32),
        .dst = kernel.dynamicBuffer(.i32),
    },
    .body = matrixCopyBody,
});

const TransposeIndexedStores = struct {
    pub fn storeIndex(_: *@This(), ctx: anytype) !void {
        const Index = @TypeOf(ctx.index);
        if (comptime Index == kernel.Index2D) {
            const height = try ctx.next.constantIndex(std.math.cast(i64, ctx.index.y.extent) orelse return error.LaunchDimensionOverflow);
            const column_base = try ctx.next.mul(ctx.index.x.index, height);
            const transposed_index = try ctx.next.add(column_base, ctx.index.y.index);
            try ctx.next.store(ctx.value, ctx.memref, transposed_index);
            return;
        }
        try ctx.default();
    }
};

const TransposedMatrixStores = MatrixCopy.transform(TransposeIndexedStores{});

fn paired_matrix_stores_each(inner: anytype, index: kernel.Index2D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    try args.param(.dst).store(inner, value, index);
    try args.param(.audit).store(inner, value, index);
}

fn pairedMatrixStoresBody(k: anytype, args: anytype) !void {
    _ = try k.forEach2D(.{
        .x = kernel.domainAxis("x", 3, 2),
        .y = kernel.domainAxis("y", 2, 2),
    }, args, paired_matrix_stores_each);
}

const PairedMatrixStores = Program(.{
    .name = "kernel_dsl_paired_matrix_stores_i32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.i32),
        .dst = kernel.dynamicBuffer(.i32),
        .audit = kernel.dynamicBuffer(.i32),
    },
    .body = pairedMatrixStoresBody,
});

const DelayedIndexedStore = struct {
    value: kernel.Value,
    memref: kernel.Value,
    index: kernel.Index2D,
};

const TransposeFirstStoreWhenPaired = struct {
    stores: [2]DelayedIndexedStore = undefined,
    store_count: usize = 0,
    active: bool = false,

    pub fn guardIndex2DDo(self: *@This(), ctx: anytype) !void {
        const previous_active = self.active;
        self.active = true;
        self.store_count = 0;
        defer {
            self.active = previous_active;
            self.store_count = 0;
        }

        var x_guard = try ctx.guardIndex(ctx.index.x);
        errdefer x_guard.abort();
        var y_guard = try ctx.guardIndex(ctx.index.y);
        errdefer y_guard.abort();
        try ctx.runBody();
        try self.flush(ctx.next);
        try y_guard.leave();
        try x_guard.leave();
    }

    pub fn storeIndex(self: *@This(), ctx: anytype) !void {
        const Index = @TypeOf(ctx.index);
        if (!self.active or comptime Index != kernel.Index2D) {
            try ctx.default();
            return;
        }
        if (self.store_count == self.stores.len) return error.DelayedStoreCapacityExceeded;
        self.stores[self.store_count] = .{
            .value = ctx.value,
            .memref = ctx.memref,
            .index = ctx.index,
        };
        self.store_count += 1;
    }

    fn flush(self: *@This(), next: anytype) !void {
        for (self.stores[0..self.store_count], 0..) |entry, i| {
            if (self.store_count >= 2 and i == 0) {
                const height = try next.constantIndex(std.math.cast(i64, entry.index.y.extent) orelse return error.LaunchDimensionOverflow);
                const column_base = try next.mul(entry.index.x.index, height);
                const transposed_index = try next.add(column_base, entry.index.y.index);
                try next.store(entry.value, entry.memref, transposed_index);
            } else {
                try next.store(entry.value, entry.memref, try entry.index.linear(next));
            }
        }
    }
};

const DelayedTransposedMatrixStores = MatrixCopy.transform(TransposeFirstStoreWhenPaired{});
const DelayedTransposedPairedStores = PairedMatrixStores.transform(TransposeFirstStoreWhenPaired{});

fn paired_volume_stores_each(inner: anytype, index: kernel.Index3D, args: anytype) !void {
    const value = try args.param(.src).load(inner, index);
    try args.param(.dst).store(inner, value, index);
    try args.param(.audit).store(inner, value, index);
}

fn pairedVolumeStoresBody(k: anytype, args: anytype) !void {
    _ = try k.forEach3D(.{
        .x = kernel.domainAxis("x", 2, 2),
        .y = kernel.domainAxis("y", 2, 2),
        .z = kernel.domainAxis("z", 2, 2),
    }, args, paired_volume_stores_each);
}

const PairedVolumeStores = Program(.{
    .name = "kernel_dsl_paired_volume_stores_i32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.i32),
        .dst = kernel.dynamicBuffer(.i32),
        .audit = kernel.dynamicBuffer(.i32),
    },
    .body = pairedVolumeStoresBody,
});

const DelayedIndexedStore3D = struct {
    value: kernel.Value,
    memref: kernel.Value,
    index: kernel.Index3D,
};

const SwapXzFirstStoreWhenPaired = struct {
    stores: [2]DelayedIndexedStore3D = undefined,
    store_count: usize = 0,
    active: bool = false,

    pub fn guardIndex3DDo(self: *@This(), ctx: anytype) !void {
        const previous_active = self.active;
        self.active = true;
        self.store_count = 0;
        defer {
            self.active = previous_active;
            self.store_count = 0;
        }

        var x_guard = try ctx.guardIndex(ctx.index.x);
        errdefer x_guard.abort();
        var y_guard = try ctx.guardIndex(ctx.index.y);
        errdefer y_guard.abort();
        var z_guard = try ctx.guardIndex(ctx.index.z);
        errdefer z_guard.abort();
        try ctx.runBody();
        try self.flush(ctx.next);
        try z_guard.leave();
        try y_guard.leave();
        try x_guard.leave();
    }

    pub fn storeIndex(self: *@This(), ctx: anytype) !void {
        const Index = @TypeOf(ctx.index);
        if (!self.active or comptime Index != kernel.Index3D) {
            try ctx.default();
            return;
        }
        if (self.store_count == self.stores.len) return error.DelayedStoreCapacityExceeded;
        self.stores[self.store_count] = .{
            .value = ctx.value,
            .memref = ctx.memref,
            .index = ctx.index,
        };
        self.store_count += 1;
    }

    fn flush(self: *@This(), next: anytype) !void {
        for (self.stores[0..self.store_count], 0..) |entry, i| {
            if (self.store_count >= 2 and i == 0) {
                const depth = try next.constantIndex(std.math.cast(i64, entry.index.z.extent) orelse return error.LaunchDimensionOverflow);
                const y_depth = std.math.mul(u64, entry.index.y.extent, entry.index.z.extent) catch return error.LaunchDimensionOverflow;
                const plane = try next.constantIndex(std.math.cast(i64, y_depth) orelse return error.LaunchDimensionOverflow);
                const x_base = try next.mul(entry.index.x.index, plane);
                const y_base = try next.mul(entry.index.y.index, depth);
                const xy_base = try next.add(x_base, y_base);
                const swapped_index = try next.add(xy_base, entry.index.z.index);
                try next.store(entry.value, entry.memref, swapped_index);
            } else {
                try next.store(entry.value, entry.memref, try entry.index.linear(next));
            }
        }
    }
};

const DelayedSwappedVolumeStores = PairedVolumeStores.transform(SwapXzFirstStoreWhenPaired{});

const GuardBodyCounter = struct {
    guard1d_count: usize = 0,

    pub const Result = struct {
        graph: kernel.Graph,
        guard1d_count: usize,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn guardIndexDo(self: *@This(), ctx: anytype) !void {
        self.guard1d_count += 1;
        try ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .guard1d_count = self.guard1d_count,
        };
    }
};

fn guarded_pair_store(inner: anytype, ctx: anytype) !void {
    const value = try ctx.args.param(.src).load(inner, ctx.index);
    try ctx.args.param(.dst).store(inner, value, ctx.index);
    try ctx.args.param(.audit).store(inner, value, ctx.index);
}

fn guarded_pair_stores_each(inner: anytype, index: kernel.Index1D, args: anytype) !void {
    const limit = try inner.constantIndex(4);
    const active = try inner.compare(.lt, index.index, limit);
    try inner.guardDo(active, .{ .args = args, .index = index }, guarded_pair_store);
}

fn guardedPairStoresBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 6, 4, args, guarded_pair_stores_each);
}

const GuardedPairStores = Program(.{
    .name = "kernel_dsl_guarded_pair_stores_i32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.i32),
        .dst = kernel.dynamicBuffer(.i32),
        .audit = kernel.dynamicBuffer(.i32),
    },
    .body = guardedPairStoresBody,
});

const DelayedIndexedStore1D = struct {
    value: kernel.Value,
    memref: kernel.Value,
    index: kernel.Index1D,
};

const ShiftFirstGuardStoreWhenPaired = struct {
    stores: [2]DelayedIndexedStore1D = undefined,
    store_count: usize = 0,
    active: bool = false,

    pub fn guardDo(self: *@This(), ctx: anytype) !void {
        const previous_active = self.active;
        self.active = true;
        self.store_count = 0;
        defer {
            self.active = previous_active;
            self.store_count = 0;
        }

        var active_guard = try ctx.guard(ctx.condition);
        errdefer active_guard.abort();
        try ctx.runBody();
        try self.flush(ctx.next);
        try active_guard.leave();
    }

    pub fn storeIndex(self: *@This(), ctx: anytype) !void {
        const Index = @TypeOf(ctx.index);
        if (!self.active or comptime Index != kernel.Index1D) {
            try ctx.default();
            return;
        }
        if (self.store_count == self.stores.len) return error.DelayedStoreCapacityExceeded;
        self.stores[self.store_count] = .{
            .value = ctx.value,
            .memref = ctx.memref,
            .index = ctx.index,
        };
        self.store_count += 1;
    }

    fn flush(self: *@This(), next: anytype) !void {
        for (self.stores[0..self.store_count], 0..) |entry, i| {
            if (self.store_count >= 2 and i == 0) {
                const offset = try next.constantIndex(2);
                const shifted_index = try next.add(entry.index.index, offset);
                try next.store(entry.value, entry.memref, shifted_index);
            } else {
                try next.store(entry.value, entry.memref, try entry.index.linear(next));
            }
        }
    }
};

const ShiftedGuardedPairStores = GuardedPairStores.transform(ShiftFirstGuardStoreWhenPaired{});

const IndexedStoreCounter = struct {
    store_index_count: usize = 0,
    store_count: usize = 0,
    mul_count: usize = 0,
    add_count: usize = 0,

    pub const Result = struct {
        graph: kernel.Graph,
        store_index_count: usize,
        store_count: usize,
        mul_count: usize,
        add_count: usize,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn storeIndex(self: *@This(), ctx: anytype) !void {
        self.store_index_count += 1;
        try ctx.default();
    }

    pub fn store(self: *@This(), ctx: anytype) !void {
        self.store_count += 1;
        try ctx.default();
    }

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        self.mul_count += 1;
        return ctx.default();
    }

    pub fn add(self: *@This(), ctx: anytype) !kernel.Value {
        self.add_count += 1;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .store_index_count = self.store_index_count,
            .store_count = self.store_count,
            .mul_count = self.mul_count,
            .add_count = self.add_count,
        };
    }
};

test "kernel Program interprets generic bodies through user build semantics" {
    var result = try InterpretedScale.interpret(std.testing.allocator, InterpretedScale.Limits.testing, ArithmeticCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.mul_count);
    try std.testing.expectEqual(@as(usize, 1), result.add_count);
    try std.testing.expectEqual(@as(usize, 1), result.store_count);
    try result.graph.verify();

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try result.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, &.{ 3.5, -4.0, 9.75, 11.0, 0.375 }, output[0..]);
}

test "kernel Program interprets multidimensional launch programs through user semantics" {
    var result = try TiledLaunch.interpret(std.testing.allocator, TiledLaunch.Limits.testing, DomainCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.index2d_count);
    try std.testing.expectEqual(@as(usize, 1), result.global_id_count);
    try std.testing.expectEqual(@as(usize, 1), result.thread_id_count);
    try std.testing.expectEqual(@as(usize, 1), result.block_id_count);
    try std.testing.expectEqual(@as(usize, 1), result.block_dim_count);
    try std.testing.expectEqual(@as(usize, 1), result.grid_dim_count);
    try std.testing.expectEqual(@as(usize, 2), result.compare_count);
    try std.testing.expectEqual(@as(usize, 1), result.constant_index_count);
    try std.testing.expectEqual(@as(usize, 1), result.mul_count);
    try std.testing.expectEqual(@as(usize, 5), result.add_count);
    try std.testing.expectEqual(@as(usize, 1), result.store_count);
    try result.graph.verify();

    const launch_value = try result.graph.launch();
    try std.testing.expectEqual(@as(u32, 3), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);

    var output = @as([15]i32, @splat(0));
    try result.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, output[0..]),
    });

    try std.testing.expectEqualSlices(i32, &.{
        4, 6, 6, 8, 8,
        4, 6, 6, 8, 8,
        5, 7, 7, 9, 9,
    }, output[0..]);
}

test "kernel Program transform forwards whileLoop through user semantics" {
    var result = try WhileCountdown.interpret(std.testing.allocator, WhileCountdown.Limits.testing, WhileLoopCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.while_loop_count);
    try result.graph.verify();

    var input = [_]i32{ 0, 1, 4, 5 };
    var output = @as([4]i32, @splat(0));
    try result.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, &.{ 0, 1, 10, 15 }, output[0..]);
}

test "kernel Program transform rewrites multidimensional indexed stores" {
    var normal = try MatrixCopy.interpret(std.testing.allocator, MatrixCopy.Limits.testing, IndexedStoreCounter{});
    defer normal.deinit();

    try std.testing.expectEqual(@as(usize, 1), normal.store_index_count);
    try std.testing.expectEqual(@as(usize, 0), normal.store_count);
    try normal.graph.verify();

    var input = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var output = @as([6]i32, @splat(0));
    try normal.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, input[0..], output[0..]);

    var transformed = try TransposedMatrixStores.interpret(std.testing.allocator, TransposedMatrixStores.Limits.testing, IndexedStoreCounter{});
    defer transformed.deinit();

    try std.testing.expectEqual(@as(usize, 0), transformed.store_index_count);
    try std.testing.expectEqual(@as(usize, 1), transformed.store_count);
    try std.testing.expectEqual(@as(usize, 2), transformed.mul_count);
    try std.testing.expectEqual(@as(usize, 2), transformed.add_count);
    try transformed.graph.verify();

    output = @as([6]i32, @splat(0));
    try transformed.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, &.{ 1, 4, 2, 5, 3, 6 }, output[0..]);
}

test "kernel Program transform can delay indexed stores inside multidimensional guards" {
    var single = try DelayedTransposedMatrixStores.interpret(std.testing.allocator, DelayedTransposedMatrixStores.Limits.testing, IndexedStoreCounter{});
    defer single.deinit();

    try std.testing.expectEqual(@as(usize, 0), single.store_index_count);
    try std.testing.expectEqual(@as(usize, 1), single.store_count);
    try std.testing.expectEqual(@as(usize, 2), single.mul_count);
    try std.testing.expectEqual(@as(usize, 2), single.add_count);
    try single.graph.verify();

    var input = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var output = @as([6]i32, @splat(0));
    try single.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, input[0..], output[0..]);

    var paired = try DelayedTransposedPairedStores.interpret(std.testing.allocator, DelayedTransposedPairedStores.Limits.testing, IndexedStoreCounter{});
    defer paired.deinit();

    try std.testing.expectEqual(@as(usize, 0), paired.store_index_count);
    try std.testing.expectEqual(@as(usize, 2), paired.store_count);
    try std.testing.expectEqual(@as(usize, 3), paired.mul_count);
    try std.testing.expectEqual(@as(usize, 3), paired.add_count);
    try paired.graph.verify();

    output = @as([6]i32, @splat(0));
    var audit = @as([6]i32, @splat(0));
    try paired.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
        kernel.argumentBuffer(i32, audit[0..]),
    });
    try std.testing.expectEqualSlices(i32, &.{ 1, 4, 2, 5, 3, 6 }, output[0..]);
    try std.testing.expectEqualSlices(i32, input[0..], audit[0..]);
}

test "kernel Program transform can delay indexed stores inside conditional guards" {
    var transformed = try ShiftedGuardedPairStores.interpret(std.testing.allocator, ShiftedGuardedPairStores.Limits.testing, IndexedStoreCounter{});
    defer transformed.deinit();

    try std.testing.expectEqual(@as(usize, 0), transformed.store_index_count);
    try std.testing.expectEqual(@as(usize, 2), transformed.store_count);
    try std.testing.expectEqual(@as(usize, 0), transformed.mul_count);
    try std.testing.expectEqual(@as(usize, 1), transformed.add_count);
    try transformed.graph.verify();

    var input = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var output = @as([6]i32, @splat(0));
    var audit = @as([6]i32, @splat(0));
    try transformed.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
        kernel.argumentBuffer(i32, audit[0..]),
    });
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 1, 2, 3, 4 }, output[0..]);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 0, 0 }, audit[0..]);
}

test "kernel Program exposes one dimensional guard body semantics" {
    var result = try InterpretedScale.interpret(std.testing.allocator, InterpretedScale.Limits.testing, GuardBodyCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.guard1d_count);
    try result.graph.verify();
}

test "kernel Program transform can delay indexed stores inside three dimensional guards" {
    var transformed = try DelayedSwappedVolumeStores.interpret(std.testing.allocator, DelayedSwappedVolumeStores.Limits.testing, IndexedStoreCounter{});
    defer transformed.deinit();

    try std.testing.expectEqual(@as(usize, 0), transformed.store_index_count);
    try std.testing.expectEqual(@as(usize, 2), transformed.store_count);
    try std.testing.expectEqual(@as(usize, 6), transformed.mul_count);
    try std.testing.expectEqual(@as(usize, 6), transformed.add_count);
    try transformed.graph.verify();

    var input = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var output = @as([8]i32, @splat(0));
    var audit = @as([8]i32, @splat(0));
    try transformed.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
        kernel.argumentBuffer(i32, audit[0..]),
    });
    try std.testing.expectEqualSlices(i32, &.{ 1, 5, 3, 7, 2, 6, 4, 8 }, output[0..]);
    try std.testing.expectEqualSlices(i32, input[0..], audit[0..]);
}

const FinishCounter = struct {
    finish_count: usize = 0,

    pub const Result = struct {
        inner: ArithmeticCounter.Result,
        finish_count: usize,

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
            self.* = undefined;
        }
    };

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        self.finish_count += 1;
        return .{
            .inner = try ctx.default(),
            .finish_count = self.finish_count,
        };
    }
};

const IndexedFinishCounter = struct {
    finish_count: usize = 0,

    pub const Result = struct {
        inner: IndexedStoreCounter.Result,
        finish_count: usize,

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
            self.* = undefined;
        }
    };

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        self.finish_count += 1;
        return .{
            .inner = try ctx.default(),
            .finish_count = self.finish_count,
        };
    }
};

test "kernel Program stacks user build semantics" {
    var result = try InterpretedScale.interpret(
        std.testing.allocator,
        InterpretedScale.Limits.testing,
        kernel.interpret.stack(.{
            kernel.interpret.with(FinishCounter{}),
            kernel.interpret.with(ArithmeticCounter{}),
        }),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.finish_count);
    try std.testing.expectEqual(@as(usize, 1), result.inner.mul_count);
    try std.testing.expectEqual(@as(usize, 1), result.inner.add_count);
    try std.testing.expectEqual(@as(usize, 1), result.inner.store_count);
    try result.inner.graph.verify();
}

test "kernel Program binds unhandled high level operations through transparent semantics" {
    var result = try MatrixCopy.interpret(
        std.testing.allocator,
        MatrixCopy.Limits.testing,
        kernel.interpret.stack(.{
            kernel.interpret.bind(IndexedFinishCounter{}),
            kernel.interpret.with(IndexedStoreCounter{}),
        }),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.finish_count);
    try std.testing.expectEqual(@as(usize, 1), result.inner.store_index_count);
    try std.testing.expectEqual(@as(usize, 0), result.inner.store_count);
    try result.inner.graph.verify();

    var input = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var output = @as([6]i32, @splat(0));
    try result.inner.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, input[0..], output[0..]);
}

test "kernel Program transform returns another composable Program" {
    var result = try TransformedScale.interpret(std.testing.allocator, TransformedScale.Limits.testing, ArithmeticCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.mul_count);
    try std.testing.expectEqual(@as(usize, 0), result.add_count);
    try std.testing.expectEqual(@as(usize, 1), result.store_count);
    try result.graph.verify();

    var graph = try TransformedScale.interpret(std.testing.allocator, TransformedScale.Limits.testing, kernel.interpret.graph());
    defer graph.deinit();
    try graph.verify();

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try TransformedScale.runCpu(std.testing.allocator, TransformedScale.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, &.{ 2.5, -5.0, 8.75, 10.0, -0.625 }, output[0..]);
}

test "kernel Program transform accepts explicit interpreter specs" {
    var result = try AdditiveScale.interpret(std.testing.allocator, AdditiveScale.Limits.testing, ArithmeticCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.mul_count);
    try std.testing.expectEqual(@as(usize, 2), result.add_count);
    try std.testing.expectEqual(@as(usize, 1), result.store_count);
    try result.graph.verify();

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try AdditiveScale.runCpu(std.testing.allocator, AdditiveScale.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, &.{ 4.5, 1.5, 7.0, 7.5, 3.25 }, output[0..]);
}

test "kernel Program transforms compose before later interpretation" {
    var result = try TwiceTransformedScale.interpret(std.testing.allocator, TwiceTransformedScale.Limits.testing, ArithmeticCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.mul_count);
    try std.testing.expectEqual(@as(usize, 0), result.add_count);
    try std.testing.expectEqual(@as(usize, 1), result.store_count);
    try result.graph.verify();

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try TwiceTransformedScale.runCpu(std.testing.allocator, TwiceTransformedScale.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, input[0..], output[0..]);
}

test "kernel Program analysis view derives transforms from whole-program semantics" {
    var mul_analysis = try AddBeforeMulAnalysis.interpret(std.testing.allocator, AddBeforeMulAnalysis.Limits.testing);
    defer mul_analysis.deinit();
    try std.testing.expect(mul_analysis.has_mul);
    try mul_analysis.graph.verify();

    var add_only_analysis = try AddOnlyAnalysis.interpret(std.testing.allocator, AddOnlyAnalysis.Limits.testing);
    defer add_only_analysis.deinit();
    try std.testing.expect(!add_only_analysis.has_mul);
    try add_only_analysis.graph.verify();

    var transformed = try DropAddAfterMulAnalysis.interpret(std.testing.allocator, DropAddAfterMulAnalysis.Limits.testing, ArithmeticCounter{});
    defer transformed.deinit();

    try std.testing.expectEqual(@as(usize, 1), transformed.mul_count);
    try std.testing.expectEqual(@as(usize, 0), transformed.add_count);
    try std.testing.expectEqual(@as(usize, 1), transformed.store_count);
    try transformed.graph.verify();

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try DropAddAfterMulAnalysis.runCpu(std.testing.allocator, DropAddAfterMulAnalysis.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, &.{ 2.5, -5.0, 8.75, 10.0, -0.625 }, output[0..]);

    var kept = try KeepAddAfterMulAnalysis.interpret(std.testing.allocator, KeepAddAfterMulAnalysis.Limits.testing, ArithmeticCounter{});
    defer kept.deinit();

    try std.testing.expectEqual(@as(usize, 0), kept.mul_count);
    try std.testing.expectEqual(@as(usize, 1), kept.add_count);
    try std.testing.expectEqual(@as(usize, 1), kept.store_count);
    try kept.graph.verify();

    output = [_]f32{ 0, 0, 0, 0, 0 };
    try KeepAddAfterMulAnalysis.runCpu(std.testing.allocator, KeepAddAfterMulAnalysis.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, &.{ 3.5, 0.5, 6.0, 6.5, 2.25 }, output[0..]);

    var composed = try DropMulAfterAnalyzedDropAdd.interpret(std.testing.allocator, DropMulAfterAnalyzedDropAdd.Limits.testing, ArithmeticCounter{});
    defer composed.deinit();

    try std.testing.expectEqual(@as(usize, 0), composed.mul_count);
    try std.testing.expectEqual(@as(usize, 0), composed.add_count);
    try std.testing.expectEqual(@as(usize, 1), composed.store_count);
    try composed.graph.verify();

    output = [_]f32{ 0, 0, 0, 0, 0 };
    try DropMulAfterAnalyzedDropAdd.runCpu(std.testing.allocator, DropMulAfterAnalyzedDropAdd.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, input[0..], output[0..]);

    var analyzed_after_transform = try AnalyzeAfterDroppedMul.interpret(std.testing.allocator, AnalyzeAfterDroppedMul.Limits.testing, ArithmeticCounter{});
    defer analyzed_after_transform.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed_after_transform.mul_count);
    try std.testing.expectEqual(@as(usize, 1), analyzed_after_transform.add_count);
    try std.testing.expectEqual(@as(usize, 1), analyzed_after_transform.store_count);
    try analyzed_after_transform.graph.verify();

    output = [_]f32{ 0, 0, 0, 0, 0 };
    try AnalyzeAfterDroppedMul.runCpu(std.testing.allocator, AnalyzeAfterDroppedMul.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, &.{ 2.0, -1.0, 4.5, 5.0, 0.75 }, output[0..]);

    var chained = try DropMulAfterAnalyzedAddRemoval.interpret(std.testing.allocator, DropMulAfterAnalyzedAddRemoval.Limits.testing, ArithmeticCounter{});
    defer chained.deinit();

    try std.testing.expectEqual(@as(usize, 0), chained.mul_count);
    try std.testing.expectEqual(@as(usize, 0), chained.add_count);
    try std.testing.expectEqual(@as(usize, 1), chained.store_count);
    try chained.graph.verify();

    output = [_]f32{ 0, 0, 0, 0, 0 };
    try DropMulAfterAnalyzedAddRemoval.runCpu(std.testing.allocator, DropMulAfterAnalyzedAddRemoval.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, input[0..], output[0..]);

    var borrowed = try DropMulWithBorrowedAnalysisFlags.interpret(std.testing.allocator, DropMulWithBorrowedAnalysisFlags.Limits.testing, ArithmeticCounter{});
    defer borrowed.deinit();

    try std.testing.expectEqual(@as(usize, 0), borrowed.mul_count);
    try std.testing.expectEqual(@as(usize, 1), borrowed.add_count);
    try std.testing.expectEqual(@as(usize, 1), borrowed.store_count);
    try borrowed.graph.verify();

    output = [_]f32{ 0, 0, 0, 0, 0 };
    try DropMulWithBorrowedAnalysisFlags.runCpu(std.testing.allocator, DropMulWithBorrowedAnalysisFlags.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.5),
    });

    try std.testing.expectEqualSlices(f32, &.{ 2.0, -1.0, 4.5, 5.0, 0.75 }, output[0..]);
}

test "kernel Program transform can validate a whole build in finish" {
    var graph = try StoreCheckedScale.build(std.testing.allocator, StoreCheckedScale.Limits.testing);
    defer graph.deinit();
    try graph.verify();

    try std.testing.expectError(error.KernelProgramRequiresStore, StoreCheckedNoStore.build(std.testing.allocator, StoreCheckedNoStore.Limits.testing));
}

fn positional_copy_each(inner: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const value = try inner.load(ctx.src, try index.linear(inner));
    try inner.store(value, ctx.dst, try index.linear(inner));
}

fn positionalBody(k: anytype, args: []const kernel.Value) !void {
    _ = try k.forEach1D(
        "i",
        4,
        4,
        .{ .src = args[0], .dst = args[1] },
        positional_copy_each,
    );
}

const PositionalCopy = Program(.{
    .name = "kernel_dsl_positional_copy_i32",
    .parameters = .{
        kernel.dynamicBuffer(.i32),
        kernel.dynamicBuffer(.i32),
    },
    .body = positionalBody,
});

test "kernel Program still accepts positional parameters" {
    try std.testing.expectEqual(@as(usize, 2), PositionalCopy.schema().len);
    var graph = try PositionalCopy.build(std.testing.allocator, PositionalCopy.Limits.testing);
    defer graph.deinit();
    try graph.verify();
}

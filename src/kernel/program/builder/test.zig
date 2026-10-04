const std = @import("std");
const testing = std.testing;
const choir = @import("choir");

const program_builder = @import("../root.zig");
const kernel = @import("../../root.zig");
const builder = kernel.builder;
const oracle = kernel.oracle;
const plan = kernel.plan;

const Builder = program_builder.Builder;
const BufferView = program_builder.BufferView;
const Index1D = program_builder.Index1D;
const VectorIndex1D = program_builder.VectorIndex1D;
const Index2D = program_builder.Index2D;
const Index3D = program_builder.Index3D;
const Program = program_builder.Program;
const TypedValue = program_builder.TypedValue;
const define = program_builder.define;
const defineWithDiagnostic = program_builder.defineWithDiagnostic;
const domainAxis = program_builder.domainAxis;

const domain_tests = struct {
    const GuardCopyContext = struct {
        src: builder.Value,
        dst: builder.Value,
        index: Index1D,
    };

    const CopyContext = struct {
        src: builder.Value,
        dst: builder.Value,
    };

    const PacketContext = struct {
        dst: builder.Value,
    };

    const TypedPacketContext = struct {
        src: BufferView(.f32),
        dst: BufferView(.f32),
    };

    const TypedCopyContext = struct {
        src: BufferView(.i32),
        dst: BufferView(.i32),
    };

    fn guard_copy_body(k: *Builder, ctx: GuardCopyContext) !void {
        const value = try k.load(ctx.src, ctx.index.index);
        try k.store(value, ctx.dst, ctx.index.index);
    }

    fn copy_1d_body(k: *Builder, index: Index1D, ctx: CopyContext) !void {
        const value = try k.loadIndex(ctx.src, index);
        try k.storeIndex(value, ctx.dst, index);
    }

    fn packet_body(k: *Builder, index: VectorIndex1D, ctx: PacketContext) !void {
        const value = try k.cast(index.packet, .i32);
        try k.store(value, ctx.dst, index.packet);
    }

    fn typed_packet_body(k: *Builder, index: VectorIndex1D, ctx: TypedPacketContext) !void {
        const value = try ctx.src.loadVector(k, index, index.width);
        const doubled = try k.add(value, value);
        try ctx.dst.storeVector(k, doubled, index);
    }

    fn typed_copy_body(k: *Builder, index: Index1D, ctx: TypedCopyContext) !void {
        const value = try ctx.src.load(k, index);
        try ctx.dst.store(k, value, index);
    }

    fn copy_2d_body(k: *Builder, index: Index2D, ctx: CopyContext) !void {
        const value = try k.loadIndex(ctx.src, index);
        try k.storeIndex(value, ctx.dst, index);
    }

    fn copy_3d_body(k: *Builder, index: Index3D, ctx: CopyContext) !void {
        const value = try k.loadIndex(ctx.src, index);
        try k.storeIndex(value, ctx.dst, index);
    }

    test "ProgramBuilder maps non-divisible 1D domains with an explicit tail guard" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "copy_guarded_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const index = try b.index1D("i", 5, 4);
        var guard = try b.guardIndex(index);

        const src = b.argument(0);
        const dst = b.argument(1);
        const value = try b.load(src, index.index);
        try b.store(value, dst, index.index);
        try guard.leave();
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 2), launch.grid[0]);
        try testing.expectEqual(@as(u32, 4), launch.block[0]);

        var input = [_]i32{ 2, 4, 6, 8, 10 };
        var output = [_]i32{ 0, 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, input[0..], output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder scopes arbitrary guards with callback syntax" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "copy_guard_do_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const index = try b.index1D("i", 5, 4);
        const in_bounds = try b.compare(.lt, index.index, index.bound);

        const context: GuardCopyContext = .{
            .src = b.argument(0),
            .dst = b.argument(1),
            .index = index,
        };

        try b.guardDo(in_bounds, context, guard_copy_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 8, 6, 7, 5, 3 };
        var output = [_]i32{ 0, 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, input[0..], output[0..]);
    }

    test "ProgramBuilder scopes guarded 1D bodies with callback syntax" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "copy_for_each_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const context: CopyContext = .{
            .src = b.argument(0),
            .dst = b.argument(1),
        };

        _ = try b.forEach1D("i", 5, 4, context, copy_1d_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 2), launch.grid[0]);
        try testing.expectEqual(@as(u32, 4), launch.block[0]);

        var input = [_]i32{ 3, 1, 4, 1, 5 };
        var output = [_]i32{ 0, 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, input[0..], output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder maps vectorized 1D domains as guarded packets" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "packet_for_each_i32",
            &.{
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: PacketContext = .{
            .dst = b.argument(0),
        };

        _ = try b.forEachVector1D("i", 12, 4, 2, context, packet_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 2), launch.grid[0]);
        try testing.expectEqual(@as(u32, 2), launch.block[0]);

        var snapshot = try program.scheduleSnapshot(testing.allocator);
        defer snapshot.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), snapshot.allAxes().len);
        try testing.expectEqual(@as(?u32, 4), snapshot.allAxes()[1].vector_width);

        var output = [_]i32{ 99, 99, 99, 99 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2, 99 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder rejects invalid vectorized 1D domains" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "bad_packet_for_each_i32",
            &.{
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        try testing.expectError(error.InvalidFactor, b.vectorIndex1D("i", 12, 0, 2));
        try testing.expectError(error.InvalidFactor, b.vectorIndex1D("i", 12, 4, 0));
        try testing.expectError(error.ExtentNotDivisible, b.vectorIndex1D("i", 10, 4, 2));
    }

    test "ProgramBuilder typed buffer views expose vector packet memory" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_packet_memory_f32",
            &.{
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: TypedPacketContext = .{
            .src = b.bufferArgument(.f32, 0),
            .dst = b.bufferArgument(.f32, 1),
        };

        _ = try b.forEachVector1D("i", 8, 4, 2, context, typed_packet_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 2), launch.block[0]);

        var snapshot = try program.scheduleSnapshot(testing.allocator);
        defer snapshot.deinit(testing.allocator);
        try testing.expectEqual(@as(?u32, 4), snapshot.allAxes()[0].vector_width);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed buffer views wrap Choir memrefs" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_buffer_copy_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: TypedCopyContext = .{
            .src = b.bufferArgument(.i32, 0),
            .dst = b.bufferArgument(.i32, 1),
        };

        _ = try b.forEach1D("i", 5, 4, context, typed_copy_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 5, 8, 13, 21, 34 };
        var output = [_]i32{ 0, 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, input[0..], output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder maps guarded 2D domains with callback syntax" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "copy_for_each_2d_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const width: u64 = 5;
        const height: u64 = 3;
        const context: CopyContext = .{
            .src = b.argument(0),
            .dst = b.argument(1),
        };

        _ = try b.forEach2D(.{
            .x = domainAxis("x", width, 4),
            .y = domainAxis("y", height, 2),
        }, context, copy_2d_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 2), launch.grid[0]);
        try testing.expectEqual(@as(u32, 2), launch.grid[1]);
        try testing.expectEqual(@as(u32, 4), launch.block[0]);
        try testing.expectEqual(@as(u32, 2), launch.block[1]);

        var input = [_]i32{
            1,  2,  3,  4,  5,
            6,  7,  8,  9,  10,
            11, 12, 13, 14, 15,
        };
        var output = [_]i32{
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
        };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, input[0..], output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder maps guarded 3D domains with callback syntax" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "copy_for_each_3d_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const width: u64 = 3;
        const height: u64 = 2;
        const depth: u64 = 2;
        const context: CopyContext = .{
            .src = b.argument(0),
            .dst = b.argument(1),
        };

        _ = try b.forEach3D(.{
            .x = domainAxis("x", width, 2),
            .y = domainAxis("y", height, 2),
            .z = domainAxis("z", depth, 1),
        }, context, copy_3d_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 2), launch.grid[0]);
        try testing.expectEqual(@as(u32, 1), launch.grid[1]);
        try testing.expectEqual(@as(u32, 2), launch.grid[2]);
        try testing.expectEqual(@as(u32, 2), launch.block[0]);
        try testing.expectEqual(@as(u32, 2), launch.block[1]);
        try testing.expectEqual(@as(u32, 1), launch.block[2]);

        var input = [_]i32{
            1,  2,  3,
            4,  5,  6,
            7,  8,  9,
            10, 11, 12,
        };
        var output = [_]i32{
            0, 0, 0,
            0, 0, 0,
            0, 0, 0,
            0, 0, 0,
        };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, input[0..], output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }
};

const lifecycle_tests = struct {
    const DefineScaleContext = struct {
        extent: u64,
        threads: u32,
    };

    const DefineScaleEachContext = struct {
        src: builder.Value,
        dst: builder.Value,
        scale: builder.Value,
    };

    const CheckedCopyContext = struct {
        src: builder.Value,
        dst: builder.Value,
    };

    fn define_scale_each(k: *Builder, index: Index1D, ctx: DefineScaleEachContext) !void {
        const value = try k.load(ctx.src, index.index);
        const scaled = try k.mul(value, ctx.scale);
        try k.store(scaled, ctx.dst, index.index);
    }

    fn define_scale_body(k: *Builder, ctx: DefineScaleContext) !void {
        const src = k.argument(0);
        const dst = k.argument(1);
        const scale = k.argument(2);
        _ = try k.forEach1D("i", ctx.extent, ctx.threads, DefineScaleEachContext{
            .src = src,
            .dst = dst,
            .scale = scale,
        }, define_scale_each);
    }

    fn checked_plan_each(k: *Builder, index: Index1D, ctx: CheckedCopyContext) !void {
        const value = try k.load(ctx.src, index.index);
        try k.store(value, ctx.dst, index.index);
    }

    fn checked_plan_body(k: *Builder, _: void) !void {
        const context: CheckedCopyContext = .{
            .src = k.argument(0),
            .dst = k.argument(1),
        };
        _ = try k.forEach1D("i", 4, 4, context, checked_plan_each);
    }

    fn sentinel_probe_body(k: *Builder, _: void) !void {
        const dst = k.argument(0);
        const shared = try k.sharedBuffer(.f32, 1);
        const zero = try k.constantIndex(0);
        const value = try k.loadIndex(shared, zero);
        try k.storeIndex(value, dst, zero);
    }

    fn invalid_if_body(k: *Builder, _: void) !void {
        const zero = try k.constantFloat(.f32, 0.0);
        const pred = try k.compare(.gt, zero, zero);
        _ = try k.if_(pred, &.{zero.valueType()});
    }

    fn invalid_index_body(k: *Builder, _: void) !void {
        const dst = k.argument(0);
        const index = try k.constantIndex(4);
        const value = try k.constantInt(.i32, 7);
        try k.store(value, dst, index);
    }

    test "ProgramBuilder borrows its Choir context through Graph lifetime" {
        const allocator = testing.allocator;
        var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try choir.dialects.registerChoirDialect(&ctx);
        const operations = ctx.operationCount();

        var b = try Builder.initBorrowing(
            allocator,
            Builder.Limits.borrowed_testing,
            &ctx,
            "borrowed_program_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        errdefer b.deinit();
        const index = try b.globalId(.x);
        const value = try b.load(b.argument(0), index);
        try b.store(value, b.argument(1), index);
        try b.return_();

        var program = try b.finish();
        var program_live = true;
        errdefer if (program_live) program.deinit();
        try testing.expectEqual(&ctx, program.kernelModule().context);
        try testing.expectEqual(
            kernel.Capacity.ContextOwnership.borrowed,
            program.capacity.context_ownership,
        );
        try program.verify();
        program.deinit();
        program_live = false;

        try testing.expectEqual(operations, ctx.operationCount());
    }

    test "ProgramBuilder owns body schedule plan and CPU execution" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "copy_program_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const i = try b.axis("i", 4);
        try b.bind(i, .thread_x);

        const src = b.argument(0);
        const dst = b.argument(1);
        const index = try b.globalId(.x);
        const value = try b.load(src, index);
        try b.store(value, dst, index);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        try testing.expectEqual(
            kernel.Capacity.ContextOwnership.owned,
            program.capacity.context_ownership,
        );

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();

        try testing.expectEqual(@as(u32, 4), out.launch.block[0]);
        try program.checkPlan(testing.allocator, &out);

        var input = [_]i32{ 11, 13, 17, 19 };
        var output = [_]i32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, input[0..], output[0..]);
    }

    test "define packages callback bodies into runnable programs" {
        var program = try define(testing.allocator, Builder.Limits.testing, "define_scale_f32", &.{
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
            builder.scalar(.f32),
        }, DefineScaleContext{ .extent = 5, .threads = 4 }, define_scale_body);
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 2), launch.grid[0]);
        try testing.expectEqual(@as(u32, 4), launch.block[0]);

        var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
        var output = [_]f32{ 0, 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, input[0..]),
            oracle.argumentBuffer(f32, output[0..]),
            oracle.argumentF32(2.0),
        });

        try testing.expectEqualSlices(f32, &.{ 2.0, -4.0, 7.0, 8.0, -0.5 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try testing.expectEqual(
            try program.bodyFingerprint(testing.allocator),
            out.body_fingerprint,
        );
        try testing.expectEqual(program.scheduleFingerprint(), out.schedule_fingerprint);
        try program.checkPlan(testing.allocator, &out);
    }

    test "Program checked plans validate replayable identity" {
        var program = try define(testing.allocator, Builder.Limits.testing, "checked_plan_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        }, {}, checked_plan_body);
        defer program.deinit();

        var out = try program.createCheckedPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);

        var input = [_]i32{ 1, 2, 3, 4 };
        var output = [_]i32{ 0, 0, 0, 0 };
        try runPlanCpu(&out, testing.allocator, &program, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });
        try testing.expectEqualSlices(i32, input[0..], output[0..]);

        out.schedule_version += 1;
        try testing.expectError(
            error.ScheduleVersionMismatch,
            program.checkPlan(testing.allocator, &out),
        );
        out.schedule_version -= 1;
        out.body_fingerprint +%= 1;
        try testing.expectError(
            error.BodyFingerprintMismatch,
            program.checkPlan(testing.allocator, &out),
        );
    }

    fn runPlanCpu(
        authored_plan: *const plan.Plan,
        allocator: std.mem.Allocator,
        program: *Program,
        args: []const oracle.Argument,
    ) !void {
        try program.runCpuWithLaunch(allocator, args, authored_plan.launch);
    }

    test "Program oracle observes the sentinel through unseeded shared memory" {
        var program = try define(
            testing.allocator,
            Builder.Limits.testing,
            "shared_sentinel_probe",
            &.{
                builder.dynamicBuffer(.f32),
            },
            {},
            sentinel_probe_body,
        );
        defer program.deinit();

        var output = [_]f32{0};
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, output[0..]),
        });

        const fill: u8 = oracle.shared_alloc_sentinel;
        const word: u32 = @as(u32, fill) << 24 |
            @as(u32, fill) << 16 | @as(u32, fill) << 8 | @as(u32, fill);
        const expected: f32 = @bitCast(word);
        try testing.expectEqual(expected, output[0]);
    }

    test "defineWithDiagnostic reports Choir verifier failures" {
        var diagnostic: builder.VerificationDiagnostic = .{};
        try testing.expectError(
            error.VerificationFailed,
            defineWithDiagnostic(
                testing.allocator,
                Builder.Limits.testing,
                "define_bad_if",
                &.{},
                {},
                invalid_if_body,
                &diagnostic,
            ),
        );
        try testing.expect(diagnostic.hasText());
        try testing.expect(std.mem.indexOf(u8, diagnostic.text(), "accy/kernel/finish") != null);
        try testing.expect(std.mem.indexOf(u8, diagnostic.text(), "scf.if") != null);
    }

    test "Program runCpuWithDiagnostic reports CPU oracle failures" {
        var program = try define(testing.allocator, Builder.Limits.testing, "oracle_bad_index", &.{
            builder.dynamicBuffer(.i32),
        }, {}, invalid_index_body);
        defer program.deinit();

        var output = [_]i32{ 0, 0, 0, 0 };
        var diagnostic: oracle.ExecutionDiagnostic = .{};
        try testing.expectError(
            error.InvalidIndex,
            program.runCpuWithDiagnostic(testing.allocator, &.{
                oracle.argumentBuffer(i32, output[0..]),
            }, &diagnostic),
        );
        try testing.expect(diagnostic.hasText());
        try testing.expect(std.mem.indexOf(u8, diagnostic.text(), "accy/kernel/run") != null);
        try testing.expect(std.mem.indexOf(u8, diagnostic.text(), "InvalidIndex") != null);
        try testing.expect(std.mem.indexOf(u8, diagnostic.text(), "memref.store") != null);
    }
};

const sdf_tests = struct {
    const SdfContext = struct {
        dst: BufferView(.f32),
    };

    const VectorMathContext = struct {
        xs: BufferView(.f32),
        ys: BufferView(.f32),
        zs: BufferView(.f32),
        box_out: BufferView(.f32),
        len_out: BufferView(.f32),
    };

    const VectorUtilityContext = struct {
        xs: BufferView(.f32),
        ys: BufferView(.f32),
        zs: BufferView(.f32),
        scalar_out: BufferView(.f32),
        clamped2_out: BufferView(.f32),
        normalized3_out: BufferView(.f32),
        cross_out: BufferView(.f32),
    };

    fn sdf_cell_center_body(k: *Builder, index: Index3D, ctx: SdfContext) !void {
        const negative_one = try k.constantFloat(.f32, -1.0);
        const one = try k.constantFloat(.f32, 1.0);
        const half = try k.constantFloat(.f32, 0.5);
        const p = try index.cellCenter(k, .f32, k.splat3(negative_one), k.splat3(one));
        const sphere = try k.sub(try p.length(k), half);
        try ctx.dst.store(k, sphere, index);
    }

    fn typed_sdf_cell_center_body(k: *Builder, index: Index3D, ctx: SdfContext) !void {
        const p = try index.cellCenter(k, .f32, -1.0, 1.0);
        const sphere = try (try p.length(k)).sub(k, 0.5);
        try ctx.dst.store(k, sphere, index);
    }

    fn uniform_cell_center_body(k: *Builder, index: Index2D, ctx: SdfContext) !void {
        const p = try index.cellCenter(k, .f32, -1.0, 1.0);
        try ctx.dst.store(k, try p.length(k), index);
    }

    fn scalar_cell_center_body(k: *Builder, index: Index1D, ctx: SdfContext) !void {
        const p = try index.cellCenter(k, .f32, -1.0, 0.5);
        try ctx.dst.store(k, p, index);
    }

    fn vector_math_body(k: *Builder, index: Index1D, ctx: VectorMathContext) !void {
        const x = try ctx.xs.load(k, index);
        const y = try ctx.ys.load(k, index);
        const z = try ctx.zs.load(k, index);

        const p2 = try k.typedVec2(.f32, x, y);
        const q = try (try p2.abs(k)).sub(k, try k.typedVec2(.f32, 0.5, 0.25));
        const outside = try (try q.max(k, 0.0)).length(k);
        const q_max = try q.x.max(k, q.y);
        const inside = try q_max.min(k, 0.0);
        const box_sdf = try outside.add(k, inside);
        try ctx.box_out.store(k, box_sdf, index);

        const p3 = try k.typedVec3(.f32, x, y, z);
        const scaled = try p3.scale(k, 2.0);
        const len3 = try scaled.length(k);
        try ctx.len_out.store(k, len3, index);
    }

    fn vector_utility_body(k: *Builder, index: Index1D, ctx: VectorUtilityContext) !void {
        const x = try ctx.xs.load(k, index);
        const y = try ctx.ys.load(k, index);
        const z = try ctx.zs.load(k, index);

        try ctx.scalar_out.store(k, try x.clamp(k, -0.25, 0.75), index);

        const p2 = try k.typedVec2(.f32, x, y);
        const clamped2 = try (try p2.clamp(k, -0.5, 0.5)).div(k, 0.5);
        try ctx.clamped2_out.store(k, try clamped2.length(k), index);

        const p3 = try k.typedVec3(.f32, x, y, z);
        const normalized3 = try p3.normalize(k);
        try ctx.normalized3_out.store(k, try normalized3.length(k), index);

        const cross = try p3.cross(k, try k.typedVec3(.f32, 0.0, 1.0, 0.0));
        try ctx.cross_out.store(k, try cross.length(k), index);
    }

    fn box2Expected(x: f32, y: f32) f32 {
        const qx = @abs(x) - 0.5;
        const qy = @abs(y) - 0.25;
        const ox = @max(qx, 0.0);
        const oy = @max(qy, 0.0);
        const outside = @sqrt(ox * ox + oy * oy);
        const inside = @min(@max(qx, qy), 0.0);
        return outside + inside;
    }

    fn scaledLength3Expected(x: f32, y: f32, z: f32) f32 {
        const sx = x * 2.0;
        const sy = y * 2.0;
        const sz = z * 2.0;
        return @sqrt(sx * sx + sy * sy + sz * sz);
    }

    fn clampExpected(value: f32, lower: f32, upper: f32) f32 {
        return @min(@max(value, lower), upper);
    }

    fn clampedDiv2LengthExpected(x: f32, y: f32) f32 {
        const cx = clampExpected(x, -0.5, 0.5) / 0.5;
        const cy = clampExpected(y, -0.5, 0.5) / 0.5;
        return @sqrt(cx * cx + cy * cy);
    }

    fn crossYLengthExpected(x: f32, z: f32) f32 {
        return @sqrt(x * x + z * z);
    }

    test "ProgramBuilder maps SDF cell centers from 3D indices" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "sdf_cell_centers_f32",
            &.{
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: SdfContext = .{
            .dst = b.bufferArgument(.f32, 0),
        };

        _ = try b.forEach3D(.{
            .x = domainAxis("x", 2, 2),
            .y = domainAxis("y", 2, 1),
            .z = domainAxis("z", 2, 1),
        }, context, sdf_cell_center_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 1), launch.grid[0]);
        try testing.expectEqual(@as(u32, 2), launch.grid[1]);
        try testing.expectEqual(@as(u32, 2), launch.grid[2]);
        try testing.expectEqual(@as(u32, 2), launch.block[0]);
        try testing.expectEqual(@as(u32, 1), launch.block[1]);
        try testing.expectEqual(@as(u32, 1), launch.block[2]);

        var output = @as([8]f32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, output[0..]),
        });

        const expected = @sqrt(@as(f32, 0.75)) - 0.5;
        for (output) |actual| {
            try testing.expectApproxEqAbs(expected, actual, 0.0001);
        }

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed SDF cell centers stay in typed vector facade" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_sdf_cell_centers_f32",
            &.{
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: SdfContext = .{
            .dst = b.bufferArgument(.f32, 0),
        };

        _ = try b.forEach3D(.{
            .x = domainAxis("x", 2, 2),
            .y = domainAxis("y", 2, 1),
            .z = domainAxis("z", 2, 1),
        }, context, typed_sdf_cell_center_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var output = @as([8]f32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, output[0..]),
        });

        const expected = @sqrt(@as(f32, 0.75)) - 0.5;
        for (output) |actual| {
            try testing.expectApproxEqAbs(expected, actual, 0.0001);
        }

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder vector cell centers accept uniform literal coordinates" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_sdf_uniform_cell_centers_f32",
            &.{
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: SdfContext = .{
            .dst = b.bufferArgument(.f32, 0),
        };

        _ = try b.forEach2D(.{
            .x = domainAxis("x", 2, 2),
            .y = domainAxis("y", 2, 1),
        }, context, uniform_cell_center_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var output = [_]f32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, output[0..]),
        });

        const expected = @sqrt(@as(f32, 0.5));
        for (output) |actual| {
            try testing.expectApproxEqAbs(expected, actual, 0.0001);
        }

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder scalar cell centers accept literal coordinates" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_sdf_scalar_cell_centers_f32",
            &.{
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: SdfContext = .{
            .dst = b.bufferArgument(.f32, 0),
        };

        _ = try b.forEach1D("x", 4, 4, context, scalar_cell_center_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var output = [_]f32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, output[0..]),
        });

        try testing.expectApproxEqAbs(@as(f32, -0.75), output[0], 0.0001);
        try testing.expectApproxEqAbs(@as(f32, -0.25), output[1], 0.0001);
        try testing.expectApproxEqAbs(@as(f32, 0.25), output[2], 0.0001);
        try testing.expectApproxEqAbs(@as(f32, 0.75), output[3], 0.0001);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder composes typed SDF vector math helpers" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "sdf_vector_math_f32",
            &.{
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: VectorMathContext = .{
            .xs = b.bufferArgument(.f32, 0),
            .ys = b.bufferArgument(.f32, 1),
            .zs = b.bufferArgument(.f32, 2),
            .box_out = b.bufferArgument(.f32, 3),
            .len_out = b.bufferArgument(.f32, 4),
        };

        _ = try b.forEach1D("i", 4, 4, context, vector_math_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var xs = [_]f32{ -0.5, 0.0, 0.75, -1.0 };
        var ys = [_]f32{ 0.0, 0.5, -0.25, 1.0 };
        var zs = [_]f32{ 0.25, -0.5, 1.0, -1.5 };
        var box_out = [_]f32{ 0, 0, 0, 0 };
        var len_out = [_]f32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, xs[0..]),
            oracle.argumentBuffer(f32, ys[0..]),
            oracle.argumentBuffer(f32, zs[0..]),
            oracle.argumentBuffer(f32, box_out[0..]),
            oracle.argumentBuffer(f32, len_out[0..]),
        });

        for (xs, ys, zs, box_out, len_out) |x, y, z, actual_box, actual_len| {
            try testing.expectApproxEqAbs(box2Expected(x, y), actual_box, 0.0001);
            try testing.expectApproxEqAbs(scaledLength3Expected(x, y, z), actual_len, 0.0001);
        }

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed vectors expose SDF utility helpers" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "sdf_vector_utilities_f32",
            &.{
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: VectorUtilityContext = .{
            .xs = b.bufferArgument(.f32, 0),
            .ys = b.bufferArgument(.f32, 1),
            .zs = b.bufferArgument(.f32, 2),
            .scalar_out = b.bufferArgument(.f32, 3),
            .clamped2_out = b.bufferArgument(.f32, 4),
            .normalized3_out = b.bufferArgument(.f32, 5),
            .cross_out = b.bufferArgument(.f32, 6),
        };

        _ = try b.forEach1D("i", 4, 4, context, vector_utility_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var xs = [_]f32{ 3.0, -2.0, 0.25, -0.5 };
        var ys = [_]f32{ 4.0, 0.5, -1.5, 0.25 };
        var zs = [_]f32{ 0.5, 1.0, 2.0, -0.75 };
        var scalar_out = [_]f32{ 0, 0, 0, 0 };
        var clamped2_out = [_]f32{ 0, 0, 0, 0 };
        var normalized3_out = [_]f32{ 0, 0, 0, 0 };
        var cross_out = [_]f32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, xs[0..]),
            oracle.argumentBuffer(f32, ys[0..]),
            oracle.argumentBuffer(f32, zs[0..]),
            oracle.argumentBuffer(f32, scalar_out[0..]),
            oracle.argumentBuffer(f32, clamped2_out[0..]),
            oracle.argumentBuffer(f32, normalized3_out[0..]),
            oracle.argumentBuffer(f32, cross_out[0..]),
        });

        for (
            xs,
            ys,
            zs,
            scalar_out,
            clamped2_out,
            normalized3_out,
            cross_out,
        ) |x, y, z, actual_scalar, actual_clamped2, actual_normalized3, actual_cross| {
            try testing.expectApproxEqAbs(clampExpected(x, -0.25, 0.75), actual_scalar, 0.0001);
            try testing.expectApproxEqAbs(clampedDiv2LengthExpected(x, y), actual_clamped2, 0.0001);
            try testing.expectApproxEqAbs(@as(f32, 1.0), actual_normalized3, 0.0001);
            try testing.expectApproxEqAbs(crossYLengthExpected(x, z), actual_cross, 0.0001);
        }

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }
};

const typed_tests = struct {
    fn sdfMathExpected(x: f32) f32 {
        const wave_input = x * 0.25;
        const wave = @sin(wave_input) + @cos(wave_input) + std.math.tan(wave_input);
        const log_exp = @log(@exp(wave_input));
        const smooth = std.math.tanh(wave_input);
        const powered = std.math.pow(f32, @abs(x) + 1.0, 2.0);
        const distance = @sqrt(x * x);
        const fused = @mulAdd(f32, powered, 0.5, distance);
        return fused + wave + log_exp + smooth;
    }

    fn shlI32Expected(value: i32, shift: u5) i32 {
        return @bitCast(@as(u32, @bitCast(value)) << shift);
    }

    fn ushrI32Expected(value: i32, shift: u5) i32 {
        return @bitCast(@as(u32, @bitCast(value)) >> shift);
    }

    const SdfMathContext = struct {
        src: BufferView(.f32),
        dst: BufferView(.f32),
    };

    const PredicateContext = struct {
        src: BufferView(.f32),
        dst: BufferView(.f32),
    };

    const PredicateStoreContext = struct {
        dst: BufferView(.f32),
        value: TypedValue(.f32),
        index: Index1D,
    };

    const PredicateLogicContext = struct {
        xs: BufferView(.f32),
        ys: BufferView(.f32),
        union_out: BufferView(.f32),
        xor_out: BufferView(.f32),
        neither_out: BufferView(.f32),
    };

    const MaskContext = struct {
        src: BufferView(.i32),
        formula_out: BufferView(.i32),
        not_out: BufferView(.i32),
    };

    const BitsContext = struct {
        src: BufferView(.i32),
        shl_out: BufferView(.i32),
        shr_out: BufferView(.i32),
        ushr_out: BufferView(.i32),
        bitcast_out: BufferView(.f32),
        roundtrip_out: BufferView(.i32),
    };

    const FoldProgramContext = struct {
        src: BufferView(.i32),
        dst: BufferView(.i32),
    };

    const TypedFoldContext = struct {
        x: TypedValue(.i32),
    };

    const WhileProgramContext = struct {
        src: BufferView(.i32),
        dst: BufferView(.i32),
    };

    const WhileCarry = struct {
        remaining: TypedValue(.i32),
        total: TypedValue(.i32),
    };

    const IndexContext = struct {
        dst: BufferView(.i32),
    };

    const IndexFoldContext = struct {
        linear: TypedValue(.i32),
    };

    const LoopProgramContext = struct {
        dst: BufferView(.i32),
    };

    const LoopContext = struct {
        dst: BufferView(.i32),
        index: Index1D,
        linear: TypedValue(.i32),
    };

    fn sdf_math_body(k: *Builder, index: Index1D, ctx: SdfMathContext) !void {
        const x = try ctx.src.load(k, index);

        const wave_input = try x.mul(k, 0.25);
        const sin_x = try wave_input.sin(k);
        const cos_x = try wave_input.cos(k);
        const tan_x = try wave_input.tan(k);
        const wave_a = try sin_x.add(k, cos_x);
        const wave = try wave_a.add(k, tan_x);

        const exp_x = try wave_input.exp(k);
        const log_exp = try exp_x.log(k);
        const smooth = try wave_input.tanh(k);

        const abs_x = try x.abs(k);
        const base = try abs_x.add(k, 1.0);
        const powered = try base.pow(k, 2.0);
        const square = try x.mul(k, x);
        const distance = try square.sqrt(k);
        const fused = try powered.fma(k, 0.5, distance);

        const left = try fused.add(k, wave);
        const right = try log_exp.add(k, smooth);
        const result = try left.add(k, right);
        try ctx.dst.store(k, result, index);
    }

    fn predicate_store(inner: *Builder, ctx: PredicateStoreContext) !void {
        try ctx.dst.store(inner, ctx.value, ctx.index);
    }

    fn predicate_body(k: *Builder, index: Index1D, ctx: PredicateContext) !void {
        const x = try ctx.src.load(k, index);
        const is_negative = try x.compare(k, .lt, 0.0);
        const abs_x = try is_negative.select(k, .f32, try x.neg(k), x);
        const should_store = try abs_x.compare(k, .gt, 1.0);

        try k.guardDo(should_store, PredicateStoreContext{
            .dst = ctx.dst,
            .value = abs_x,
            .index = index,
        }, predicate_store);
    }

    fn predicate_logic_body(k: *Builder, index: Index1D, ctx: PredicateLogicContext) !void {
        const x = try ctx.xs.load(k, index);
        const y = try ctx.ys.load(k, index);

        const x_lower = try x.compare(k, .ge, -0.5);
        const x_upper = try x.compare(k, .le, 0.5);
        const y_lower = try y.compare(k, .ge, -0.5);
        const y_upper = try y.compare(k, .le, 0.5);
        const x_inside = try x_lower.and_(k, x_upper);
        const y_inside = try y_lower.and_(k, y_upper);
        const union_predicate = try x_inside.or_(k, y_inside);
        const xor_predicate = try x_inside.xor(k, y_inside);
        const neither_predicate = try (try x_inside.not(k)).and_(k, try y_inside.not(k));

        try ctx.union_out.store(
            k,
            try union_predicate.select(k, .f32, try x.add(k, y), -9.0),
            index,
        );
        try ctx.xor_out.store(k, try xor_predicate.select(k, .f32, 1.0, 0.0), index);
        try ctx.neither_out.store(k, try neither_predicate.select(k, .f32, -1.0, 1.0), index);
    }

    fn mask_body(k: *Builder, index: Index1D, ctx: MaskContext) !void {
        const value = try ctx.src.load(k, index);
        const low = try value.and_(k, 0x0f);
        const tagged = try low.or_(k, 0x10);
        const formula = try tagged.xor(k, 0x03);
        try ctx.formula_out.store(k, formula, index);
        try ctx.not_out.store(k, try value.not(k), index);
    }

    fn bits_body(k: *Builder, index: Index1D, ctx: BitsContext) !void {
        const value = try ctx.src.load(k, index);
        try ctx.shl_out.store(k, try value.shl(k, 1), index);
        try ctx.shr_out.store(k, try value.shr(k, 1), index);
        try ctx.ushr_out.store(k, try value.ushr(k, 1), index);
        const as_float = try value.bitcast(k, .f32);
        try ctx.bitcast_out.store(k, as_float, index);
        try ctx.roundtrip_out.store(k, try as_float.bitcast(k, .i32), index);
    }

    fn typed_fold_step(
        inner: *Builder,
        iteration: TypedValue(.i32),
        acc: TypedValue(.i32),
        ctx: TypedFoldContext,
    ) !TypedValue(.i32) {
        const term = try ctx.x.add(inner, iteration);
        return acc.add(inner, term);
    }

    fn typed_fold_body(k: *Builder, index: Index1D, ctx: FoldProgramContext) !void {
        const x = try ctx.src.load(k, index);
        const zero = try k.constantValue(.i32, 0);
        const sum = try k.foldRange(0, 3, 1, zero, TypedFoldContext{ .x = x }, typed_fold_step);
        try ctx.dst.store(k, sum, index);
    }

    fn while_keep_going(inner: *Builder, carry: WhileCarry, _: void) !TypedValue(.i1) {
        return carry.remaining.compare(inner, .gt, 0);
    }

    fn while_step(inner: *Builder, carry: WhileCarry, _: void) !WhileCarry {
        return .{
            .remaining = try carry.remaining.sub(inner, 1),
            .total = try carry.total.add(inner, carry.remaining),
        };
    }

    fn while_body(k: *Builder, index: Index1D, ctx: WhileProgramContext) !void {
        const start = try ctx.src.load(k, index);
        const zero = try k.constantValue(.i32, 0);
        const walked = try k.whileLoop(WhileCarry{
            .remaining = start,
            .total = zero,
        }, {}, while_keep_going, while_step);
        try ctx.dst.store(k, walked.total, index);
    }

    fn index_fold_step(
        inner: *Builder,
        iteration: TypedValue(.i32),
        acc: TypedValue(.i32),
        ctx: IndexFoldContext,
    ) !TypedValue(.i32) {
        const term = try ctx.linear.add(inner, iteration);
        return acc.add(inner, term);
    }

    fn index_fold_body(k: *Builder, index: Index1D, ctx: IndexContext) !void {
        const linear = try k.linearIndexValue(index, .i32);
        const zero = try k.constantValue(.i32, 0);
        const sum = try k.foldRange(
            0,
            3,
            1,
            zero,
            IndexFoldContext{ .linear = linear },
            index_fold_step,
        );
        try ctx.dst.store(k, sum, index);
    }

    fn side_effect_loop_step(
        inner: *Builder,
        iteration: TypedValue(.i32),
        ctx: LoopContext,
    ) !void {
        const value = try ctx.linear.add(inner, iteration);
        try ctx.dst.store(inner, value, ctx.index);
    }

    fn side_effect_loop_body(k: *Builder, index: Index1D, ctx: LoopProgramContext) !void {
        const linear = try index.linearValue(k, .i32);
        _ = try k.forRangeValueDo(.i32, 0, 3, 1, LoopContext{
            .dst = ctx.dst,
            .index = index,
            .linear = linear,
        }, side_effect_loop_step);
    }

    test "ProgramBuilder typed scalar values expose SDF-style Choir arith ops" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "sdf_math_f32", &.{
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
        });
        defer b.deinit();

        const context: SdfMathContext = .{
            .src = b.bufferArgument(.f32, 0),
            .dst = b.bufferArgument(.f32, 1),
        };

        _ = try b.forEach1D("i", 4, 4, context, sdf_math_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]f32{ -0.5, 0.0, 0.25, 0.75 };
        var output = [_]f32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, input[0..]),
            oracle.argumentBuffer(f32, output[0..]),
        });

        for (input, output) |x, actual| {
            try testing.expectApproxEqAbs(sdfMathExpected(x), actual, 0.0001);
        }

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed predicates drive Choir guards and selects" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_predicate_guard_f32",
            &.{
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: PredicateContext = .{
            .src = b.bufferArgument(.f32, 0),
            .dst = b.bufferArgument(.f32, 1),
        };

        _ = try b.forEach1D("i", 4, 4, context, predicate_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]f32{ -2.0, -0.5, 1.25, 3.0 };
        var output = [_]f32{ -9.0, -9.0, -9.0, -9.0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, input[0..]),
            oracle.argumentBuffer(f32, output[0..]),
        });

        try testing.expectEqualSlices(f32, &.{ 2.0, -9.0, 1.25, 3.0 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed predicates compose boolean logic without raw Choir handles" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_predicate_logic_f32",
            &.{
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const context: PredicateLogicContext = .{
            .xs = b.bufferArgument(.f32, 0),
            .ys = b.bufferArgument(.f32, 1),
            .union_out = b.bufferArgument(.f32, 2),
            .xor_out = b.bufferArgument(.f32, 3),
            .neither_out = b.bufferArgument(.f32, 4),
        };

        _ = try b.forEach1D("i", 4, 4, context, predicate_logic_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var xs = [_]f32{ -0.25, 2.0, 0.25, 2.0 };
        var ys = [_]f32{ -0.25, 0.25, 2.0, 2.0 };
        var union_out = [_]f32{ 0, 0, 0, 0 };
        var xor_out = [_]f32{ 0, 0, 0, 0 };
        var neither_out = [_]f32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, xs[0..]),
            oracle.argumentBuffer(f32, ys[0..]),
            oracle.argumentBuffer(f32, union_out[0..]),
            oracle.argumentBuffer(f32, xor_out[0..]),
            oracle.argumentBuffer(f32, neither_out[0..]),
        });

        try testing.expectEqualSlices(f32, &.{ -0.5, 2.25, 2.25, -9.0 }, union_out[0..]);
        try testing.expectEqualSlices(f32, &.{ 0.0, 1.0, 1.0, 0.0 }, xor_out[0..]);
        try testing.expectEqualSlices(f32, &.{ 1.0, 1.0, 1.0, -1.0 }, neither_out[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed integer masks expose Choir bitwise ops" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_mask_logic_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: MaskContext = .{
            .src = b.bufferArgument(.i32, 0),
            .formula_out = b.bufferArgument(.i32, 1),
            .not_out = b.bufferArgument(.i32, 2),
        };

        _ = try b.forEach1D("i", 4, 4, context, mask_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 0x00, 0x0f, 0x33, 0x7c };
        var formula_out = [_]i32{ 0, 0, 0, 0 };
        var not_out = [_]i32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, formula_out[0..]),
            oracle.argumentBuffer(i32, not_out[0..]),
        });

        for (input, formula_out, not_out) |x, actual_formula, actual_not| {
            try testing.expectEqual(((x & 0x0f) | 0x10) ^ 0x03, actual_formula);
            try testing.expectEqual(~x, actual_not);
        }

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed bit operations expose shifts and bitcasts" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "typed_bits_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const context: BitsContext = .{
            .src = b.bufferArgument(.i32, 0),
            .shl_out = b.bufferArgument(.i32, 1),
            .shr_out = b.bufferArgument(.i32, 2),
            .ushr_out = b.bufferArgument(.i32, 3),
            .bitcast_out = b.bufferArgument(.f32, 4),
            .roundtrip_out = b.bufferArgument(.i32, 5),
        };

        _ = try b.forEach1D("i", 4, 4, context, bits_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{
            @as(i32, @bitCast(@as(u32, 0x3f800000))),
            @as(i32, @bitCast(@as(u32, 0x40000000))),
            @as(i32, @bitCast(@as(u32, 0xbf800000))),
            0,
        };
        var shl_out = [_]i32{ 0, 0, 0, 0 };
        var shr_out = [_]i32{ 0, 0, 0, 0 };
        var ushr_out = [_]i32{ 0, 0, 0, 0 };
        var bitcast_out = [_]f32{ 0, 0, 0, 0 };
        var roundtrip_out = [_]i32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, shl_out[0..]),
            oracle.argumentBuffer(i32, shr_out[0..]),
            oracle.argumentBuffer(i32, ushr_out[0..]),
            oracle.argumentBuffer(f32, bitcast_out[0..]),
            oracle.argumentBuffer(i32, roundtrip_out[0..]),
        });

        for (input, shl_out, shr_out, ushr_out) |x, actual_shl, actual_shr, actual_ushr| {
            try testing.expectEqual(shlI32Expected(x, 1), actual_shl);
            try testing.expectEqual(x >> 1, actual_shr);
            try testing.expectEqual(ushrI32Expected(x, 1), actual_ushr);
        }
        try testing.expectEqualSlices(i32, input[0..], roundtrip_out[0..]);
        try testing.expectApproxEqAbs(@as(f32, 1.0), bitcast_out[0], 0.0001);
        try testing.expectApproxEqAbs(@as(f32, 2.0), bitcast_out[1], 0.0001);
        try testing.expectApproxEqAbs(@as(f32, -1.0), bitcast_out[2], 0.0001);
        try testing.expectApproxEqAbs(@as(f32, 0.0), bitcast_out[3], 0.0001);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed folds preserve scalar handles through Choir loops" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "typed_fold_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const context: FoldProgramContext = .{
            .src = b.bufferArgument(.i32, 0),
            .dst = b.bufferArgument(.i32, 1),
        };

        _ = try b.forEach1D("i", 4, 4, context, typed_fold_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 1, 2, 3, 4 };
        var output = [_]i32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 6, 9, 12, 15 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder whileLoop preserves typed carry shape" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_while_loop_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: WhileProgramContext = .{
            .src = b.bufferArgument(.i32, 0),
            .dst = b.bufferArgument(.i32, 1),
        };

        _ = try b.forEach1D("i", 4, 4, context, while_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 0, 1, 4, 5 };
        var output = @as([4]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 0, 1, 10, 15 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed linear indices compose with typed fold induction" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_index_fold_i32",
            &.{
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: IndexContext = .{
            .dst = b.bufferArgument(.i32, 0),
        };

        _ = try b.forEach1D("i", 5, 4, context, index_fold_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var output = @as([5]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 3, 6, 9, 12, 15 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed side-effect loops pass typed induction handles" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_side_effect_loop_i32",
            &.{
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: LoopProgramContext = .{
            .dst = b.bufferArgument(.i32, 0),
        };

        _ = try b.forEach1D("i", 4, 4, context, side_effect_loop_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var output = @as([4]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 2, 3, 4, 5 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }
};

const warp_tests = struct {
    const TypedWarpReduceContext = struct {
        src: BufferView(.i32),
        dst: BufferView(.i32),
    };

    const TypedWarpScanContext = struct {
        src: BufferView(.i32),
        inclusive: BufferView(.i32),
        exclusive: BufferView(.i32),
    };

    const TypedWarpShuffleContext = struct {
        src: BufferView(.i32),
        broadcast: BufferView(.i32),
        pair: BufferView(.i32),
    };

    const TypedWarpVoteContext = struct {
        src: BufferView(.i32),
        all_out: BufferView(.i32),
        any_out: BufferView(.i32),
        ballot_out: BufferView(.i32),
    };

    const TypedGpuIdContext = struct {
        global: BufferView(.i32),
        thread: BufferView(.i32),
        block: BufferView(.i32),
        lane: BufferView(.i32),
        warp: BufferView(.i32),
        mask: BufferView(.i32),
    };

    const TypedGpuDimContext = struct {
        block_x: BufferView(.i32),
        block_y: BufferView(.i32),
        grid_x: BufferView(.i32),
        grid_y: BufferView(.i32),
        capacity: BufferView(.i32),
    };

    const SharedBroadcastContext = struct {
        src: BufferView(.f32),
        dst: BufferView(.f32),
        shared: BufferView(.f32),
    };

    const WarpOracleContext = struct {
        src: builder.Value,
        reduced: builder.Value,
        lane: builder.Value,
        warp: builder.Value,
        mask: builder.Value,
    };

    const GuardedWarpContext = struct {
        src: builder.Value,
        reduced: builder.Value,
        mask: builder.Value,
    };

    const CooperativeLoopContext = struct {
        src: builder.Value,
        dst: builder.Value,
    };

    const CooperativeFoldContext = struct {
        src: builder.Value,
        index: builder.Value,
    };

    fn typed_warp_reduce_body(k: *Builder, index: Index1D, ctx: TypedWarpReduceContext) !void {
        const value = try ctx.src.load(k, index);
        const reduced = try value.warpReduce(k, .add);
        try ctx.dst.store(k, reduced, index);
    }

    fn typed_warp_scan_body(k: *Builder, index: Index1D, ctx: TypedWarpScanContext) !void {
        const value = try ctx.src.load(k, index);
        const inclusive = try value.warpScan(k, .add, .inclusive);
        const exclusive = try value.warpScan(k, .add, .exclusive);
        try ctx.inclusive.store(k, inclusive, index);
        try ctx.exclusive.store(k, exclusive, index);
    }

    fn typed_warp_shuffle_body(k: *Builder, index: Index1D, ctx: TypedWarpShuffleContext) !void {
        const value = try ctx.src.load(k, index);
        const broadcast = try value.shuffleSync(k, .sync, 0);
        const pair = try value.shuffleSync(k, .xor, 1);
        try ctx.broadcast.store(k, broadcast, index);
        try ctx.pair.store(k, pair, index);
    }

    fn typed_warp_vote_body(k: *Builder, index: Index1D, ctx: TypedWarpVoteContext) !void {
        const value = try ctx.src.load(k, index);
        const predicate = try value.compare(k, .lt, 4);
        const all = try predicate.allSync(k);
        const any = try predicate.anySync(k);
        const ballot = try predicate.ballotSync(k);

        try ctx.all_out.store(k, try all.cast(k, .i32), index);
        try ctx.any_out.store(k, try any.cast(k, .i32), index);
        try ctx.ballot_out.store(k, ballot, index);
    }

    fn typed_gpu_id_body(k: *Builder, index: Index1D, ctx: TypedGpuIdContext) !void {
        const global = try k.globalIdValue(.i32, .x);
        const thread = try k.threadIdValue(.i32, .x);
        const block = try k.blockIdValue(.i32, .x);
        const lane = try k.laneIdValue(.i32);
        const warp = try k.warpIdValue(.i32);
        const mask = try k.activeMaskValue();
        const lane_with_block = try lane.add(k, block);

        try ctx.global.store(k, global, index);
        try ctx.thread.store(k, thread, index);
        try ctx.block.store(k, block, index);
        try ctx.lane.store(k, lane_with_block, index);
        try ctx.warp.store(k, warp, index);
        try ctx.mask.store(k, mask, index);
    }

    fn typed_gpu_dim_body(k: *Builder, index: Index2D, ctx: TypedGpuDimContext) !void {
        const block_x = try k.blockDimValue(.i32, .x);
        const block_y = try k.blockDimValue(.i32, .y);
        const grid_x = try k.gridDimValue(.i32, .x);
        const grid_y = try k.gridDimValue(.i32, .y);
        const x_capacity = try block_x.mul(k, grid_x);
        const y_capacity = try block_y.mul(k, grid_y);
        const capacity = try x_capacity.mul(k, y_capacity);

        try ctx.block_x.store(k, block_x, index);
        try ctx.block_y.store(k, block_y, index);
        try ctx.grid_x.store(k, grid_x, index);
        try ctx.grid_y.store(k, grid_y, index);
        try ctx.capacity.store(k, capacity, index);
    }

    fn shared_broadcast_init(k: *Builder, ctx: SharedBroadcastContext) !void {
        const seed = try ctx.src.load(k, 0);
        try ctx.shared.store(k, seed, 0);
    }

    fn shared_broadcast_body(k: *Builder, index: Index1D, ctx: SharedBroadcastContext) !void {
        const zero = try k.constantValue(.i32, 0);
        const lane = try k.threadIdValue(.i32, .x);
        const is_first = try lane.compare(k, .eq, zero);
        try k.guardDo(is_first, ctx, shared_broadcast_init);
        try k.barrier(.block);
        const value = try ctx.shared.load(k, 0);
        try ctx.dst.store(k, value, index);
    }

    fn warp_oracle_body(k: *Builder, index: Index1D, ctx: WarpOracleContext) !void {
        const value = try k.load(ctx.src, index.index);
        const reduced = try k.warpReduce(.add, value);
        const lane = try k.cast(try k.laneId(), .i32);
        const warp = try k.cast(try k.warpId(), .i32);
        const mask = try k.activeMask();
        try k.syncWarp();
        try k.store(reduced, ctx.reduced, index.index);
        try k.store(lane, ctx.lane, index.index);
        try k.store(warp, ctx.warp, index.index);
        try k.store(mask, ctx.mask, index.index);
    }

    fn guarded_warp_body(k: *Builder, index: Index1D, ctx: GuardedWarpContext) !void {
        const value = try k.load(ctx.src, index.index);
        const reduced = try k.warpReduce(.add, value);
        const mask = try k.activeMask();
        try k.store(reduced, ctx.reduced, index.index);
        try k.store(mask, ctx.mask, index.index);
    }

    fn cooperative_fold_step(
        inner: *Builder,
        iteration: builder.Value,
        acc: builder.Value,
        ctx: CooperativeFoldContext,
    ) !builder.Value {
        const value = try inner.load(ctx.src, ctx.index);
        const adjusted = try inner.add(value, try inner.cast(iteration, .i32));
        const reduced = try inner.warpReduce(.add, adjusted);
        return inner.add(acc, reduced);
    }

    fn cooperative_loop_body(k: *Builder, index: Index1D, ctx: CooperativeLoopContext) !void {
        const zero = try k.constantInt(.i32, 0);
        const sum = try k.foldRange(0, 2, 1, zero, CooperativeFoldContext{
            .src = ctx.src,
            .index = index.index,
        }, cooperative_fold_step);
        try k.store(sum, ctx.dst, index.index);
    }

    test "ProgramBuilder typed warp reductions return typed scalar handles" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_warp_reduce_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: TypedWarpReduceContext = .{
            .src = b.bufferArgument(.i32, 0),
            .dst = b.bufferArgument(.i32, 1),
        };

        _ = try b.forEach1D("i", 4, 4, context, typed_warp_reduce_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 1, 2, 3, 4 };
        var output = [_]i32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 10, 10, 10, 10 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed warp scans return typed scalar handles" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_warp_scan_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: TypedWarpScanContext = .{
            .src = b.bufferArgument(.i32, 0),
            .inclusive = b.bufferArgument(.i32, 1),
            .exclusive = b.bufferArgument(.i32, 2),
        };

        _ = try b.forEach1D("i", 8, 8, context, typed_warp_scan_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
        var inclusive = @as([8]i32, @splat(0));
        var exclusive = @as([8]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, inclusive[0..]),
            oracle.argumentBuffer(i32, exclusive[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 1, 3, 6, 10, 15, 21, 28, 36 }, inclusive[0..]);
        try testing.expectEqualSlices(i32, &.{ 0, 1, 3, 6, 10, 15, 21, 28 }, exclusive[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed warp shuffles return typed scalar handles" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_warp_shuffle_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: TypedWarpShuffleContext = .{
            .src = b.bufferArgument(.i32, 0),
            .broadcast = b.bufferArgument(.i32, 1),
            .pair = b.bufferArgument(.i32, 2),
        };

        _ = try b.forEach1D("i", 8, 8, context, typed_warp_shuffle_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 10, 20, 30, 40, 50, 60, 70, 80 };
        var broadcast = @as([8]i32, @splat(0));
        var pair = @as([8]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, broadcast[0..]),
            oracle.argumentBuffer(i32, pair[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 10, 10, 10, 10, 10, 10, 10, 10 }, broadcast[0..]);
        try testing.expectEqualSlices(i32, &.{ 20, 10, 40, 30, 60, 50, 80, 70 }, pair[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed warp votes return typed predicate and ballot handles" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_warp_votes_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: TypedWarpVoteContext = .{
            .src = b.bufferArgument(.i32, 0),
            .all_out = b.bufferArgument(.i32, 1),
            .any_out = b.bufferArgument(.i32, 2),
            .ballot_out = b.bufferArgument(.i32, 3),
        };

        _ = try b.forEach1D("i", 8, 8, context, typed_warp_vote_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7 };
        var all_out = @as([8]i32, @splat(0));
        var any_out = @as([8]i32, @splat(0));
        var ballot_out = @as([8]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, all_out[0..]),
            oracle.argumentBuffer(i32, any_out[0..]),
            oracle.argumentBuffer(i32, ballot_out[0..]),
        });

        const expected_all = @as([8]i32, @splat(0));
        const expected_any = @as([8]i32, @splat(1));
        const expected_ballot = @as([8]i32, @splat(0xf));
        try testing.expectEqualSlices(i32, expected_all[0..], all_out[0..]);
        try testing.expectEqualSlices(i32, expected_any[0..], any_out[0..]);
        try testing.expectEqualSlices(i32, expected_ballot[0..], ballot_out[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed gpu ids and masks compose with typed buffers" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "typed_gpu_ids_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const context: TypedGpuIdContext = .{
            .global = b.bufferArgument(.i32, 0),
            .thread = b.bufferArgument(.i32, 1),
            .block = b.bufferArgument(.i32, 2),
            .lane = b.bufferArgument(.i32, 3),
            .warp = b.bufferArgument(.i32, 4),
            .mask = b.bufferArgument(.i32, 5),
        };

        _ = try b.forEach1D("i", 10, 4, context, typed_gpu_id_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var global = @as([10]i32, @splat(0));
        var thread = @as([10]i32, @splat(0));
        var block = @as([10]i32, @splat(0));
        var lane = @as([10]i32, @splat(0));
        var warp = @as([10]i32, @splat(0));
        var mask = @as([10]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, global[0..]),
            oracle.argumentBuffer(i32, thread[0..]),
            oracle.argumentBuffer(i32, block[0..]),
            oracle.argumentBuffer(i32, lane[0..]),
            oracle.argumentBuffer(i32, warp[0..]),
            oracle.argumentBuffer(i32, mask[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, global[0..]);
        try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 0, 1, 2, 3, 0, 1 }, thread[0..]);
        try testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2 }, block[0..]);
        try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 1, 2, 3, 4, 2, 3 }, lane[0..]);
        try testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, warp[0..]);
        try testing.expectEqualSlices(
            i32,
            &.{ 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0x3, 0x3 },
            mask[0..],
        );

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder typed GPU launch dimensions compose with typed buffers" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "typed_gpu_launch_dims_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const width: u64 = 5;
        const height: u64 = 3;

        const context: TypedGpuDimContext = .{
            .block_x = b.bufferArgument(.i32, 0),
            .block_y = b.bufferArgument(.i32, 1),
            .grid_x = b.bufferArgument(.i32, 2),
            .grid_y = b.bufferArgument(.i32, 3),
            .capacity = b.bufferArgument(.i32, 4),
        };

        _ = try b.forEach2D(.{
            .x = domainAxis("x", width, 2),
            .y = domainAxis("y", height, 2),
        }, context, typed_gpu_dim_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        const launch = try program.launch();
        try testing.expectEqual(@as(u32, 3), launch.grid[0]);
        try testing.expectEqual(@as(u32, 2), launch.grid[1]);
        try testing.expectEqual(@as(u32, 2), launch.block[0]);
        try testing.expectEqual(@as(u32, 2), launch.block[1]);

        var block_x = @as([15]i32, @splat(0));
        var block_y = @as([15]i32, @splat(0));
        var grid_x = @as([15]i32, @splat(0));
        var grid_y = @as([15]i32, @splat(0));
        var capacity = @as([15]i32, @splat(0));
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, block_x[0..]),
            oracle.argumentBuffer(i32, block_y[0..]),
            oracle.argumentBuffer(i32, grid_x[0..]),
            oracle.argumentBuffer(i32, grid_y[0..]),
            oracle.argumentBuffer(i32, capacity[0..]),
        });

        const expected_block = @as([15]i32, @splat(2));
        const expected_grid_x = @as([15]i32, @splat(3));
        const expected_grid_y = @as([15]i32, @splat(2));
        const expected_capacity = @as([15]i32, @splat(24));
        try testing.expectEqualSlices(i32, expected_block[0..], block_x[0..]);
        try testing.expectEqualSlices(i32, expected_block[0..], block_y[0..]);
        try testing.expectEqualSlices(i32, expected_grid_x[0..], grid_x[0..]);
        try testing.expectEqualSlices(i32, expected_grid_y[0..], grid_y[0..]);
        try testing.expectEqualSlices(i32, expected_capacity[0..], capacity[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder exposes shared workgroup buffers through Choir memref ops" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "shared_broadcast_f32",
            &.{
                builder.dynamicBuffer(.f32),
                builder.dynamicBuffer(.f32),
            },
        );
        defer b.deinit();

        const shared = try b.sharedBufferView(.f32, 1);

        const context: SharedBroadcastContext = .{
            .src = b.bufferArgument(.f32, 0),
            .dst = b.bufferArgument(.f32, 1),
            .shared = shared,
        };

        _ = try b.forEach1D("i", 4, 4, context, shared_broadcast_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]f32{ 9.0, 2.0, 3.0, 4.0 };
        var output = [_]f32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(f32, input[0..]),
            oracle.argumentBuffer(f32, output[0..]),
        });

        try testing.expectEqualSlices(f32, &.{ 9.0, 9.0, 9.0, 9.0 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder exposes warp reductions with CPU oracle semantics" {
        var b = try Builder.init(testing.allocator, Builder.Limits.testing, "warp_reduce_i32", &.{
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
            builder.dynamicBuffer(.i32),
        });
        defer b.deinit();

        const context: WarpOracleContext = .{
            .src = b.argument(0),
            .reduced = b.argument(1),
            .lane = b.argument(2),
            .warp = b.argument(3),
            .mask = b.argument(4),
        };

        _ = try b.forEach1D("i", 8, 8, context, warp_oracle_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
        var reduced = [_]i32{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var lanes = [_]i32{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var warps = [_]i32{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var masks = [_]i32{ 0, 0, 0, 0, 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, reduced[0..]),
            oracle.argumentBuffer(i32, lanes[0..]),
            oracle.argumentBuffer(i32, warps[0..]),
            oracle.argumentBuffer(i32, masks[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 36, 36, 36, 36, 36, 36, 36, 36 }, reduced[0..]);
        try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, lanes[0..]);
        try testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, warps[0..]);
        try testing.expectEqualSlices(
            i32,
            &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
            masks[0..],
        );

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder active masks track guarded warp lanes" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "guarded_warp_active_mask_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: GuardedWarpContext = .{
            .src = b.argument(0),
            .reduced = b.argument(1),
            .mask = b.argument(2),
        };

        _ = try b.forEach1D("i", 5, 8, context, guarded_warp_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 1, 2, 3, 4, 5 };
        var reduced = [_]i32{ 0, 0, 0, 0, 0 };
        var masks = [_]i32{ 0, 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, reduced[0..]),
            oracle.argumentBuffer(i32, masks[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 15, 15, 15, 15, 15 }, reduced[0..]);
        try testing.expectEqualSlices(i32, &.{ 0x1f, 0x1f, 0x1f, 0x1f, 0x1f }, masks[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }

    test "ProgramBuilder runs warp reductions inside cooperative loops" {
        var b = try Builder.init(
            testing.allocator,
            Builder.Limits.testing,
            "loop_warp_reduce_i32",
            &.{
                builder.dynamicBuffer(.i32),
                builder.dynamicBuffer(.i32),
            },
        );
        defer b.deinit();

        const context: CooperativeLoopContext = .{
            .src = b.argument(0),
            .dst = b.argument(1),
        };

        _ = try b.forEach1D("i", 4, 4, context, cooperative_loop_body);
        try b.return_();

        var program = try b.finish();
        defer program.deinit();

        var input = [_]i32{ 1, 2, 3, 4 };
        var output = [_]i32{ 0, 0, 0, 0 };
        try program.runCpu(testing.allocator, &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });

        try testing.expectEqualSlices(i32, &.{ 24, 24, 24, 24 }, output[0..]);

        var out = try program.createPlan(testing.allocator, .{});
        defer out.deinit();
        try program.checkPlan(testing.allocator, &out);
    }
};

test {
    @import("test_discovery").discover(domain_tests);
    @import("test_discovery").discover(lifecycle_tests);
    @import("test_discovery").discover(sdf_tests);
    @import("test_discovery").discover(typed_tests);
    @import("test_discovery").discover(warp_tests);
    @import("test_discovery").discover(program_builder);
}

test "accy kernel program builder declaration coverage" {
    std.testing.refAllDecls(domain_tests);
    std.testing.refAllDecls(lifecycle_tests);
    std.testing.refAllDecls(sdf_tests);
    std.testing.refAllDecls(typed_tests);
    std.testing.refAllDecls(warp_tests);
    std.testing.refAllDecls(program_builder);
}

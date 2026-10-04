const gpu_abi = @import("gpu_abi");
const core = @import("../core/root.zig");

const base = core.builder;
const domain = @import("domain/root.zig");
const kernel_domain = core.domain;
const typed = core.typed;
const vector = core.vector;
const view = core.view;

const DType = gpu_abi.DType;

pub fn Builder(comptime Inner: type, comptime Schedule: type) type {
    return struct {
        token: *anyopaque,
        schedule: Schedule,

        const Self = @This();

        pub fn init(source: *Inner, schedule: Schedule) Self {
            return .{
                .token = source,
                .schedule = schedule,
            };
        }

        pub fn index1D(self: *Self, name: []const u8, extent: u64) !kernel_domain.Index1D {
            return self.schedule.index1D(self.owner(), domain.axis(name, extent));
        }

        pub fn index2D(self: *Self, shape: domain.Domain2D) !kernel_domain.Index2D {
            return self.schedule.index2D(self.owner(), shape);
        }

        pub fn index3D(self: *Self, shape: domain.Domain3D) !kernel_domain.Index3D {
            return self.schedule.index3D(self.owner(), shape);
        }

        pub fn guardDo(
            self: *Self,
            condition: anytype,
            context: anytype,
            comptime body: anytype,
        ) !void {
            var active_guard = try self.owner().guard(condition);
            errdefer active_guard.abort();
            try body(self, context);
            try active_guard.leave();
        }

        pub fn guardIndexDo(
            self: *Self,
            index: kernel_domain.Index1D,
            context: anytype,
            comptime body: anytype,
        ) !void {
            var active_guard = try self.owner().guardIndex(index);
            errdefer active_guard.abort();
            try body(self, index, context);
            try active_guard.leave();
        }

        pub fn guardIndex2DDo(
            self: *Self,
            index: kernel_domain.Index2D,
            context: anytype,
            comptime body: anytype,
        ) !void {
            var x_guard = try self.owner().guardIndex(index.x);
            errdefer x_guard.abort();
            var y_guard = try self.owner().guardIndex(index.y);
            errdefer y_guard.abort();
            try body(self, index, context);
            try y_guard.leave();
            try x_guard.leave();
        }

        pub fn guardIndex3DDo(
            self: *Self,
            index: kernel_domain.Index3D,
            context: anytype,
            comptime body: anytype,
        ) !void {
            var x_guard = try self.owner().guardIndex(index.x);
            errdefer x_guard.abort();
            var y_guard = try self.owner().guardIndex(index.y);
            errdefer y_guard.abort();
            var z_guard = try self.owner().guardIndex(index.z);
            errdefer z_guard.abort();
            try body(self, index, context);
            try z_guard.leave();
            try y_guard.leave();
            try x_guard.leave();
        }

        pub fn forEach1D(
            self: *Self,
            name: []const u8,
            extent: u64,
            context: anytype,
            comptime body: anytype,
        ) !kernel_domain.Index1D {
            const index = try self.index1D(name, extent);
            try self.guardIndexDo(index, context, body);
            return index;
        }

        pub fn forEach2D(
            self: *Self,
            shape: domain.Domain2D,
            context: anytype,
            comptime body: anytype,
        ) !kernel_domain.Index2D {
            const index = try self.index2D(shape);
            try self.guardIndex2DDo(index, context, body);
            return index;
        }

        pub fn forEach3D(
            self: *Self,
            shape: domain.Domain3D,
            context: anytype,
            comptime body: anytype,
        ) !kernel_domain.Index3D {
            const index = try self.index3D(shape);
            try self.guardIndex3DDo(index, context, body);
            return index;
        }

        pub fn fold(
            self: *Self,
            lower: base.Value,
            upper: base.Value,
            step: base.Value,
            initial: anytype,
            context: anytype,
            comptime body: anytype,
        ) !@TypeOf(initial) {
            return self.owner().fold(lower, upper, step, initial, .{
                .logical = self,
                .payload = context,
            }, struct {
                fn each(
                    _: anytype,
                    iteration: anytype,
                    acc: anytype,
                    fold_ctx: anytype,
                ) !@TypeOf(acc) {
                    return body(fold_ctx.logical, iteration, acc, fold_ctx.payload);
                }
            }.each);
        }

        pub fn foldRange(
            self: *Self,
            lower: i64,
            upper: i64,
            step: i64,
            initial: anytype,
            context: anytype,
            comptime body: anytype,
        ) !@TypeOf(initial) {
            const lower_value = try self.constantIndex(lower);
            const upper_value = try self.constantIndex(upper);
            const step_value = try self.constantIndex(step);
            return self.fold(lower_value, upper_value, step_value, initial, context, body);
        }

        pub fn whileLoop(
            self: *Self,
            initial: anytype,
            context: anytype,
            comptime condition: anytype,
            comptime body: anytype,
        ) !@TypeOf(initial) {
            return self.owner().whileLoop(initial, .{
                .logical = self,
                .payload = context,
            }, struct {
                fn keepGoing(_: anytype, carry: anytype, loop_ctx: anytype) !base.Value {
                    return typed.raw(try condition(loop_ctx.logical, carry, loop_ctx.payload));
                }
            }.keepGoing, struct {
                fn each(_: anytype, carry: anytype, loop_ctx: anytype) !@TypeOf(carry) {
                    return body(loop_ctx.logical, carry, loop_ctx.payload);
                }
            }.each);
        }

        pub fn forScope(
            self: *Self,
            lower: base.Value,
            upper: base.Value,
            step: base.Value,
            init_args: []const base.Value,
            result_types: []const base.Type,
        ) !ForScope(Inner) {
            return self.owner().forScope(lower, upper, step, init_args, result_types);
        }

        pub fn whileScope(
            self: *Self,
            init_args: []const base.Value,
            result_types: []const base.Type,
        ) !WhileScope(Inner) {
            return self.owner().whileScope(init_args, result_types);
        }

        pub fn forDo(
            self: *Self,
            lower: base.Value,
            upper: base.Value,
            step: base.Value,
            context: anytype,
            comptime body: anytype,
        ) !base.For {
            var scope = try self.forScope(lower, upper, step, &.{}, &.{});
            errdefer scope.abort();
            try body(self, scope.inductionVar(), context);
            try scope.leave(&.{});
            return scope.loop;
        }

        pub fn forValueDo(
            self: *Self,
            comptime dtype: DType,
            lower: base.Value,
            upper: base.Value,
            step: base.Value,
            context: anytype,
            comptime body: anytype,
        ) !base.For {
            var scope = try self.forScope(lower, upper, step, &.{}, &.{});
            errdefer scope.abort();
            try body(self, try self.castValue(scope.inductionVar(), dtype), context);
            try scope.leave(&.{});
            return scope.loop;
        }

        pub fn forRangeDo(
            self: *Self,
            lower: i64,
            upper: i64,
            step: i64,
            context: anytype,
            comptime body: anytype,
        ) !base.For {
            const lower_value = try self.constantIndex(lower);
            const upper_value = try self.constantIndex(upper);
            const step_value = try self.constantIndex(step);
            return self.forDo(lower_value, upper_value, step_value, context, body);
        }

        pub fn forRangeValueDo(
            self: *Self,
            comptime dtype: DType,
            lower: i64,
            upper: i64,
            step: i64,
            context: anytype,
            comptime body: anytype,
        ) !base.For {
            const lower_value = try self.constantIndex(lower);
            const upper_value = try self.constantIndex(upper);
            const step_value = try self.constantIndex(step);
            return self.forValueDo(dtype, lower_value, upper_value, step_value, context, body);
        }

        pub fn argument(self: *Self, index: usize) base.Value {
            return self.owner().argument(index);
        }

        pub fn globalId(self: *Self, dim: base.Dimension) !base.Value {
            return self.owner().globalId(dim);
        }

        pub fn globalIdValue(
            self: *Self,
            comptime dtype: DType,
            dim: base.Dimension,
        ) !typed.Value(dtype) {
            return self.owner().globalIdValue(dtype, dim);
        }

        pub fn laneId(self: *Self) !base.Value {
            return self.owner().laneId();
        }

        pub fn threadId(self: *Self, dim: base.Dimension) !base.Value {
            return self.owner().threadId(dim);
        }

        pub fn blockId(self: *Self, dim: base.Dimension) !base.Value {
            return self.owner().blockId(dim);
        }

        pub fn blockDim(self: *Self, dim: base.Dimension) !base.Value {
            return self.owner().blockDim(dim);
        }

        pub fn gridDim(self: *Self, dim: base.Dimension) !base.Value {
            return self.owner().gridDim(dim);
        }

        pub fn warpReduce(self: *Self, op_kind: base.WarpOpKind, value: anytype) !@TypeOf(value) {
            return self.owner().warpReduce(op_kind, value);
        }

        pub fn warpScan(
            self: *Self,
            op_kind: base.WarpOpKind,
            mode: base.WarpScanMode,
            value: anytype,
        ) !@TypeOf(value) {
            return self.owner().warpScan(op_kind, mode, value);
        }

        pub fn warpId(self: *Self) !base.Value {
            return self.owner().warpId();
        }

        pub fn mmaSync(
            self: *Self,
            shape: base.MmaShape,
            a: [4]base.Value,
            b: [2]base.Value,
            c: [4]base.Value,
        ) ![4]base.Value {
            return self.owner().mmaSync(shape, a, b, c);
        }

        pub fn shuffleSync(
            self: *Self,
            mode: base.ShuffleMode,
            value: base.Value,
            lane_or_delta: base.Value,
        ) !base.Value {
            return self.owner().shuffleSync(mode, value, lane_or_delta);
        }

        pub fn fence(self: *Self, scope: base.Scope) !void {
            return self.owner().fence(scope);
        }

        pub fn asyncCopyShared(
            self: *Self,
            dst: base.Value,
            dst_index: base.Value,
            src: base.Value,
            src_index: base.Value,
            bytes: u32,
        ) !void {
            return self.owner().asyncCopyShared(dst, dst_index, src, src_index, bytes);
        }

        pub fn asyncCopyCommit(self: *Self) !void {
            return self.owner().asyncCopyCommit();
        }

        pub fn asyncCopyWait(self: *Self, groups: u32) !void {
            return self.owner().asyncCopyWait(groups);
        }

        pub fn sharedBuffer(self: *Self, dtype: DType, size: u64) !base.Value {
            return self.owner().sharedBuffer(dtype, size);
        }

        pub fn dynamicSharedBuffer(
            self: *Self,
            dtype: DType,
            size: u64,
            byte_offset: u64,
        ) !base.Value {
            return self.owner().dynamicSharedBuffer(dtype, size, byte_offset);
        }

        pub fn barrier(self: *Self, scope: base.Scope) !void {
            return self.owner().barrier(scope);
        }

        pub fn typedArgument(self: *Self, comptime dtype: DType, index: usize) typed.Value(dtype) {
            return self.owner().typedArgument(dtype, index);
        }

        pub fn typedValue(
            self: *Self,
            comptime dtype: DType,
            value: base.Value,
        ) typed.Value(dtype) {
            return self.owner().typedValue(dtype, value);
        }

        pub fn castValue(self: *Self, input: anytype, comptime dtype: DType) !typed.Value(dtype) {
            return self.owner().castValue(input, dtype);
        }

        pub fn bufferArgument(
            self: *Self,
            comptime dtype: DType,
            index: usize,
        ) view.BufferView(dtype) {
            return self.owner().bufferArgument(dtype, index);
        }

        pub fn bufferView(
            self: *Self,
            comptime dtype: DType,
            value: base.Value,
        ) view.BufferView(dtype) {
            return self.owner().bufferView(dtype, value);
        }

        pub fn constantInt(self: *Self, dtype: DType, value: i64) !base.Value {
            return self.owner().constantInt(dtype, value);
        }

        pub fn constantIndex(self: *Self, value: i64) !base.Value {
            return self.owner().constantIndex(value);
        }

        pub fn constantFloat(self: *Self, dtype: DType, value: f64) !base.Value {
            return self.owner().constantFloat(dtype, value);
        }

        pub fn constantBool(self: *Self, value: bool) !base.Value {
            return self.owner().constantBool(value);
        }

        pub fn constantValue(
            self: *Self,
            comptime dtype: DType,
            value: anytype,
        ) !typed.Value(dtype) {
            return self.owner().constantValue(dtype, value);
        }

        pub fn add(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().add(lhs, rhs);
        }

        pub fn sub(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().sub(lhs, rhs);
        }

        pub fn mul(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().mul(lhs, rhs);
        }

        pub fn umulhi(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().umulhi(lhs, rhs);
        }

        pub fn div(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().div(lhs, rhs);
        }

        pub fn min(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().min(lhs, rhs);
        }

        pub fn max(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().max(lhs, rhs);
        }

        pub fn and_(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().and_(lhs, rhs);
        }

        pub fn or_(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().or_(lhs, rhs);
        }

        pub fn xor(self: *Self, lhs: base.Value, rhs: base.Value) !base.Value {
            return self.owner().xor(lhs, rhs);
        }

        pub fn not(self: *Self, input: base.Value) !base.Value {
            return self.owner().not(input);
        }

        pub fn popcount(self: *Self, input: base.Value) !base.Value {
            return self.owner().popcount(input);
        }

        pub fn ballotSync(self: *Self, predicate: base.Value) !base.Value {
            return self.owner().ballotSync(predicate);
        }

        pub fn shl(self: *Self, value: base.Value, shift: base.Value) !base.Value {
            return self.owner().shl(value, shift);
        }

        pub fn shr(self: *Self, value: base.Value, shift: base.Value) !base.Value {
            return self.owner().shr(value, shift);
        }

        pub fn ushr(self: *Self, value: base.Value, shift: base.Value) !base.Value {
            return self.owner().ushr(value, shift);
        }

        pub fn bitcast(self: *Self, input: base.Value, dtype: DType) !base.Value {
            return self.owner().bitcast(input, dtype);
        }

        pub fn neg(self: *Self, input: base.Value) !base.Value {
            return self.owner().neg(input);
        }

        pub fn abs(self: *Self, input: base.Value) !base.Value {
            return self.owner().abs(input);
        }

        pub fn sqrt(self: *Self, input: base.Value) !base.Value {
            return self.owner().sqrt(input);
        }

        pub fn exp(self: *Self, input: base.Value) !base.Value {
            return self.owner().exp(input);
        }

        pub fn log(self: *Self, input: base.Value) !base.Value {
            return self.owner().log(input);
        }

        pub fn tanh(self: *Self, input: base.Value) !base.Value {
            return self.owner().tanh(input);
        }

        pub fn sin(self: *Self, input: base.Value) !base.Value {
            return self.owner().sin(input);
        }

        pub fn cos(self: *Self, input: base.Value) !base.Value {
            return self.owner().cos(input);
        }

        pub fn tan(self: *Self, input: base.Value) !base.Value {
            return self.owner().tan(input);
        }

        pub fn floor(self: *Self, input: base.Value) !base.Value {
            return self.owner().floor(input);
        }

        pub fn round(self: *Self, input: base.Value) !base.Value {
            return self.owner().round(input);
        }

        pub fn trunc(self: *Self, input: base.Value) !base.Value {
            return self.owner().trunc(input);
        }

        pub fn tf32Round(self: *Self, input: base.Value) !base.Value {
            return self.owner().tf32Round(input);
        }

        pub fn pow(self: *Self, base_value: base.Value, exponent: base.Value) !base.Value {
            return self.owner().pow(base_value, exponent);
        }

        pub fn atan2(self: *Self, y: base.Value, x: base.Value) !base.Value {
            return self.owner().atan2(y, x);
        }

        pub fn fma(self: *Self, a: base.Value, b: base.Value, c: base.Value) !base.Value {
            return self.owner().fma(a, b, c);
        }

        pub fn compare(
            self: *Self,
            predicate: base.Compare,
            lhs: base.Value,
            rhs: base.Value,
        ) !base.Value {
            return self.owner().compare(predicate, lhs, rhs);
        }

        pub fn select(
            self: *Self,
            condition: base.Value,
            true_value: base.Value,
            false_value: base.Value,
        ) !base.Value {
            return self.owner().select(condition, true_value, false_value);
        }

        pub fn cast(self: *Self, input: base.Value, dtype: DType) !base.Value {
            return self.owner().cast(input, dtype);
        }

        pub fn castIndex(self: *Self, input: base.Value) !base.Value {
            return self.owner().castIndex(input);
        }

        pub fn linearIndex(self: *Self, index: anytype) !base.Value {
            return self.owner().linearIndex(index);
        }

        pub fn linearIndexValue(
            self: *Self,
            index: anytype,
            comptime dtype: DType,
        ) !typed.Value(dtype) {
            return self.owner().linearIndexValue(index, dtype);
        }

        pub fn loadIndex(self: *Self, memref: base.Value, index: anytype) !base.Value {
            return self.owner().loadIndex(memref, index);
        }

        pub fn loadVector(
            self: *Self,
            memref: base.Value,
            index: base.Value,
            width: u32,
        ) !base.Value {
            return self.owner().loadVector(memref, index, width);
        }

        pub fn extractLane(self: *Self, vec: base.Value, lane: u32, dtype: DType) !base.Value {
            return self.owner().extractLane(vec, lane, dtype);
        }

        pub fn insertLane(self: *Self, vec: base.Value, scalar: base.Value, lane: u32) !base.Value {
            return self.owner().insertLane(vec, scalar, lane);
        }

        pub fn packVector(self: *Self, lanes: [4]base.Value) !base.Value {
            return self.owner().packVector(lanes);
        }

        pub fn storeIndex(
            self: *Self,
            value: base.Value,
            memref: base.Value,
            index: anytype,
        ) !void {
            try self.owner().storeIndex(value, memref, index);
        }

        pub fn atomicRmw(
            self: *Self,
            kind: base.AtomicRmwKind,
            value: base.Value,
            memref: base.Value,
            index: base.Value,
        ) !base.Value {
            return self.owner().atomicRmw(kind, value, memref, index);
        }

        pub fn atomicRmwIndex(
            self: *Self,
            kind: base.AtomicRmwKind,
            value: base.Value,
            memref: base.Value,
            index: anytype,
        ) !base.Value {
            return self.atomicRmw(kind, value, memref, try self.linearIndex(index));
        }

        pub fn atomicCas(
            self: *Self,
            expected: base.Value,
            desired: base.Value,
            memref: base.Value,
            index: base.Value,
        ) !base.Value {
            return self.owner().atomicCas(expected, desired, memref, index);
        }

        pub fn atomicCasIndex(
            self: *Self,
            expected: base.Value,
            desired: base.Value,
            memref: base.Value,
            index: anytype,
        ) !base.Value {
            return self.atomicCas(expected, desired, memref, try self.linearIndex(index));
        }

        pub fn vec2(self: *Self, x: base.Value, y: base.Value) vector.Vec2 {
            return self.owner().vec2(x, y);
        }

        pub fn typedVec2(
            self: *Self,
            comptime dtype: DType,
            x: anytype,
            y: anytype,
        ) !typed.Vec2(dtype) {
            return self.owner().typedVec2(dtype, x, y);
        }

        pub fn vec3(self: *Self, x: base.Value, y: base.Value, z: base.Value) vector.Vec3 {
            return self.owner().vec3(x, y, z);
        }

        pub fn typedVec3(
            self: *Self,
            comptime dtype: DType,
            x: anytype,
            y: anytype,
            z: anytype,
        ) !typed.Vec3(dtype) {
            return self.owner().typedVec3(dtype, x, y, z);
        }

        pub fn splat2(self: *Self, value: base.Value) vector.Vec2 {
            return self.owner().splat2(value);
        }

        pub fn typedSplat2(self: *Self, comptime dtype: DType, value: anytype) !typed.Vec2(dtype) {
            return self.owner().typedSplat2(dtype, value);
        }

        pub fn splat3(self: *Self, value: base.Value) vector.Vec3 {
            return self.owner().splat3(value);
        }

        pub fn typedSplat3(self: *Self, comptime dtype: DType, value: anytype) !typed.Vec3(dtype) {
            return self.owner().typedSplat3(dtype, value);
        }

        fn owner(self: *Self) *Inner {
            return @ptrCast(@alignCast(self.token));
        }
    };
}

pub fn wrap(inner: anytype, schedule: anytype) Builder(
    PointerChild(@TypeOf(inner)),
    @TypeOf(schedule),
) {
    return Builder(PointerChild(@TypeOf(inner)), @TypeOf(schedule)).init(inner, schedule);
}

fn PointerChild(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info.child,
        else => @compileError("logical kernel builders wrap builder pointers"),
    };
}

fn WhileScope(comptime Inner: type) type {
    const Return = @TypeOf(@as(*Inner, undefined).whileScope(
        @as([]const base.Value, undefined),
        @as([]const base.Type, undefined),
    ));
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => @compileError("whileScope must return an error union"),
    };
}

fn ForScope(comptime Inner: type) type {
    const Return = @TypeOf(@as(*Inner, undefined).forScope(
        @as(base.Value, undefined),
        @as(base.Value, undefined),
        @as(base.Value, undefined),
        @as([]const base.Value, undefined),
        @as([]const base.Type, undefined),
    ));
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => @compileError("forScope must return an error union"),
    };
}

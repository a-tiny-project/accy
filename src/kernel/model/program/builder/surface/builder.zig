const std = @import("std");
const choir = @import("choir");

const core = @import("../../../core/root.zig");
const graph = @import("../../graph/root.zig");
const guard_mod = @import("../../guard/root.zig");

const builder = core.builder;
const builder_typed = @import("../typed/root.zig");
const domain_mod = core.domain;
const schedule_mod = core.schedule;
const surface_domain = @import("domain.zig");
const surface_flow = @import("flow.zig");
const surface_guard = @import("guard.zig");
const surface_primitive = @import("primitive.zig");
const surface_schedule = @import("schedule.zig");

const ir = choir.ir;

/// A caller instantiates this once per kernel program type to get the typed builder its kernels are
/// written with. The function returns a type that pairs a kernel program type with the dialects,
/// named groups of compiler operations, that each of its own compiler contexts, the objects that
/// own the dialects, types and operations of one compiler module, loads at setup. The shared kernel
/// program front end passes `.{}`, and the kernel execution path passes the target dialect
/// registrations and preloads `scf`. A builder that borrows a context the caller already owns skips
/// those requirements, so the owner prepares that context before building or freezing it.
pub fn Surface(
    comptime ProgramType: type,
    comptime context_requirements: builder.ContextRequirements,
) type {
    return struct {
        pub const Index1D = domain_mod.Index1D;
        pub const VectorIndex1D = domain_mod.VectorIndex1D;
        pub const DomainAxis = domain_mod.DomainAxis;
        pub const Domain2D = domain_mod.Domain2D;
        pub const Domain3D = domain_mod.Domain3D;
        pub const Index2D = domain_mod.Index2D;
        pub const Index3D = domain_mod.Index3D;
        pub const Vec2 = builder_typed.Vec2;
        pub const Vec3 = builder_typed.Vec3;
        pub const TypedValue = builder_typed.TypedValue;
        pub const TypedVec2 = builder_typed.TypedVec2;
        pub const TypedVec3 = builder_typed.TypedVec3;
        pub const domainAxis = domain_mod.domainAxis;
        pub const BufferView = builder_typed.BufferView;
        pub const Program = ProgramType;
        pub const Limits = core.Limits;
        pub const Capacity = Builder.Capacity;

        pub fn define(
            allocator: std.mem.Allocator,
            limits: Limits,
            kernel_name: []const u8,
            params: []const builder.Param,
            context: anytype,
            comptime body: anytype,
        ) !Program {
            var program_builder = try Builder.init(allocator, limits, kernel_name, params);
            errdefer program_builder.deinit();
            try body(&program_builder, context);
            try program_builder.return_();
            return program_builder.finish();
        }

        pub fn defineWithDiagnostic(
            allocator: std.mem.Allocator,
            limits: Limits,
            kernel_name: []const u8,
            params: []const builder.Param,
            context: anytype,
            comptime body: anytype,
            diagnostic: *builder.VerificationDiagnostic,
        ) !Program {
            var program_builder = try Builder.init(allocator, limits, kernel_name, params);
            errdefer program_builder.deinit();
            try body(&program_builder, context);
            try program_builder.return_();
            return program_builder.finishWithDiagnostic(diagnostic);
        }

        pub const Guard = guard_mod.Guard(Builder);

        pub const Builder = struct {
            capacity: graph.Capacity,
            body: builder.Builder,
            schedule: schedule_mod.Schedule,
            body_active: bool = true,
            schedule_active: bool = true,

            pub const Result: type = Program;
            pub const Limits = core.Limits;
            pub const Capacity = graph.Capacity;

            pub fn init(
                allocator: std.mem.Allocator,
                limits: @This().Limits,
                kernel_name: []const u8,
                params: []const builder.Param,
            ) !Builder {
                const capacity = try graph.Capacity.derive(limits);
                var body = try builder.Builder.init(
                    allocator,
                    limits.raw(),
                    kernel_name,
                    params,
                    context_requirements,
                );
                errdefer body.deinit();
                var schedule = try schedule_mod.Schedule.init(allocator, limits.schedule);
                errdefer schedule.deinit(allocator);

                return .{
                    .capacity = capacity,
                    .body = body,
                    .schedule = schedule,
                };
            }

            pub fn initBorrowing(
                allocator: std.mem.Allocator,
                limits: @This().Limits,
                ir_ctx: *ir.Context,
                kernel_name: []const u8,
                params: []const builder.Param,
            ) !Builder {
                const capacity = try graph.Capacity.deriveBorrowing(limits);
                var body = try builder.Builder.initBorrowing(
                    allocator,
                    limits.raw(),
                    ir_ctx,
                    kernel_name,
                    params,
                );
                errdefer body.deinit();
                var schedule = try schedule_mod.Schedule.init(allocator, limits.schedule);
                errdefer schedule.deinit(allocator);

                return .{
                    .capacity = capacity,
                    .body = body,
                    .schedule = schedule,
                };
            }

            pub fn deinit(self: *Builder) void {
                const allocator = self.body.allocator;
                if (self.body_active) self.body.deinit();
                if (self.schedule_active) self.schedule.deinit(allocator);
                self.* = undefined;
            }

            pub fn finish(self: *Builder) !Program {
                return self.finishKernel(try self.body.finish());
            }

            pub fn finishWithDiagnostic(
                self: *Builder,
                diagnostic: *builder.VerificationDiagnostic,
            ) !Program {
                return self.finishKernel(try self.body.finishWithDiagnostic(diagnostic));
            }

            fn finishKernel(self: *Builder, finished_kernel: builder.Kernel) !Program {
                var kernel = finished_kernel;
                errdefer kernel.deinit();

                var schedule = self.schedule;
                schedule.activate();
                self.body_active = false;
                self.schedule_active = false;

                return Program.init(kernel, schedule, self.capacity);
            }

            pub const axis = surface_schedule.axis;
            pub const split = surface_schedule.split;
            pub const bind = surface_schedule.bind;
            pub const vectorize = surface_schedule.vectorize;
            pub const unroll = surface_schedule.unroll;

            pub const index1D = surface_domain.index1D;
            pub const vectorIndex1D = surface_domain.vectorIndex1D;
            pub const index2D = surface_domain.index2D;
            pub const index3D = surface_domain.index3D;
            pub const guardIndexDo = surface_domain.guardIndexDo;
            pub const guardVectorIndexDo = surface_domain.guardVectorIndexDo;
            pub const guardIndex2DDo = surface_domain.guardIndex2DDo;
            pub const guardIndex3DDo = surface_domain.guardIndex3DDo;
            pub const forEach1D = surface_domain.forEach1D;
            pub const forEachVector1D = surface_domain.forEachVector1D;
            pub const forEach2D = surface_domain.forEach2D;
            pub const forEach3D = surface_domain.forEach3D;

            pub const guard = surface_guard.guard;
            pub const guardIndex = surface_guard.guardIndex;
            pub const guardDo = surface_guard.guardDo;

            pub const argument = surface_primitive.argument;
            pub const entryBlock = surface_primitive.entryBlock;
            pub const insertionBlock = surface_primitive.insertionBlock;
            pub const setInsertionBlock = surface_primitive.setInsertionBlock;
            pub const enterBlock = surface_primitive.enterBlock;
            pub const globalId = surface_primitive.globalId;
            pub const threadId = surface_primitive.threadId;
            pub const blockId = surface_primitive.blockId;
            pub const blockDim = surface_primitive.blockDim;
            pub const gridDim = surface_primitive.gridDim;
            pub const laneId = surface_primitive.laneId;
            pub const warpId = surface_primitive.warpId;
            pub const constantInt = surface_primitive.constantInt;
            pub const constantIndex = surface_primitive.constantIndex;
            pub const constantFloat = surface_primitive.constantFloat;
            pub const constantBool = surface_primitive.constantBool;
            pub const add = surface_primitive.add;
            pub const sub = surface_primitive.sub;
            pub const mul = surface_primitive.mul;
            pub const umulhi = surface_primitive.umulhi;
            pub const div = surface_primitive.div;
            pub const min = surface_primitive.min;
            pub const max = surface_primitive.max;
            pub const and_ = surface_primitive.and_;
            pub const or_ = surface_primitive.or_;
            pub const xor = surface_primitive.xor;
            pub const not = surface_primitive.not;
            pub const popcount = surface_primitive.popcount;
            pub const shl = surface_primitive.shl;
            pub const shr = surface_primitive.shr;
            pub const ushr = surface_primitive.ushr;
            pub const bitcast = surface_primitive.bitcast;
            pub const neg = surface_primitive.neg;
            pub const abs = surface_primitive.abs;
            pub const splatVector = surface_primitive.splatVector;
            pub const shuffleVector = surface_primitive.shuffleVector;
            pub const extractLane = surface_primitive.extractLane;
            pub const insertLane = surface_primitive.insertLane;
            pub const packVector = surface_primitive.packVector;
            pub const sqrt = surface_primitive.sqrt;
            pub const exp = surface_primitive.exp;
            pub const log = surface_primitive.log;
            pub const tanh = surface_primitive.tanh;
            pub const sin = surface_primitive.sin;
            pub const cos = surface_primitive.cos;
            pub const tan = surface_primitive.tan;
            pub const floor = surface_primitive.floor;
            pub const round = surface_primitive.round;
            pub const trunc = surface_primitive.trunc;
            pub const tf32Round = surface_primitive.tf32Round;
            pub const pow = surface_primitive.pow;
            pub const atan2 = surface_primitive.atan2;
            pub const fma = surface_primitive.fma;
            pub const compare = surface_primitive.compare;
            pub const select = surface_primitive.select;
            pub const cast = surface_primitive.cast;
            pub const castIndex = surface_primitive.castIndex;
            pub const load = surface_primitive.load;
            pub const loadVector = surface_primitive.loadVector;
            pub const linearIndex = surface_primitive.linearIndex;
            pub const loadIndex = surface_primitive.loadIndex;
            pub const loadVectorIndex = surface_primitive.loadVectorIndex;
            pub const sharedBuffer = surface_primitive.sharedBuffer;
            pub const dynamicSharedBuffer = surface_primitive.dynamicSharedBuffer;
            pub const store = surface_primitive.store;
            pub const storeIndex = surface_primitive.storeIndex;
            pub const atomicRmw = surface_primitive.atomicRmw;
            pub const atomicCas = surface_primitive.atomicCas;
            pub const barrier = surface_primitive.barrier;
            pub const activeMask = surface_primitive.activeMask;
            pub const syncWarp = surface_primitive.syncWarp;
            pub const allSync = surface_primitive.allSync;
            pub const anySync = surface_primitive.anySync;
            pub const ballotSync = surface_primitive.ballotSync;
            pub const mmaSync = surface_primitive.mmaSync;
            pub const fence = surface_primitive.fence;
            pub const asyncCopyShared = surface_primitive.asyncCopyShared;
            pub const asyncCopyCommit = surface_primitive.asyncCopyCommit;
            pub const asyncCopyWait = surface_primitive.asyncCopyWait;
            pub const if_ = surface_primitive.if_;
            pub const for_ = surface_primitive.for_;
            pub const forScope = surface_primitive.forScope;
            pub const while_ = surface_primitive.while_;
            pub const whileScope = surface_primitive.whileScope;
            pub const yield_ = surface_primitive.yield_;
            pub const return_ = surface_primitive.return_;

            pub const typedArgument = builder_typed.typedArgument;
            pub const typedValue = builder_typed.typedValue;
            pub const castValue = builder_typed.castValue;
            pub const bufferArgument = builder_typed.bufferArgument;
            pub const bufferView = builder_typed.bufferView;
            pub const globalIdValue = builder_typed.globalIdValue;
            pub const threadIdValue = builder_typed.threadIdValue;
            pub const blockIdValue = builder_typed.blockIdValue;
            pub const blockDimValue = builder_typed.blockDimValue;
            pub const gridDimValue = builder_typed.gridDimValue;
            pub const laneIdValue = builder_typed.laneIdValue;
            pub const warpIdValue = builder_typed.warpIdValue;
            pub const constantValue = builder_typed.constantValue;
            pub const linearIndexValue = builder_typed.linearIndexValue;
            pub const sharedBufferView = builder_typed.sharedBufferView;
            pub const vec2 = builder_typed.vec2;
            pub const typedVec2 = builder_typed.typedVec2;
            pub const vec3 = builder_typed.vec3;
            pub const typedVec3 = builder_typed.typedVec3;
            pub const splat2 = builder_typed.splat2;
            pub const typedSplat2 = builder_typed.typedSplat2;
            pub const splat3 = builder_typed.splat3;
            pub const typedSplat3 = builder_typed.typedSplat3;
            pub const activeMaskValue = builder_typed.activeMaskValue;
            pub const allSyncValue = builder_typed.allSyncValue;
            pub const anySyncValue = builder_typed.anySyncValue;
            pub const ballotSyncValue = builder_typed.ballotSyncValue;
            pub const warpReduce = builder_typed.warpReduce;
            pub const warpScan = builder_typed.warpScan;
            pub const shuffleSync = builder_typed.shuffleSync;

            pub const forDo = surface_flow.forDo;
            pub const forValueDo = surface_flow.forValueDo;
            pub const fold = surface_flow.fold;
            pub const whileLoop = surface_flow.whileLoop;
            pub const forRangeDo = surface_flow.forRangeDo;
            pub const forRangeValueDo = surface_flow.forRangeValueDo;
            pub const foldRange = surface_flow.foldRange;
        };
    };
}

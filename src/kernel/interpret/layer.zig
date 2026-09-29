const std = @import("std");
const gpu_abi = @import("gpu_abi");

const builder = @import("../root.zig").builder;
const contexts = @import("context/root.zig");
const policy = @import("policy.zig");
const program = @import("../program/root.zig");
const typed = @import("../root.zig").typed;

const DType = gpu_abi.DType;

fn stateHandle(comptime StateType: type) type {
    return switch (@typeInfo(StateType)) {
        .pointer => StateType,
        else => *StateType,
    };
}

fn stateResult(comptime StateType: type) type {
    return switch (@typeInfo(StateType)) {
        .pointer => |info| info.child.Result,
        else => StateType.Result,
    };
}

fn LayerResult(comptime Next: type, comptime Impl: type) type {
    if (@hasDecl(Impl, "Result")) return Impl.Result;
    return stateResult(Next);
}

fn forScopePayload(comptime Handle: type) type {
    const Return = @TypeOf(@as(Handle, undefined).forScope(
        @as(builder.Value, undefined),
        @as(builder.Value, undefined),
        @as(builder.Value, undefined),
        @as([]const builder.Value, undefined),
        @as([]const builder.Type, undefined),
    ));
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => @compileError("forScope must return an error union"),
    };
}

fn whileScopePayload(comptime Handle: type) type {
    const Return = @TypeOf(@as(Handle, undefined).whileScope(
        @as([]const builder.Value, undefined),
        @as([]const builder.Type, undefined),
    ));
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => @compileError("whileScope must return an error union"),
    };
}

fn LayerWhileScope(comptime Owner: type, comptime Handle: type, comptime Scope: type, comptime Impl: type) type {
    return struct {
        owner: *Owner,
        scope: Scope,
        loop: builder.While,

        const Self = @This();

        pub fn beforeArg(self: *const Self, index: usize) ?builder.Value {
            var ctx = contexts.WhileScopeBeforeArgContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "whileScopeBeforeArg")) return self.owner.impl.whileScopeBeforeArg(&ctx);
            return ctx.default();
        }

        pub fn afterArg(self: *const Self, index: usize) ?builder.Value {
            var ctx = contexts.WhileScopeAfterArgContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "whileScopeAfterArg")) return self.owner.impl.whileScopeAfterArg(&ctx);
            return ctx.default();
        }

        pub fn result(self: *const Self, index: usize) ?builder.Value {
            var ctx = contexts.WhileScopeResultContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "whileScopeResult")) return self.owner.impl.whileScopeResult(&ctx);
            return ctx.default();
        }

        pub fn condition(self: *Self, cond: builder.Value, args: []const builder.Value) !void {
            var ctx = contexts.WhileScopeConditionContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .condition = cond,
                .args = args,
            };
            if (comptime @hasDecl(Impl, "whileScopeCondition")) return self.owner.impl.whileScopeCondition(&ctx);
            return ctx.default();
        }

        pub fn leave(self: *Self, values: []const builder.Value) !void {
            var ctx = contexts.WhileScopeLeaveContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .values = values,
            };
            if (comptime @hasDecl(Impl, "whileScopeLeave")) return self.owner.impl.whileScopeLeave(&ctx);
            return ctx.default();
        }

        pub fn abort(self: *Self) void {
            var ctx = contexts.WhileScopeAbortContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
            };
            if (comptime @hasDecl(Impl, "whileScopeAbort")) return self.owner.impl.whileScopeAbort(&ctx);
            return ctx.default();
        }
    };
}

fn LayerForScope(comptime Owner: type, comptime Handle: type, comptime Scope: type, comptime Impl: type) type {
    return struct {
        owner: *Owner,
        scope: Scope,
        loop: builder.For,

        const Self = @This();

        pub fn inductionVar(self: *Self) builder.Value {
            var ctx = contexts.ForScopeInductionVarContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
            };
            if (comptime @hasDecl(Impl, "forScopeInductionVar")) return self.owner.impl.forScopeInductionVar(&ctx);
            return ctx.default();
        }

        pub fn iterArg(self: *Self, index: usize) ?builder.Value {
            var ctx = contexts.ForScopeIterArgContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "forScopeIterArg")) return self.owner.impl.forScopeIterArg(&ctx);
            return ctx.default();
        }

        pub fn result(self: *const Self, index: usize) ?builder.Value {
            var ctx = contexts.ForScopeResultContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "forScopeResult")) return self.owner.impl.forScopeResult(&ctx);
            return ctx.default();
        }

        pub fn leave(self: *Self, values: []const builder.Value) !void {
            var ctx = contexts.ForScopeLeaveContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
                .values = values,
            };
            if (comptime @hasDecl(Impl, "forScopeLeave")) return self.owner.impl.forScopeLeave(&ctx);
            return ctx.default();
        }

        pub fn abort(self: *Self) void {
            var ctx = contexts.ForScopeAbortContext(Handle, Scope){
                .next = self.owner.nextHandle(),
                .scope = &self.scope,
            };
            if (comptime @hasDecl(Impl, "forScopeAbort")) return self.owner.impl.forScopeAbort(&ctx);
            return ctx.default();
        }
    };
}

pub fn Layer(comptime Next: type, comptime Impl: type, comptime unhandled: policy.Unhandled) type {
    return struct {
        next: Next,
        impl: Impl,

        const Self = @This();
        const Handle: type = stateHandle(Next);
        const NextForScope: type = forScopePayload(Handle);
        const NextWhileScope: type = whileScopePayload(Handle);

        pub const Result: type = LayerResult(Next, Impl);
        pub const ForScope: type = LayerForScope(Self, Handle, NextForScope, Impl);
        pub const WhileScope: type = LayerWhileScope(Self, Handle, NextWhileScope, Impl);

        fn nextHandle(self: *Self) stateHandle(Next) {
            return switch (@typeInfo(Next)) {
                .pointer => self.next,
                else => &self.next,
            };
        }

        pub fn finish(self: *Self) !Self.Result {
            var ctx = contexts.FinishContext(stateHandle(Next)){ .next = self.nextHandle() };
            if (comptime @hasDecl(Impl, "finish")) return self.impl.finish(&ctx);
            return ctx.default();
        }

        pub fn return_(self: *Self) !void {
            var ctx = contexts.ReturnContext(stateHandle(Next)){ .next = self.nextHandle() };
            if (comptime @hasDecl(Impl, "return_")) return self.impl.return_(&ctx);
            return ctx.default();
        }

        pub fn argument(self: *Self, index: usize) builder.Value {
            return self.nextHandle().argument(index);
        }

        pub fn typedArgument(self: *Self, comptime dtype: DType, index: usize) program.TypedValue(dtype) {
            return self.nextHandle().typedArgument(dtype, index);
        }

        pub fn bufferArgument(self: *Self, comptime dtype: DType, index: usize) program.BufferView(dtype) {
            return self.nextHandle().bufferArgument(dtype, index);
        }

        pub fn bufferView(self: *Self, comptime dtype: DType, value: builder.Value) program.BufferView(dtype) {
            _ = self;
            return program.BufferView(dtype).init(value);
        }

        pub fn entryBlock(self: *Self) builder.Block {
            return self.nextHandle().entryBlock();
        }

        pub fn insertionBlock(self: *Self) builder.Block {
            return self.nextHandle().insertionBlock();
        }

        pub fn setInsertionBlock(self: *Self, block: builder.Block) void {
            self.nextHandle().setInsertionBlock(block);
        }

        pub fn enterBlock(self: *Self, block: builder.Block) !builder.InsertionScope {
            return self.nextHandle().enterBlock(block);
        }

        pub fn typedValue(self: *Self, comptime dtype: DType, value: builder.Value) program.TypedValue(dtype) {
            return self.nextHandle().typedValue(dtype, value);
        }

        pub fn castValue(self: *Self, input: anytype, comptime dtype: DType) !program.TypedValue(dtype) {
            return self.typedValue(dtype, try self.cast(typed.raw(input), dtype));
        }

        pub fn constantInt(self: *Self, dtype: DType, value: i64) !builder.Value {
            var ctx = contexts.ConstantIntContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dtype = dtype,
                .value = value,
            };
            if (comptime @hasDecl(Impl, "constantInt")) return self.impl.constantInt(&ctx);
            return ctx.default();
        }

        pub fn constantIndex(self: *Self, value: i64) !builder.Value {
            var ctx = contexts.ConstantIndexContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .value = value,
            };
            if (comptime @hasDecl(Impl, "constantIndex")) return self.impl.constantIndex(&ctx);
            return ctx.default();
        }

        pub fn constantFloat(self: *Self, dtype: DType, value: f64) !builder.Value {
            var ctx = contexts.ConstantFloatContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dtype = dtype,
                .value = value,
            };
            if (comptime @hasDecl(Impl, "constantFloat")) return self.impl.constantFloat(&ctx);
            return ctx.default();
        }

        pub fn constantBool(self: *Self, value: bool) !builder.Value {
            var ctx = contexts.ConstantBoolContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .value = value,
            };
            if (comptime @hasDecl(Impl, "constantBool")) return self.impl.constantBool(&ctx);
            return ctx.default();
        }

        pub fn constantValue(self: *Self, comptime dtype: DType, value: anytype) !program.TypedValue(dtype) {
            return self.typedValue(dtype, switch (dtype) {
                .i1 => try self.constantBool(value),
                .i8, .i16, .i32, .i64 => try self.constantInt(dtype, std.math.cast(i64, value) orelse return error.IntegerOutOfBounds),
                .f16, .bf16, .f32, .f64 => try self.constantFloat(dtype, contexts.literalFloat(value)),
                else => return error.UnsupportedDType,
            });
        }

        pub fn linearIndex(self: *Self, index: anytype) !builder.Value {
            const Index = @TypeOf(index);
            if (comptime Index == builder.Value) return index;
            switch (comptime @typeInfo(Index)) {
                .int, .comptime_int => return self.constantIndex(std.math.cast(i64, index) orelse return error.IntegerOutOfBounds),
                else => return index.linear(self),
            }
        }

        pub fn linearIndexValue(self: *Self, index: anytype, comptime dtype: DType) !program.TypedValue(dtype) {
            return self.castValue(try self.linearIndex(index), dtype);
        }

        pub fn load(self: *Self, memref: builder.Value, index: builder.Value) !builder.Value {
            var ctx = contexts.LoadContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .memref = memref,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "load")) return self.impl.load(&ctx);
            return ctx.default();
        }

        pub fn loadIndex(self: *Self, memref: builder.Value, index: anytype) !builder.Value {
            const Index = @TypeOf(index);
            var ctx = contexts.LoadIndexContext(stateHandle(Next), Index){
                .next = self.nextHandle(),
                .memref = memref,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "loadIndex")) return self.impl.loadIndex(&ctx);
            if (comptime unhandled.indexed == .bind) return ctx.default();
            return self.load(memref, try self.linearIndex(index));
        }

        pub fn store(self: *Self, value: builder.Value, memref: builder.Value, index: builder.Value) !void {
            var ctx = contexts.StoreContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .value = value,
                .memref = memref,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "store")) return self.impl.store(&ctx);
            return ctx.default();
        }

        pub fn storeIndex(self: *Self, value: builder.Value, memref: builder.Value, index: anytype) !void {
            const Index = @TypeOf(index);
            var ctx = contexts.StoreIndexContext(stateHandle(Next), Index){
                .next = self.nextHandle(),
                .value = value,
                .memref = memref,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "storeIndex")) return self.impl.storeIndex(&ctx);
            if (comptime unhandled.indexed == .bind) return ctx.default();
            try self.store(value, memref, try self.linearIndex(index));
        }

        pub fn atomicRmw(
            self: *Self,
            kind: builder.AtomicRmwKind,
            value: builder.Value,
            memref: builder.Value,
            index: builder.Value,
        ) !builder.Value {
            var ctx = contexts.AtomicRmwContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .kind = kind,
                .value = value,
                .memref = memref,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "atomicRmw")) return self.impl.atomicRmw(&ctx);
            return ctx.default();
        }

        pub fn atomicRmwIndex(
            self: *Self,
            kind: builder.AtomicRmwKind,
            value: builder.Value,
            memref: builder.Value,
            index: anytype,
        ) !builder.Value {
            return self.atomicRmw(kind, value, memref, try self.linearIndex(index));
        }

        pub fn atomicCas(
            self: *Self,
            expected: builder.Value,
            desired: builder.Value,
            memref: builder.Value,
            index: builder.Value,
        ) !builder.Value {
            var ctx = contexts.AtomicCasContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .expected = expected,
                .desired = desired,
                .memref = memref,
                .index = index,
            };
            if (comptime @hasDecl(Impl, "atomicCas")) return self.impl.atomicCas(&ctx);
            return ctx.default();
        }

        pub fn atomicCasIndex(
            self: *Self,
            expected: builder.Value,
            desired: builder.Value,
            memref: builder.Value,
            index: anytype,
        ) !builder.Value {
            return self.atomicCas(expected, desired, memref, try self.linearIndex(index));
        }

        pub fn add(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.AddContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "add")) return self.impl.add(&ctx);
            return ctx.default();
        }

        pub fn sub(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.SubContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "sub")) return self.impl.sub(&ctx);
            return ctx.default();
        }

        pub fn mul(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.MulContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "mul")) return self.impl.mul(&ctx);
            return ctx.default();
        }

        pub fn umulhi(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.UmulhiContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "umulhi")) return self.impl.umulhi(&ctx);
            return ctx.default();
        }

        pub fn div(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.DivContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "div")) return self.impl.div(&ctx);
            return ctx.default();
        }

        pub fn and_(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.AndContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "and_")) return self.impl.and_(&ctx);
            return ctx.default();
        }

        pub fn or_(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.OrContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "or_")) return self.impl.or_(&ctx);
            return ctx.default();
        }

        pub fn xor(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.XorContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "xor")) return self.impl.xor(&ctx);
            return ctx.default();
        }

        pub fn not(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.NotContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "not")) return self.impl.not(&ctx);
            return ctx.default();
        }

        pub fn popcount(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.PopCountContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "popcount")) return self.impl.popcount(&ctx);
            return ctx.default();
        }

        pub fn shl(self: *Self, value: builder.Value, shift: builder.Value) !builder.Value {
            var ctx = contexts.ShlContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .value = value,
                .shift = shift,
            };
            if (comptime @hasDecl(Impl, "shl")) return self.impl.shl(&ctx);
            return ctx.default();
        }

        pub fn shr(self: *Self, value: builder.Value, shift: builder.Value) !builder.Value {
            var ctx = contexts.ShrContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .value = value,
                .shift = shift,
            };
            if (comptime @hasDecl(Impl, "shr")) return self.impl.shr(&ctx);
            return ctx.default();
        }

        pub fn ushr(self: *Self, value: builder.Value, shift: builder.Value) !builder.Value {
            var ctx = contexts.UshrContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .value = value,
                .shift = shift,
            };
            if (comptime @hasDecl(Impl, "ushr")) return self.impl.ushr(&ctx);
            return ctx.default();
        }

        pub fn bitcast(self: *Self, input: builder.Value, dtype: DType) !builder.Value {
            var ctx = contexts.BitcastContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
                .dtype = dtype,
            };
            if (comptime @hasDecl(Impl, "bitcast")) return self.impl.bitcast(&ctx);
            return ctx.default();
        }

        pub fn min(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.MinContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "min")) return self.impl.min(&ctx);
            return ctx.default();
        }

        pub fn max(self: *Self, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.MaxContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "max")) return self.impl.max(&ctx);
            return ctx.default();
        }

        pub fn neg(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.NegContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "neg")) return self.impl.neg(&ctx);
            return ctx.default();
        }

        pub fn abs(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.AbsContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "abs")) return self.impl.abs(&ctx);
            return ctx.default();
        }

        pub fn sin(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.SinContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "sin")) return self.impl.sin(&ctx);
            return ctx.default();
        }

        pub fn cos(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.CosContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "cos")) return self.impl.cos(&ctx);
            return ctx.default();
        }

        pub fn exp(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.ExpContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "exp")) return self.impl.exp(&ctx);
            return ctx.default();
        }

        pub fn sqrt(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.SqrtContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "sqrt")) return self.impl.sqrt(&ctx);
            return ctx.default();
        }

        pub fn log(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.LogContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "log")) return self.impl.log(&ctx);
            return ctx.default();
        }

        pub fn tanh(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.TanhContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "tanh")) return self.impl.tanh(&ctx);
            return ctx.default();
        }

        pub fn tan(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.TanContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "tan")) return self.impl.tan(&ctx);
            return ctx.default();
        }

        pub fn floor(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.FloorContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "floor")) return self.impl.floor(&ctx);
            return ctx.default();
        }

        pub fn round(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.RoundContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "round")) return self.impl.round(&ctx);
            return ctx.default();
        }

        pub fn trunc(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.TruncContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "trunc")) return self.impl.trunc(&ctx);
            return ctx.default();
        }

        pub fn pow(self: *Self, base: builder.Value, exponent: builder.Value) !builder.Value {
            var ctx = contexts.PowContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .base = base,
                .exponent = exponent,
            };
            if (comptime @hasDecl(Impl, "pow")) return self.impl.pow(&ctx);
            return ctx.default();
        }

        pub fn atan2(self: *Self, y: builder.Value, x: builder.Value) !builder.Value {
            var ctx = contexts.Atan2Context(stateHandle(Next)){
                .next = self.nextHandle(),
                .y = y,
                .x = x,
            };
            if (comptime @hasDecl(Impl, "atan2")) return self.impl.atan2(&ctx);
            return ctx.default();
        }

        pub fn fma(self: *Self, a: builder.Value, b: builder.Value, c: builder.Value) !builder.Value {
            var ctx = contexts.FmaContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .a = a,
                .b = b,
                .c = c,
            };
            if (comptime @hasDecl(Impl, "fma")) return self.impl.fma(&ctx);
            return ctx.default();
        }

        pub fn compare(self: *Self, predicate: builder.Compare, lhs: builder.Value, rhs: builder.Value) !builder.Value {
            var ctx = contexts.CompareContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .predicate = predicate,
                .lhs = lhs,
                .rhs = rhs,
            };
            if (comptime @hasDecl(Impl, "compare")) return self.impl.compare(&ctx);
            return ctx.default();
        }

        pub fn cast(self: *Self, input: builder.Value, dtype: DType) !builder.Value {
            var ctx = contexts.CastContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
                .dtype = dtype,
            };
            if (comptime @hasDecl(Impl, "cast")) return self.impl.cast(&ctx);
            return ctx.default();
        }

        pub fn sharedBuffer(self: *Self, dtype: DType, size: u64) !builder.Value {
            var ctx = contexts.SharedBufferContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dtype = dtype,
                .size = size,
            };
            if (comptime @hasDecl(Impl, "sharedBuffer")) return self.impl.sharedBuffer(&ctx);
            return ctx.default();
        }

        pub fn sharedBufferView(self: *Self, comptime dtype: DType, size: u64) !program.BufferView(dtype) {
            return self.bufferView(dtype, try self.sharedBuffer(dtype, size));
        }

        pub fn vec2(self: *Self, x: builder.Value, y: builder.Value) program.Vec2 {
            _ = self;
            return program.Vec2.init(x, y);
        }

        pub fn typedVec2(self: *Self, comptime dtype: DType, x: anytype, y: anytype) !program.TypedVec2(dtype) {
            return program.TypedVec2(dtype).init(
                try program.TypedValue(dtype).from(self, x),
                try program.TypedValue(dtype).from(self, y),
            );
        }

        pub fn vec3(self: *Self, x: builder.Value, y: builder.Value, z: builder.Value) program.Vec3 {
            _ = self;
            return program.Vec3.init(x, y, z);
        }

        pub fn typedVec3(self: *Self, comptime dtype: DType, x: anytype, y: anytype, z: anytype) !program.TypedVec3(dtype) {
            return program.TypedVec3(dtype).init(
                try program.TypedValue(dtype).from(self, x),
                try program.TypedValue(dtype).from(self, y),
                try program.TypedValue(dtype).from(self, z),
            );
        }

        pub fn splat2(self: *Self, value: builder.Value) program.Vec2 {
            _ = self;
            return program.Vec2.splat(value);
        }

        pub fn typedSplat2(self: *Self, comptime dtype: DType, value: anytype) !program.TypedVec2(dtype) {
            return program.TypedVec2(dtype).splat(try program.TypedValue(dtype).from(self, value));
        }

        pub fn splat3(self: *Self, value: builder.Value) program.Vec3 {
            _ = self;
            return program.Vec3.splat(value);
        }

        pub fn typedSplat3(self: *Self, comptime dtype: DType, value: anytype) !program.TypedVec3(dtype) {
            return program.TypedVec3(dtype).splat(try program.TypedValue(dtype).from(self, value));
        }

        pub fn barrier(self: *Self, scope: builder.Scope) !void {
            var ctx = contexts.BarrierContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .scope = scope,
            };
            if (comptime @hasDecl(Impl, "barrier")) return self.impl.barrier(&ctx);
            return ctx.default();
        }

        pub fn select(self: *Self, condition: builder.Value, true_value: builder.Value, false_value: builder.Value) !builder.Value {
            var ctx = contexts.SelectContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .condition = condition,
                .true_value = true_value,
                .false_value = false_value,
            };
            if (comptime @hasDecl(Impl, "select")) return self.impl.select(&ctx);
            return ctx.default();
        }

        pub fn castIndex(self: *Self, input: builder.Value) !builder.Value {
            var ctx = contexts.CastIndexContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .input = input,
            };
            if (comptime @hasDecl(Impl, "castIndex")) return self.impl.castIndex(&ctx);
            return ctx.default();
        }

        pub fn globalId(self: *Self, dim: builder.Dimension) !builder.Value {
            var ctx = contexts.GlobalIdContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dim = dim,
            };
            if (comptime @hasDecl(Impl, "globalId")) return self.impl.globalId(&ctx);
            return ctx.default();
        }

        pub fn globalIdValue(self: *Self, comptime dtype: DType, dim: builder.Dimension) !program.TypedValue(dtype) {
            return self.castValue(try self.globalId(dim), dtype);
        }

        pub fn if_(self: *Self, condition: builder.Value, result_types: []const builder.Type) !builder.If {
            var ctx = contexts.IfContext(Handle){
                .next = self.nextHandle(),
                .condition = condition,
                .result_types = result_types,
            };
            if (comptime @hasDecl(Impl, "if_")) return self.impl.if_(&ctx);
            return ctx.default();
        }

        pub fn for_(self: *Self, lower: builder.Value, upper: builder.Value, step: builder.Value, init_args: []const builder.Value, result_types: []const builder.Type) !builder.For {
            var ctx = contexts.ForContext(Handle){
                .next = self.nextHandle(),
                .lower = lower,
                .upper = upper,
                .step = step,
                .init_args = init_args,
                .result_types = result_types,
            };
            if (comptime @hasDecl(Impl, "for_")) return self.impl.for_(&ctx);
            return ctx.default();
        }

        pub fn forScope(self: *Self, lower: builder.Value, upper: builder.Value, step: builder.Value, init_args: []const builder.Value, result_types: []const builder.Type) !ForScope {
            var ctx = contexts.ForScopeContext(Handle, NextForScope){
                .next = self.nextHandle(),
                .lower = lower,
                .upper = upper,
                .step = step,
                .init_args = init_args,
                .result_types = result_types,
            };
            const scope = if (comptime @hasDecl(Impl, "forScope")) try self.impl.forScope(&ctx) else try ctx.default();
            return .{
                .owner = self,
                .scope = scope,
                .loop = scope.loop,
            };
        }

        pub fn while_(self: *Self, init_args: []const builder.Value, result_types: []const builder.Type) !builder.While {
            var ctx = contexts.WhileContext(Handle){
                .next = self.nextHandle(),
                .init_args = init_args,
                .result_types = result_types,
            };
            if (comptime @hasDecl(Impl, "while_")) return self.impl.while_(&ctx);
            return ctx.default();
        }

        pub fn whileScope(self: *Self, init_args: []const builder.Value, result_types: []const builder.Type) !WhileScope {
            var ctx = contexts.WhileScopeContext(Handle, NextWhileScope){
                .next = self.nextHandle(),
                .init_args = init_args,
                .result_types = result_types,
            };
            const scope = if (comptime @hasDecl(Impl, "whileScope")) try self.impl.whileScope(&ctx) else try ctx.default();
            return .{
                .owner = self,
                .scope = scope,
                .loop = scope.loop,
            };
        }

        pub fn forDo(self: *Self, lower: builder.Value, upper: builder.Value, step: builder.Value, context: anytype, comptime body: anytype) !builder.For {
            var scope = try self.forScope(lower, upper, step, &.{}, &.{});
            errdefer scope.abort();
            try body(self, scope.inductionVar(), context);
            try scope.leave(&.{});
            return scope.loop;
        }

        pub fn forValueDo(self: *Self, comptime dtype: DType, lower: builder.Value, upper: builder.Value, step: builder.Value, context: anytype, comptime body: anytype) !builder.For {
            var scope = try self.forScope(lower, upper, step, &.{}, &.{});
            errdefer scope.abort();
            try body(self, try self.castValue(scope.inductionVar(), dtype), context);
            try scope.leave(&.{});
            return scope.loop;
        }

        pub fn fold(self: *Self, lower: builder.Value, upper: builder.Value, step: builder.Value, initial: anytype, context: anytype, comptime body: anytype) !@TypeOf(initial) {
            var ctx = contexts.FoldContext(Self, stateHandle(Next), @TypeOf(initial), @TypeOf(context), body){
                .owner = self,
                .next = self.nextHandle(),
                .lower = lower,
                .upper = upper,
                .step = step,
                .initial = initial,
                .context = context,
            };
            if (comptime @hasDecl(Impl, "fold")) return self.impl.fold(&ctx);
            if (comptime unhandled.regions == .bind) return self.nextHandle().fold(lower, upper, step, initial, context, body);
            return ctx.default();
        }

        pub fn whileLoop(self: *Self, initial: anytype, context: anytype, comptime condition: anytype, comptime body: anytype) !@TypeOf(initial) {
            var ctx = contexts.WhileLoopContext(Self, stateHandle(Next), @TypeOf(initial), @TypeOf(context), condition, body){
                .owner = self,
                .next = self.nextHandle(),
                .initial = initial,
                .context = context,
            };
            if (comptime @hasDecl(Impl, "whileLoop")) return self.impl.whileLoop(&ctx);
            if (comptime unhandled.regions == .bind) return self.nextHandle().whileLoop(initial, context, condition, body);
            return ctx.default();
        }

        pub fn foldRange(self: *Self, lower: i64, upper: i64, step: i64, initial: anytype, context: anytype, comptime body: anytype) !@TypeOf(initial) {
            const lower_value = try self.constantIndex(lower);
            const upper_value = try self.constantIndex(upper);
            const step_value = try self.constantIndex(step);
            return self.fold(lower_value, upper_value, step_value, initial, context, body);
        }

        pub fn forRangeDo(self: *Self, lower: i64, upper: i64, step: i64, context: anytype, comptime body: anytype) !builder.For {
            const lower_value = try self.constantIndex(lower);
            const upper_value = try self.constantIndex(upper);
            const step_value = try self.constantIndex(step);
            return self.forDo(lower_value, upper_value, step_value, context, body);
        }

        pub fn forRangeValueDo(self: *Self, comptime dtype: DType, lower: i64, upper: i64, step: i64, context: anytype, comptime body: anytype) !builder.For {
            const lower_value = try self.constantIndex(lower);
            const upper_value = try self.constantIndex(upper);
            const step_value = try self.constantIndex(step);
            return self.forValueDo(dtype, lower_value, upper_value, step_value, context, body);
        }

        pub fn yield_(self: *Self, values: []const builder.Value) !void {
            var ctx = contexts.YieldContext(Handle){
                .next = self.nextHandle(),
                .values = values,
            };
            if (comptime @hasDecl(Impl, "yield_")) return self.impl.yield_(&ctx);
            return ctx.default();
        }

        pub fn threadId(self: *Self, dim: builder.Dimension) !builder.Value {
            var ctx = contexts.ThreadIdContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dim = dim,
            };
            if (comptime @hasDecl(Impl, "threadId")) return self.impl.threadId(&ctx);
            return ctx.default();
        }

        pub fn threadIdValue(self: *Self, comptime dtype: DType, dim: builder.Dimension) !program.TypedValue(dtype) {
            return self.castValue(try self.threadId(dim), dtype);
        }

        pub fn blockId(self: *Self, dim: builder.Dimension) !builder.Value {
            var ctx = contexts.BlockIdContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dim = dim,
            };
            if (comptime @hasDecl(Impl, "blockId")) return self.impl.blockId(&ctx);
            return ctx.default();
        }

        pub fn blockIdValue(self: *Self, comptime dtype: DType, dim: builder.Dimension) !program.TypedValue(dtype) {
            return self.castValue(try self.blockId(dim), dtype);
        }

        pub fn blockDim(self: *Self, dim: builder.Dimension) !builder.Value {
            var ctx = contexts.BlockDimContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dim = dim,
            };
            if (comptime @hasDecl(Impl, "blockDim")) return self.impl.blockDim(&ctx);
            return ctx.default();
        }

        pub fn blockDimValue(self: *Self, comptime dtype: DType, dim: builder.Dimension) !program.TypedValue(dtype) {
            return self.castValue(try self.blockDim(dim), dtype);
        }

        pub fn gridDim(self: *Self, dim: builder.Dimension) !builder.Value {
            var ctx = contexts.GridDimContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .dim = dim,
            };
            if (comptime @hasDecl(Impl, "gridDim")) return self.impl.gridDim(&ctx);
            return ctx.default();
        }

        pub fn gridDimValue(self: *Self, comptime dtype: DType, dim: builder.Dimension) !program.TypedValue(dtype) {
            return self.castValue(try self.gridDim(dim), dtype);
        }

        pub fn guard(self: *Self, condition: anytype) !program.Guard {
            return self.nextHandle().guard(condition);
        }

        pub fn guardIndex(self: *Self, index: program.Index1D) !program.Guard {
            const in_bounds = try self.compare(.lt, index.index, index.bound);
            return self.guard(in_bounds);
        }

        pub fn guardDo(self: *Self, condition: anytype, context: anytype, comptime body: anytype) !void {
            var ctx = contexts.GuardDoContext(Self, stateHandle(Next), @TypeOf(condition), @TypeOf(context), body){
                .owner = self,
                .next = self.nextHandle(),
                .condition = condition,
                .context = context,
            };
            if (comptime @hasDecl(Impl, "guardDo")) return self.impl.guardDo(&ctx);
            if (comptime unhandled.regions == .bind) return self.nextHandle().guardDo(condition, context, body);
            return ctx.default();
        }

        pub fn guardIndexDo(self: *Self, index: program.Index1D, context: anytype, comptime body: anytype) !void {
            var ctx = contexts.GuardIndexDoContext(Self, stateHandle(Next), @TypeOf(context), body){
                .owner = self,
                .next = self.nextHandle(),
                .index = index,
                .context = context,
            };
            if (comptime @hasDecl(Impl, "guardIndexDo")) return self.impl.guardIndexDo(&ctx);
            if (comptime unhandled.regions == .bind) return self.nextHandle().guardIndexDo(index, context, body);
            return ctx.default();
        }

        pub fn guardIndex2DDo(self: *Self, index: program.Index2D, context: anytype, comptime body: anytype) !void {
            var ctx = contexts.GuardIndex2DDoContext(Self, stateHandle(Next), @TypeOf(context), body){
                .owner = self,
                .next = self.nextHandle(),
                .index = index,
                .context = context,
            };
            if (comptime @hasDecl(Impl, "guardIndex2DDo")) return self.impl.guardIndex2DDo(&ctx);
            if (comptime unhandled.regions == .bind) return self.nextHandle().guardIndex2DDo(index, context, body);
            return ctx.default();
        }

        pub fn guardIndex3DDo(self: *Self, index: program.Index3D, context: anytype, comptime body: anytype) !void {
            var ctx = contexts.GuardIndex3DDoContext(Self, stateHandle(Next), @TypeOf(context), body){
                .owner = self,
                .next = self.nextHandle(),
                .index = index,
                .context = context,
            };
            if (comptime @hasDecl(Impl, "guardIndex3DDo")) return self.impl.guardIndex3DDo(&ctx);
            if (comptime unhandled.regions == .bind) return self.nextHandle().guardIndex3DDo(index, context, body);
            return ctx.default();
        }

        pub fn index1D(self: *Self, name: []const u8, extent: u64, threads_per_block: u32) !program.Index1D {
            var ctx = contexts.Index1DContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .name = name,
                .extent = extent,
                .threads_per_block = threads_per_block,
            };
            if (comptime @hasDecl(Impl, "index1D")) return self.impl.index1D(&ctx);
            return ctx.default();
        }

        pub fn index2D(self: *Self, domain: program.Domain2D) !program.Index2D {
            var ctx = contexts.Index2DContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .domain = domain,
            };
            if (comptime @hasDecl(Impl, "index2D")) return self.impl.index2D(&ctx);
            return ctx.default();
        }

        pub fn index3D(self: *Self, domain: program.Domain3D) !program.Index3D {
            var ctx = contexts.Index3DContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .domain = domain,
            };
            if (comptime @hasDecl(Impl, "index3D")) return self.impl.index3D(&ctx);
            return ctx.default();
        }

        pub fn forEach1D(self: *Self, name: []const u8, extent: u64, threads_per_block: u32, context: anytype, comptime body: anytype) !program.Index1D {
            if (comptime unhandled.regions == .bind) return self.nextHandle().forEach1D(name, extent, threads_per_block, context, body);
            const index = try self.index1D(name, extent, threads_per_block);
            try self.guardIndexDo(index, context, body);
            return index;
        }

        pub fn forEach2D(self: *Self, domain: program.Domain2D, context: anytype, comptime body: anytype) !program.Index2D {
            if (comptime unhandled.regions == .bind) return self.nextHandle().forEach2D(domain, context, body);
            const index = try self.index2D(domain);
            try self.guardIndex2DDo(index, context, body);
            return index;
        }

        pub fn forEach3D(self: *Self, domain: program.Domain3D, context: anytype, comptime body: anytype) !program.Index3D {
            if (comptime unhandled.regions == .bind) return self.nextHandle().forEach3D(domain, context, body);
            const index = try self.index3D(domain);
            try self.guardIndex3DDo(index, context, body);
            return index;
        }

        pub fn laneId(self: *Self) !builder.Value {
            var ctx = contexts.LaneIdContext(stateHandle(Next)){ .next = self.nextHandle() };
            if (comptime @hasDecl(Impl, "laneId")) return self.impl.laneId(&ctx);
            return ctx.default();
        }

        pub fn laneIdValue(self: *Self, comptime dtype: DType) !program.TypedValue(dtype) {
            return self.castValue(try self.laneId(), dtype);
        }

        pub fn warpId(self: *Self) !builder.Value {
            var ctx = contexts.WarpIdContext(stateHandle(Next)){ .next = self.nextHandle() };
            if (comptime @hasDecl(Impl, "warpId")) return self.impl.warpId(&ctx);
            return ctx.default();
        }

        pub fn warpIdValue(self: *Self, comptime dtype: DType) !program.TypedValue(dtype) {
            return self.castValue(try self.warpId(), dtype);
        }

        pub fn activeMask(self: *Self) !builder.Value {
            var ctx = contexts.ActiveMaskContext(stateHandle(Next)){ .next = self.nextHandle() };
            if (comptime @hasDecl(Impl, "activeMask")) return self.impl.activeMask(&ctx);
            return ctx.default();
        }

        pub fn activeMaskValue(self: *Self) !program.TypedValue(.i32) {
            return self.typedValue(.i32, try self.activeMask());
        }

        pub fn syncWarp(self: *Self) !void {
            var ctx = contexts.SyncWarpContext(stateHandle(Next)){ .next = self.nextHandle() };
            if (comptime @hasDecl(Impl, "syncWarp")) return self.impl.syncWarp(&ctx);
            return ctx.default();
        }

        pub fn allSync(self: *Self, predicate: builder.Value) !builder.Value {
            var ctx = contexts.AllSyncContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .predicate = predicate,
            };
            if (comptime @hasDecl(Impl, "allSync")) return self.impl.allSync(&ctx);
            return ctx.default();
        }

        pub fn allSyncValue(self: *Self, predicate: anytype) !program.TypedValue(.i1) {
            const pred = try program.TypedValue(.i1).from(self, predicate);
            return self.typedValue(.i1, try self.allSync(pred.raw()));
        }

        pub fn anySync(self: *Self, predicate: builder.Value) !builder.Value {
            var ctx = contexts.AnySyncContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .predicate = predicate,
            };
            if (comptime @hasDecl(Impl, "anySync")) return self.impl.anySync(&ctx);
            return ctx.default();
        }

        pub fn anySyncValue(self: *Self, predicate: anytype) !program.TypedValue(.i1) {
            const pred = try program.TypedValue(.i1).from(self, predicate);
            return self.typedValue(.i1, try self.anySync(pred.raw()));
        }

        pub fn ballotSync(self: *Self, predicate: builder.Value) !builder.Value {
            var ctx = contexts.BallotSyncContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .predicate = predicate,
            };
            if (comptime @hasDecl(Impl, "ballotSync")) return self.impl.ballotSync(&ctx);
            return ctx.default();
        }

        pub fn ballotSyncValue(self: *Self, predicate: anytype) !program.TypedValue(.i32) {
            const pred = try program.TypedValue(.i1).from(self, predicate);
            return self.typedValue(.i32, try self.ballotSync(pred.raw()));
        }

        pub fn warpReduce(self: *Self, op_kind: builder.WarpOpKind, value: anytype) !@TypeOf(value) {
            var ctx = contexts.WarpReduceContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .op_kind = op_kind,
                .value = typed.raw(value),
            };
            const result = if (comptime @hasDecl(Impl, "warpReduce")) try self.impl.warpReduce(&ctx) else try ctx.default();
            return typed.wrapValueLike(value, result);
        }

        pub fn warpScan(self: *Self, op_kind: builder.WarpOpKind, mode: builder.WarpScanMode, value: anytype) !@TypeOf(value) {
            var ctx = contexts.WarpScanContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .op_kind = op_kind,
                .mode = mode,
                .value = typed.raw(value),
            };
            const result = if (comptime @hasDecl(Impl, "warpScan")) try self.impl.warpScan(&ctx) else try ctx.default();
            return typed.wrapValueLike(value, result);
        }

        pub fn shuffleSync(self: *Self, mode: builder.ShuffleMode, value: anytype, lane_or_delta: anytype) !@TypeOf(value) {
            const lane = try program.TypedValue(.i32).from(self, lane_or_delta);
            var ctx = contexts.ShuffleSyncContext(stateHandle(Next)){
                .next = self.nextHandle(),
                .mode = mode,
                .value = typed.raw(value),
                .lane_or_delta = lane.raw(),
            };
            const result = if (comptime @hasDecl(Impl, "shuffleSync")) try self.impl.shuffleSync(&ctx) else try ctx.default();
            return typed.wrapValueLike(value, result);
        }
    };
}

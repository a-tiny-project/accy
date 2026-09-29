const builder = @import("../../../core/root.zig").builder;
const builder_primitive = @import("../primitive/root.zig");

pub const argument = builder_primitive.argument;
pub const entryBlock = builder_primitive.entryBlock;
pub const insertionBlock = builder_primitive.insertionBlock;
pub const setInsertionBlock = builder_primitive.setInsertionBlock;
pub const enterBlock = builder_primitive.enterBlock;
pub const globalId = builder_primitive.globalId;
pub const threadId = builder_primitive.threadId;
pub const blockId = builder_primitive.blockId;
pub const blockDim = builder_primitive.blockDim;
pub const gridDim = builder_primitive.gridDim;
pub const laneId = builder_primitive.laneId;
pub const warpId = builder_primitive.warpId;
pub const constantInt = builder_primitive.constantInt;
pub const constantIndex = builder_primitive.constantIndex;
pub const constantFloat = builder_primitive.constantFloat;
pub const constantBool = builder_primitive.constantBool;
pub const add = builder_primitive.add;
pub const sub = builder_primitive.sub;
pub const mul = builder_primitive.mul;
pub const umulhi = builder_primitive.umulhi;
pub const div = builder_primitive.div;
pub const min = builder_primitive.min;
pub const max = builder_primitive.max;
pub const and_ = builder_primitive.and_;
pub const or_ = builder_primitive.or_;
pub const xor = builder_primitive.xor;
pub const not = builder_primitive.not;
pub const popcount = builder_primitive.popcount;
pub const shl = builder_primitive.shl;
pub const shr = builder_primitive.shr;
pub const ushr = builder_primitive.ushr;
pub const bitcast = builder_primitive.bitcast;
pub const neg = builder_primitive.neg;
pub const abs = builder_primitive.abs;
pub const splatVector = builder_primitive.splatVector;
pub const shuffleVector = builder_primitive.shuffleVector;
pub const extractLane = builder_primitive.extractLane;
pub const insertLane = builder_primitive.insertLane;
pub const packVector = builder_primitive.packVector;
pub const sqrt = builder_primitive.sqrt;
pub const exp = builder_primitive.exp;
pub const log = builder_primitive.log;
pub const tanh = builder_primitive.tanh;
pub const sin = builder_primitive.sin;
pub const cos = builder_primitive.cos;
pub const tan = builder_primitive.tan;
pub const floor = builder_primitive.floor;
pub const round = builder_primitive.round;
pub const trunc = builder_primitive.trunc;
pub const tf32Round = builder_primitive.tf32Round;
pub const pow = builder_primitive.pow;
pub const atan2 = builder_primitive.atan2;
pub const fma = builder_primitive.fma;
pub const compare = builder_primitive.compare;
pub const select = builder_primitive.select;
pub const cast = builder_primitive.cast;
pub const castIndex = builder_primitive.castIndex;
pub const load = builder_primitive.load;
pub const loadVector = builder_primitive.loadVector;
pub const linearIndex = builder_primitive.linearIndex;
pub const loadIndex = builder_primitive.loadIndex;
pub const loadVectorIndex = builder_primitive.loadVectorIndex;
pub const sharedBuffer = builder_primitive.sharedBuffer;
pub const dynamicSharedBuffer = builder_primitive.dynamicSharedBuffer;
pub const store = builder_primitive.store;
pub const storeIndex = builder_primitive.storeIndex;
pub const atomicRmw = builder_primitive.atomicRmw;
pub const atomicCas = builder_primitive.atomicCas;
pub const barrier = builder_primitive.barrier;
pub const activeMask = builder_primitive.activeMask;
pub const syncWarp = builder_primitive.syncWarp;
pub const allSync = builder_primitive.allSync;
pub const anySync = builder_primitive.anySync;
pub const ballotSync = builder_primitive.ballotSync;
pub const if_ = builder_primitive.if_;
pub const for_ = builder_primitive.for_;
pub const forScope = builder_primitive.forScope;
pub const while_ = builder_primitive.while_;
pub const whileScope = builder_primitive.whileScope;
pub const yield_ = builder_primitive.yield_;
pub const return_ = builder_primitive.return_;

pub fn mmaSync(owner: anytype, shape: builder.MmaShape, a: [4]builder.Value, b: [2]builder.Value, c: [4]builder.Value) ![4]builder.Value {
    return owner.body.mmaSync(shape, a, b, c);
}

pub fn fence(owner: anytype, scope: builder.Scope) !void {
    try owner.body.fence(scope);
}

pub fn asyncCopyShared(owner: anytype, dst: builder.Value, dst_index: builder.Value, src: builder.Value, src_index: builder.Value, bytes: u32) !void {
    try owner.body.asyncCopyShared(dst, dst_index, src, src_index, bytes);
}

pub fn asyncCopyCommit(owner: anytype) !void {
    try owner.body.asyncCopyCommit();
}

pub fn asyncCopyWait(owner: anytype, groups: u32) !void {
    try owner.body.asyncCopyWait(groups);
}

const arithmetic = @import("arithmetic.zig");
const bitwise = @import("bitwise.zig");
const conversion = @import("conversion.zig");
const elementary = @import("elementary.zig");
const selection = @import("selection.zig");

pub const add = arithmetic.add;
pub const sub = arithmetic.sub;
pub const mul = arithmetic.mul;
pub const umulhi = arithmetic.umulhi;
pub const div = arithmetic.div;
pub const min = arithmetic.min;
pub const max = arithmetic.max;
pub const neg = arithmetic.neg;
pub const abs = arithmetic.abs;
pub const splatVector = arithmetic.splatVector;
pub const extractLane = arithmetic.extractLane;
pub const insertLane = arithmetic.insertLane;
pub const packVector = arithmetic.packVector;
pub const shuffleVector = arithmetic.shuffleVector;

pub const and_ = bitwise.and_;
pub const or_ = bitwise.or_;
pub const xor = bitwise.xor;
pub const not = bitwise.not;
pub const popcount = bitwise.popcount;
pub const shl = bitwise.shl;
pub const shr = bitwise.shr;
pub const ushr = bitwise.ushr;

pub const bitcast = conversion.bitcast;
pub const cast = conversion.cast;
pub const castIndex = conversion.castIndex;

pub const sqrt = elementary.sqrt;
pub const exp = elementary.exp;
pub const log = elementary.log;
pub const tanh = elementary.tanh;
pub const sin = elementary.sin;
pub const cos = elementary.cos;
pub const tan = elementary.tan;
pub const floor = elementary.floor;
pub const round = elementary.round;
pub const trunc = elementary.trunc;
pub const tf32Round = elementary.tf32Round;
pub const pow = elementary.pow;
pub const atan2 = elementary.atan2;
pub const fma = elementary.fma;

pub const compare = selection.compare;
pub const select = selection.select;

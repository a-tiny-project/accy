/// One value's home in the frame: where it sits, how wide it is, and what it
/// looks like in a register.
///
/// A VALUE'S REPRESENTATION IN A REGISTER IS A PROPERTY OF THE VALUE AND NOT
/// OF THE INSTRUCTION READING IT. It is fixed here, where the slot is
/// reserved, at the value's own width and its own signedness, and every
/// reload reproduces it. `ext` exists because it used to be missing: the slot
/// carried an offset and a width, so a reload had to guess the signedness and
/// guessed `signed`, and a `u8` of 200 was stored by a `movzbq` that read it
/// as 200 and returned by a `movsbq` that read it as -56.
///
/// TWO RELOADS OF THE SAME VALUE AGREED WITH EACH OTHER, WHICH IS WHY THE
/// DEFECT WAS QUIET. Sign extension is injective, so an equality between two
/// values extended the same way survives it and answers correctly. Only a
/// reload met against an immediate disagreed, because the immediate is the
/// face value. The bug was never one wrong instruction. It was that nothing
/// fixed what a narrow value looks like, so the load, the reload and the
/// immediate each answered differently.
///
/// EVERY FIELD IS SPELLED AT EVERY LITERAL AND `ext` HAS NO DEFAULT. A
/// default is exactly the silent guess this field was added to remove, so a
/// new slot must say what its value looks like rather than inherit an answer.
pub const Slot = struct {
    offset: i32,
    width: u8,
    /// The form a reload puts this value in, from the value's own type.
    ///
    /// Only widths 8 and 16 branch on it. A 32 or 64 bit slot takes a plain
    /// `mov` and never reads this, so a non integer value carries `unsigned`
    /// as the answer nothing asks for.
    ext: IntExtension,
};

pub const VectorSlot = struct {
    base: Slot,
    lanes: usize,
    elem_type_name: []const u8,
    is_float: bool,
};

pub const SretInfo = union(enum) {
    /// Vector result written lane by lane through the hidden result address.
    vector: VectorSlot,
    /// Scalar result count written at eightbyte offsets through the hidden result address.
    record: usize,
};

pub const AllocationKind = enum {
    heap,
    stack_emulated,
};

pub const TypeInfo = struct {
    width: u8,
    is_float: bool,
};

/// How a narrow value is widened when it comes back out of its slot.
///
/// A `Slot` carries the one its value was spelled with. A site passes it by
/// hand only where the OPERATION needs a different form than the value's own,
/// which is a statement about the instruction rather than about the value: a
/// logical shift right reads its input as unsigned whatever its type says.
pub const IntExtension = enum {
    signed,
    unsigned,
};

pub fn laneStride(base: Slot) usize {
    return @divExact(base.width, 8);
}

/// One lane of a vector, which is the base slot's value and so its form.
pub fn laneSlot(base: Slot, lane: usize) Slot {
    return .{
        .offset = base.offset - @as(i32, @intCast(lane * laneStride(base))),
        .width = base.width,
        .ext = base.ext,
    };
}

pub fn laneDisplacement(base: Slot, lane: usize) i32 {
    return -@as(i32, @intCast(lane * laneStride(base)));
}

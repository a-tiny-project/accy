const capacity = @import("capacity");
const typed = @import("typed.zig");

test "typed declaration rejects a node outside the Spec fragment" {
    const Owner = typed.Owner(.outside_fragment);
    capacity.requireAllocatorExactOwnerShape(Owner);
}

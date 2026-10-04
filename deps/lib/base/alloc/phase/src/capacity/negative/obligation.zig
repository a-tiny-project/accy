const capacity = @import("capacity");
const typed = @import("typed.zig");

test "typed declaration rejects an unknown obligation" {
    const Owner = typed.Owner(.unknown_obligation);
    capacity.requireAllocatorExactOwnerShape(Owner);
}

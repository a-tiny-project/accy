const capacity = @import("capacity");
const typed = @import("typed.zig");

test "typed declaration rejects a missing owner binding" {
    const Owner = typed.Owner(.missing_binding);
    capacity.requireAllocatorExactOwnerShape(Owner);
}

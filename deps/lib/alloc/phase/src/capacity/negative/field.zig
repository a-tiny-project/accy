const capacity = @import("capacity");
const typed = @import("typed.zig");

test "typed declaration rejects an unknown Limits field" {
    const Owner = typed.Owner(.bad_field_path);
    capacity.requireAllocatorExactOwnerShape(Owner);
}

/// Defines the lifecycle phases shared across allocator guards:
/// `initialization`, `steady`, and `teardown`. Runtime guards use these values
/// to classify incoming raw allocator calls. Under this classification,
/// `initialization` permits every raw operation, `steady` marks all raw
/// operations as violations, and `teardown` permits only deallocations while
/// marking allocations, resizes, and remaps as violations. Depending on the
/// selected guard type, a violation either triggers an immediate panic or
/// increments audit counters before forwarding the call to the backing
/// allocator. The enumeration itself is an unadorned data type that enforces no
/// transition rules or operational policies on other owners.
pub const Phase = enum(u8) {
    initialization,
    steady,
    teardown,
};

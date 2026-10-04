const Features = @import("features.zig").Features;
const SubgroupRequirements = @import("features.zig").SubgroupRequirements;
const PushConstants = @import("push.zig").PushConstants;

/// What one compiled kernel entry asks of the runtime that loads it. The
/// artifact carries this record; the runtime checks the requirements against
/// the device at load and packs launch scalars through the push-constant
/// layout.
pub const Interface = struct {
    features: Features = .{},
    subgroup: SubgroupRequirements = .{},
    push_constants: PushConstants = .{},
};

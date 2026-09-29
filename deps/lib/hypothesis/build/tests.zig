const std = @import("std");

pub fn add(
    b: *std.Build,
    hypothesis: *std.Build.Module,
    properties: *std.Build.Module,
    filters: []const []const u8,
) void {
    const unit_artifact = b.addTest(.{
        .root_module = hypothesis,
        .filters = filters,
    });
    const run_unit = b.addRunArtifact(unit_artifact);
    const direct_property_artifact = b.addTest(.{
        .root_module = hypothesis,
        .filters = &.{ "stateful:", "fuzz:" },
    });
    const run_direct_properties = b.addRunArtifact(direct_property_artifact);
    const property_artifact = b.addTest(.{ .root_module = properties });
    const run_properties = b.addRunArtifact(property_artifact);

    const unit = b.step("test", "Run unit tests");
    unit.dependOn(&run_unit.step);

    const property = b.step("pbt", "Run hypothesis stateful and fuzz tests");
    property.dependOn(&run_direct_properties.step);
    property.dependOn(&run_properties.step);
}

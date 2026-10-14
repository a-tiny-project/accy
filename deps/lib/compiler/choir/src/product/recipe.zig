const std = @import("std");
const ir = @import("../core/root.zig");
const revision = @import("root.zig").revision;

pub const version: u32 = 1;
pub const ArithmeticPolicy = ir.interfaces.effects.ArithmeticPolicy;

/// The effective Context policy is an input, not a derived permission bit.
pub const Recipe = struct {
    arithmetic: ArithmeticPolicy,
    policy: []const u8,

    pub fn requireContext(self: Recipe, context: *const ir.Context) !void {
        if (!std.meta.eql(self.arithmetic, context.arithmetic_policy)) {
            return error.UnrecordedArithmeticPolicy;
        }
    }

    pub fn restore(self: Recipe, context: *ir.Context) void {
        context.arithmetic_policy = self.arithmetic;
    }
};

pub fn encode(allocator: std.mem.Allocator, recipe: Recipe) ![]u8 {
    comptime classify();
    var writer = revision.record.Writer.init(allocator);
    defer writer.deinit();
    try writer.writeInt(u32, version);
    inline for (@typeInfo(ArithmeticPolicy).@"struct".field_names) |field| {
        try writer.writeBool(@field(recipe.arithmetic, field));
    }
    try writer.writeBlob(recipe.policy);
    return writer.finish();
}

pub fn decode(bytes: []const u8) !Recipe {
    comptime classify();
    var reader = try revision.record.Reader.init(bytes);
    if (try reader.readInt(u32) != version) return error.UnknownRecipeSchema;
    var arithmetic: ArithmeticPolicy = undefined;
    inline for (@typeInfo(ArithmeticPolicy).@"struct".field_names) |field| {
        @field(arithmetic, field) = try reader.readBool();
    }
    const policy = try reader.readBlob();
    if (!reader.atEnd()) return error.InvalidRecipe;
    return .{ .arithmetic = arithmetic, .policy = policy };
}

fn classify() void {
    revision.record.requireFields(Recipe, &.{ "arithmetic", "policy" });
    revision.record.requireFields(ArithmeticPolicy, &.{
        "exceptions_masked", "default_rounding", "environment_observable",
    });
}

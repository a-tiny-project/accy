const std = @import("std");

const policy = @import("policy.zig");
const program = @import("../program/root.zig");
const spec = @import("spec.zig");

pub const ExclusionKind = enum {
    lifecycle,
    diagnostic_finish,
    schedule_construction,
};

pub const Exclusion = struct {
    name: []const u8,
    kind: ExclusionKind,
};

pub const excluded_methods = [_]Exclusion{
    .{ .name = "init", .kind = .lifecycle },
    .{ .name = "deinit", .kind = .lifecycle },
    .{ .name = "finishWithDiagnostic", .kind = .diagnostic_finish },
    .{ .name = "axis", .kind = .schedule_construction },
    .{ .name = "split", .kind = .schedule_construction },
    .{ .name = "bind", .kind = .schedule_construction },
    .{ .name = "vectorize", .kind = .schedule_construction },
    .{ .name = "unroll", .kind = .schedule_construction },
};

pub fn exclusion(comptime name: []const u8) ?Exclusion {
    inline for (excluded_methods) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

pub fn supports(comptime name: []const u8) bool {
    return isFnDecl(program.Builder, name) and exclusion(name) == null and @hasDecl(DefaultLayer(), name);
}

pub fn assertLayerCoversBuilder(comptime LayerType: type) void {
    assertExclusionsReferToBuilderMethods();
    inline for (@typeInfo(program.Builder).@"struct".decl_names) |decl_name| {
        if (!isFnDecl(program.Builder, decl_name)) continue;
        if (exclusion(decl_name) != null) continue;
        if (!@hasDecl(LayerType, decl_name)) {
            @compileError("kernel.interpret.Layer missing typed builder method: " ++ decl_name);
        }
    }
}

fn DefaultLayer() type {
    return spec.Layer(*program.Builder, struct {}, policy.lower);
}

fn assertExclusionsReferToBuilderMethods() void {
    inline for (excluded_methods) |item| {
        if (!isFnDecl(program.Builder, item.name)) {
            @compileError("kernel.interpret surface exclusion is not a typed builder method: " ++ item.name);
        }
    }
}

fn isFnDecl(comptime Type: type, comptime name: []const u8) bool {
    if (!@hasDecl(Type, name)) return false;
    return switch (@typeInfo(@TypeOf(@field(Type, name)))) {
        .@"fn" => true,
        else => false,
    };
}

test "kernel interpret Layer covers typed builder body surface" {
    assertLayerCoversBuilder(DefaultLayer());
    try std.testing.expect(supports("forScope"));
    try std.testing.expect(supports("tan"));
    try std.testing.expect(exclusion("axis").?.kind == .schedule_construction);
}

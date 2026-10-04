const std = @import("std");

const Allocator = std.mem.Allocator;

/// Recursively inspects a compile-time type to detect whether it exposes an
/// allocator capability. The traversal follows typed pointers, arrays, vectors,
/// optionals, error-union payloads, struct and union fields, and container
/// receiver methods whose return types lead to an allocator. It maintains a
/// compile-time tuple of visited containers to prevent infinite loops on
/// recursive data structures, and recognizes `std.mem.Allocator` as an
/// immediate capability. For bare function types, the check examines only the
/// return type, without scanning parameter lists. This public recursive
/// inspector differs from the narrower internal scanner used by
/// allocator-backed shapes, which inspects only immediate field types and
/// container allocator methods. The function does not inspect function bodies,
/// detect global allocator variables, or track capabilities through type-erased
/// pointers such as `*anyopaque`. It does not prove that runtime execution is
/// free from allocation side effects.
pub fn typeHasAllocatorCapability(comptime T: type) bool {
    @setEvalBranchQuota(1_000_000);
    return typeHasAllocatorCapabilitySeen(T, .{});
}

/// Shape validation uses this shallower predicate for allocator-backed owners
/// to identify immediate allocator access in a type's inspected surface.
/// Caller-provisioned shape validation selects the recursive predicate
/// `typeHasAllocatorCapability` instead.
///
/// A type possesses immediate capability if it directly references
/// `std.mem.Allocator`, including references wrapped in arrays, vectors,
/// optional values, error union payloads, or pointer chains. For struct and
/// union values, inspection examines both declarations and fields: a container
/// qualifies if it declares a function named `allocator` returning an allocator
/// reference, or if any field contains a direct allocator reference, provides
/// an allocator factory directly or through a pointer, or exposes a function
/// type with allocator capability. Inspecting a pointer to a container,
/// however, checks only whether the pointee declares an `allocator` factory
/// function, without traversing stored fields. For example, a pointer to an
/// owner storing an allocator (`*BorrowedOwner`) evaluates to false because the
/// pointee lacks an allocator factory declaration, whereas
/// `std.heap.ArenaAllocator` evaluates to true because the arena declares an
/// `allocator` method returning an allocator reference. Function types qualify
/// when any typed parameter or return type contains an immediate allocator
/// reference.
///
/// Inspection operates on type structure only: it does not analyze function
/// bodies, detect global state, or inspect type-erased targets such as
/// `*anyopaque`, and it provides no whole-program absence-of-allocation proof.
pub fn typeHasImmediateAllocatorCapability(comptime T: type) bool {
    if (immediateAllocatorReference(T)) return true;
    const Base = immediateSurface(T);
    return switch (@typeInfo(Base)) {
        .pointer => immediatePointeeHasAllocatorCapability(immediatePointeeBase(Base)),
        .@"struct" => |structure| immediateContainerHasAllocatorCapability(
            Base,
            structure.field_types,
        ),
        .@"union" => |union_info| immediateContainerHasAllocatorCapability(
            Base,
            union_info.field_types,
        ),
        .@"fn" => |function| immediateFunctionHasAllocatorCapability(function),
        else => false,
    };
}

fn typeHasAllocatorCapabilitySeen(comptime T: type, comptime seen: anytype) bool {
    if (T == Allocator) return true;
    return switch (@typeInfo(T)) {
        .array => |array| typeHasAllocatorCapabilitySeen(array.child, seen),
        .error_union => |error_union| typeHasAllocatorCapabilitySeen(
            error_union.payload,
            seen,
        ),
        .optional => |optional| typeHasAllocatorCapabilitySeen(optional.child, seen),
        .pointer => |pointer| typeHasAllocatorCapabilitySeen(pointer.child, seen),
        .vector => |vector| typeHasAllocatorCapabilitySeen(vector.child, seen),
        .@"struct" => |structure| containerHasAllocatorCapability(
            T,
            structure.field_types,
            seen,
        ),
        .@"union" => |union_info| containerHasAllocatorCapability(
            T,
            union_info.field_types,
            seen,
        ),
        .@"enum", .@"opaque" => containerHasAllocatorCapability(T, &.{}, seen),
        .@"fn" => |function| functionResultHasAllocatorCapability(function, seen),
        else => false,
    };
}

fn containerHasAllocatorCapability(
    comptime Container: type,
    comptime field_types: []const type,
    comptime seen: anytype,
) bool {
    inline for (seen) |Seen| {
        if (Container == Seen) return false;
    }
    const next = seen ++ .{Container};
    if (containerDeclaresAllocatorCapability(Container, next)) return true;
    inline for (field_types) |field_type| {
        if (typeHasAllocatorCapabilitySeen(field_type, next)) return true;
    }
    return false;
}

fn containerDeclaresAllocatorCapability(
    comptime Container: type,
    comptime seen: anytype,
) bool {
    const declaration_names = switch (@typeInfo(Container)) {
        .@"struct" => |structure| structure.decl_names,
        .@"union" => |union_info| union_info.decl_names,
        .@"enum" => |enum_info| enum_info.decl_names,
        .@"opaque" => |opaque_info| opaque_info.decl_names,
        else => return false,
    };
    inline for (declaration_names) |declaration_name| {
        const declaration_type = @TypeOf(@field(Container, declaration_name));
        if (@typeInfo(declaration_type) != .@"fn") continue;
        const function = @typeInfo(declaration_type).@"fn";
        if (function.param_types.len == 0) continue;
        const receiver = function.param_types[0] orelse continue;
        if (comptime !containerReceiver(receiver, Container)) continue;
        if (comptime functionResultHasAllocatorCapability(function, seen)) {
            return true;
        }
    }
    return false;
}

fn functionResultHasAllocatorCapability(
    comptime function: std.builtin.Type.Fn,
    comptime seen: anytype,
) bool {
    if (function.return_type) |result| {
        return typeHasAllocatorCapabilitySeen(result, seen);
    }
    return false;
}

fn containerReceiver(comptime T: type, comptime Container: type) bool {
    if (T == Container) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child == Container,
        else => false,
    };
}

fn immediateAllocatorReference(comptime T: type) bool {
    if (T == Allocator) return true;
    return switch (@typeInfo(T)) {
        .array => |array| immediateAllocatorReference(array.child),
        .error_union => |error_union| immediateAllocatorReference(error_union.payload),
        .optional => |optional| immediateAllocatorReference(optional.child),
        .pointer => |pointer| immediateAllocatorReference(pointer.child),
        .vector => |vector| immediateAllocatorReference(vector.child),
        else => false,
    };
}

fn immediateSurface(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |array| immediateSurface(array.child),
        .error_union => |error_union| immediateSurface(error_union.payload),
        .optional => |optional| immediateSurface(optional.child),
        .vector => |vector| immediateSurface(vector.child),
        else => T,
    };
}

fn immediatePointeeBase(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |array| immediatePointeeBase(array.child),
        .error_union => |error_union| immediatePointeeBase(error_union.payload),
        .optional => |optional| immediatePointeeBase(optional.child),
        .pointer => |pointer| immediatePointeeBase(pointer.child),
        .vector => |vector| immediatePointeeBase(vector.child),
        else => T,
    };
}

fn immediateContainerHasAllocatorCapability(
    comptime Container: type,
    comptime field_types: []const type,
) bool {
    if (immediateContainerDeclaresAllocatorFactory(Container)) return true;
    inline for (field_types) |field_type| {
        if (immediateAllocatorReference(field_type)) return true;
        const FieldSurface = immediateSurface(field_type);
        const FieldBase = switch (@typeInfo(FieldSurface)) {
            .pointer => immediatePointeeBase(FieldSurface),
            else => FieldSurface,
        };
        if (immediatePointeeHasAllocatorCapability(FieldBase)) return true;
    }
    return false;
}

fn immediatePointeeHasAllocatorCapability(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"fn" => |function| immediateFunctionHasAllocatorCapability(function),
        else => immediateContainerDeclaresAllocatorFactory(T),
    };
}

fn immediateContainerDeclaresAllocatorFactory(comptime Container: type) bool {
    switch (@typeInfo(Container)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(Container, "allocator")) return false;
    const allocator_type = @TypeOf(@field(Container, "allocator"));
    if (@typeInfo(allocator_type) != .@"fn") return false;
    const result = @typeInfo(allocator_type).@"fn".return_type orelse return false;
    return immediateAllocatorReference(result);
}

fn immediateFunctionHasAllocatorCapability(
    comptime function: std.builtin.Type.Fn,
) bool {
    inline for (function.param_types) |parameter_type_optional| {
        if (parameter_type_optional) |parameter_type| {
            if (immediateAllocatorReference(parameter_type)) return true;
        }
    }
    if (function.return_type) |result| return immediateAllocatorReference(result);
    return false;
}

test "phase owner shape recognizes transitive allocator capabilities" {
    const BorrowedOwner = struct {
        allocator: Allocator,
    };
    const Wrapper = struct {
        borrowed: ?*BorrowedOwner,
    };
    const Cycle = struct {
        next: ?*@This(),
    };
    const Consumer = struct {
        pub fn init(_: Allocator) @This() {
            return .{};
        }
    };
    const Factory = struct {
        handle: *anyopaque,

        pub fn borrowed(_: *const @This()) Allocator {
            unreachable;
        }
    };
    const EnumFactory = enum {
        handle,

        pub fn borrowed(_: @This()) Allocator {
            unreachable;
        }
    };
    const OpaqueFactory = opaque {
        pub fn borrowed(_: *const @This()) Allocator {
            unreachable;
        }
    };

    try std.testing.expect(typeHasAllocatorCapability(?Allocator));
    try std.testing.expect(typeHasAllocatorCapability(error{Unavailable}!Allocator));
    try std.testing.expect(typeHasAllocatorCapability(*Allocator));
    try std.testing.expect(typeHasAllocatorCapability(std.heap.ArenaAllocator));
    try std.testing.expect(typeHasAllocatorCapability(*std.heap.ArenaAllocator));
    try std.testing.expect(typeHasAllocatorCapability(*const fn () Allocator));
    try std.testing.expect(!typeHasAllocatorCapability(*const fn (Allocator) void));
    try std.testing.expect(typeHasAllocatorCapability(*BorrowedOwner));
    try std.testing.expect(typeHasAllocatorCapability([]?*Wrapper));
    try std.testing.expect(!typeHasAllocatorCapability(Consumer));
    try std.testing.expect(typeHasAllocatorCapability(Factory));
    try std.testing.expect(typeHasAllocatorCapability(EnumFactory));
    try std.testing.expect(typeHasAllocatorCapability(*OpaqueFactory));
    try std.testing.expect(!typeHasAllocatorCapability(Cycle));
    try std.testing.expect(!typeHasImmediateAllocatorCapability(*BorrowedOwner));
    try std.testing.expect(
        typeHasImmediateAllocatorCapability(std.heap.ArenaAllocator),
    );
}

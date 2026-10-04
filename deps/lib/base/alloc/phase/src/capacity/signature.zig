//! signature.zig contains reflection helpers used by owner shape checks.
//! Helpers inspect parameter types, return types, supported container kinds and
//! receiver mutability without invoking the inspected functions. For
//! allocator-backed owners, derive and init may return their payload directly
//! or through an error union, and activate may return void or an error union
//! containing void. Their deinit receives *Owner and Allocator and returns
//! void. For caller-provisioned owners, derive and init require finite nonempty
//! error unions, activate receives *Owner and returns void, and deinit receives
//! *Owner and returns Storage. Lifecycle receiver checks require one mutable
//! pointer to Owner. The overload-method receiver helper also permits a const
//! pointer.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn functionReturnsExhaustion(comptime function: type, comptime Exhaustion: type) bool {
    const function_info = @typeInfo(function).@"fn";
    const result = function_info.return_type orelse return false;
    const result_errors = switch (@typeInfo(result)) {
        .error_set => result,
        .error_union => |error_union| error_union.error_set,
        else => return false,
    };
    return errorSetContains(result_errors, Exhaustion);
}

fn errorSetContains(comptime Superset: type, comptime Subset: type) bool {
    const superset_errors = @typeInfo(Superset).error_set.error_names orelse return false;
    const subset_errors = @typeInfo(Subset).error_set.error_names orelse return false;
    inline for (subset_errors) |required| {
        var found = false;
        inline for (superset_errors) |available| {
            if (std.mem.eql(u8, required, available)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

pub fn capacityDeriveValid(comptime Owner: type) bool {
    const derive_type = @TypeOf(Owner.Capacity.derive);
    if (@typeInfo(derive_type) != .@"fn") return false;
    const derive = @typeInfo(derive_type).@"fn";
    if (derive.param_types.len != 1) return false;
    if (derive.param_types[0] != Owner.Limits) return false;
    const result = derive.return_type orelse return false;
    return returnPayload(result) == Owner.Capacity;
}

pub fn provisionedCapacityDeriveValid(comptime Owner: type) bool {
    const derive_type = @TypeOf(Owner.Capacity.derive);
    if (@typeInfo(derive_type) != .@"fn") return false;
    const derive = @typeInfo(derive_type).@"fn";
    if (derive.param_types.len != 1) return false;
    if (derive.param_types[0] != Owner.Limits) return false;
    const result = derive.return_type orelse return false;
    const error_union = switch (@typeInfo(result)) {
        .error_union => |info| info,
        else => return false,
    };
    if (!finiteNonemptyErrorSet(error_union.error_set)) return false;
    return error_union.payload == Owner.Capacity;
}

pub fn declarationContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

pub fn exhaustionSetValid(comptime Exhaustion: type) bool {
    return finiteNonemptyErrorSet(Exhaustion);
}

pub fn allocatorOwnerInitValid(comptime Owner: type) bool {
    const init_type = @TypeOf(Owner.init);
    if (@typeInfo(init_type) != .@"fn") return false;
    const init = @typeInfo(init_type).@"fn";
    if (init.param_types.len != 2) return false;
    if (init.param_types[0] != Allocator) return false;
    if (init.param_types[1] != Owner.Limits) return false;
    const result = init.return_type orelse return false;
    return returnPayload(result) == Owner;
}

pub fn provisionedOwnerInitValid(comptime Owner: type) bool {
    const init_type = @TypeOf(Owner.init);
    if (@typeInfo(init_type) != .@"fn") return false;
    const init = @typeInfo(init_type).@"fn";
    if (init.param_types.len != 2) return false;
    if (init.param_types[0] != Owner.Storage) return false;
    if (init.param_types[1] != Owner.Limits) return false;
    const result = init.return_type orelse return false;
    const error_union = switch (@typeInfo(result)) {
        .error_union => |info| info,
        else => return false,
    };
    if (!finiteNonemptyErrorSet(error_union.error_set)) return false;
    return error_union.payload == Owner;
}

pub fn ownerActivateValid(comptime Owner: type) bool {
    const activate_type = @TypeOf(Owner.activate);
    if (@typeInfo(activate_type) != .@"fn") return false;
    const activate = @typeInfo(activate_type).@"fn";
    if (activate.param_types.len != 1) return false;
    if (!ownerMutableReceiver(activate.param_types[0], Owner)) return false;
    const result = activate.return_type orelse return false;
    return returnPayload(result) == void;
}

pub fn provisionedOwnerActivateValid(comptime Owner: type) bool {
    const activate_type = @TypeOf(Owner.activate);
    if (@typeInfo(activate_type) != .@"fn") return false;
    const activate = @typeInfo(activate_type).@"fn";
    if (activate.param_types.len != 1) return false;
    if (!ownerMutableReceiver(activate.param_types[0], Owner)) return false;
    return activate.return_type == void;
}

pub fn allocatorOwnerDeinitValid(comptime Owner: type) bool {
    const deinit_type = @TypeOf(Owner.deinit);
    if (@typeInfo(deinit_type) != .@"fn") return false;
    const deinit = @typeInfo(deinit_type).@"fn";
    if (deinit.param_types.len != 2) return false;
    if (!ownerMutableReceiver(deinit.param_types[0], Owner)) return false;
    if (deinit.param_types[1] != Allocator) return false;
    return deinit.return_type == void;
}

pub fn provisionedOwnerDeinitValid(comptime Owner: type) bool {
    const deinit_type = @TypeOf(Owner.deinit);
    if (@typeInfo(deinit_type) != .@"fn") return false;
    const deinit = @typeInfo(deinit_type).@"fn";
    if (deinit.param_types.len != 1) return false;
    if (!ownerMutableReceiver(deinit.param_types[0], Owner)) return false;
    return deinit.return_type == Owner.Storage;
}

pub fn provisionedStorageTypeValid(comptime Owner: type) bool {
    if (Owner.storage_alignment == 0) return false;
    if (!std.math.isPowerOfTwo(Owner.storage_alignment)) return false;
    return Owner.Storage == []align(Owner.storage_alignment) u8;
}

pub fn ownerReceiver(comptime receiver_type: ?type, comptime Owner: type) bool {
    const receiver = receiver_type orelse return false;
    if (@typeInfo(receiver) != .pointer) return false;
    const pointer = @typeInfo(receiver).pointer;
    return pointer.size == .one and pointer.child == Owner;
}

fn ownerMutableReceiver(comptime receiver_type: ?type, comptime Owner: type) bool {
    const receiver = receiver_type orelse return false;
    if (!ownerReceiver(receiver, Owner)) return false;
    return !@typeInfo(receiver).pointer.attrs.@"const";
}

fn returnPayload(comptime result: type) type {
    return switch (@typeInfo(result)) {
        .error_union => |error_union| error_union.payload,
        else => result,
    };
}

fn finiteNonemptyErrorSet(comptime ErrorSet: type) bool {
    if (@typeInfo(ErrorSet) != .error_set) return false;
    const errors = @typeInfo(ErrorSet).error_set.error_names orelse return false;
    return errors.len != 0;
}

const SliceDeinitFixture = struct {
    pub fn deinit(_: []@This(), _: Allocator) void {}
};

const ConstDeinitFixture = struct {
    pub fn deinit(_: *const @This(), _: Allocator) void {}
};

test "phase owner shape requires a finite nonempty exhaustion set" {
    try std.testing.expect(exhaustionSetValid(error{Full}));
    try std.testing.expect(!exhaustionSetValid(error{}));
    try std.testing.expect(!exhaustionSetValid(anyerror));
}

test "phase owner deinit requires one mutable owner pointer" {
    try std.testing.expect(!allocatorOwnerDeinitValid(SliceDeinitFixture));
    try std.testing.expect(!allocatorOwnerDeinitValid(ConstDeinitFixture));
}

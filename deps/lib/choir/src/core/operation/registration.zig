const std = @import("std");
const interfaces = @import("../interfaces/root.zig");

pub fn Methods(comptime Operation: type) type {
    return struct {
        pub fn getRegisteredInfo(self: *Operation) ?*const interfaces.OperationInfo {
            return self.name.resolveRegisteredInfo(self.context);
        }

        fn lookupRegisteredInfo(self: *const Operation) ?*const interfaces.OperationInfo {
            if (self.name.getRegisteredInfo()) |info| {
                return info;
            }
            return self.context.lookupOperation(self.name.name);
        }

        pub fn getInherentAttributeNames(self: *const Operation) []const []const u8 {
            const info = lookupRegisteredInfo(self) orelse return &.{};
            return info.getInherentAttributeNames();
        }

        pub fn hasInherentAttributeName(self: *const Operation, name: []const u8) bool {
            const info = lookupRegisteredInfo(self) orelse return false;
            return info.hasInherentAttributeName(name);
        }

        pub fn isDiscardableAttrName(self: *const Operation, name: []const u8) bool {
            return !hasInherentAttributeName(self, name);
        }

        pub fn isRegistered(self: *Operation) bool {
            return getRegisteredInfo(self) != null;
        }

        pub fn getInterface(self: *Operation, comptime IFace: type) ?*const IFace.VTable {
            _ = self.name.resolveRegisteredInfo(self.context);

            if (self.name.getInterface(IFace)) |vtable| {
                return vtable;
            }

            const fallbacks = self.context.dialect_registry.op_interface_fallbacks.lookup(IFace.id) orelse return null;

            const ns = self.name.getDialectNamespace();
            if (ns.len > 0) {
                if (fallbacks.get(ns)) |fallback| {
                    if (fallback(self)) |vt_any| {
                        return @ptrCast(@alignCast(vt_any));
                    }
                }
            }

            return null;
        }

        pub fn InterfaceHandle(comptime IFace: type) type {
            return struct {
                op: *Operation,
                vtable: *const IFace.VTable,

                fn returnType(comptime fn_ptr_type: type) type {
                    const ptr_info = @typeInfo(fn_ptr_type);
                    const fn_type = switch (ptr_info) {
                        .pointer => |p| p.child,
                        else => @compileError("expected interface vtable field to be a function pointer"),
                    };
                    const fn_info = switch (@typeInfo(fn_type)) {
                        .@"fn" => |f| f,
                        else => @compileError("expected interface vtable field to be a function pointer"),
                    };
                    return fn_info.return_type orelse @compileError("generic interface vtable methods are not supported");
                }

                fn methodFnPtrType(comptime method: std.meta.FieldEnum(IFace.VTable)) type {
                    const dummy: IFace.VTable = undefined;
                    return @TypeOf(@field(dummy, @tagName(method)));
                }

                pub inline fn call(
                    self: @This(),
                    comptime method: std.meta.FieldEnum(IFace.VTable),
                    args: anytype,
                ) returnType(methodFnPtrType(method)) {
                    const fn_ptr = @field(self.vtable, @tagName(method));
                    const op_any: *const anyopaque = @ptrCast(self.op);
                    return @call(.auto, fn_ptr, .{op_any} ++ args);
                }
            };
        }

        pub fn interface(self: *Operation, comptime IFace: type) ?InterfaceHandle(IFace) {
            const vtable = getInterface(self, IFace) orelse return null;
            return .{ .op = self, .vtable = vtable };
        }

        pub fn hasInterface(self: *Operation, comptime IFace: type) bool {
            return getInterface(self, IFace) != null;
        }

        pub fn getTraits(self: *Operation) interfaces.OperationTraits {
            _ = self.name.resolveRegisteredInfo(self.context);
            return self.name.getTraits();
        }

        pub fn hasTrait(self: *Operation, comptime trait_field: []const u8) bool {
            const traits = getTraits(self);
            return @field(traits, trait_field);
        }

        pub fn hasTraitId(self: *Operation, trait_id: interfaces.TraitId) bool {
            _ = self.name.resolveRegisteredInfo(self.context);
            return self.name.hasTraitId(trait_id);
        }

        pub fn hasTraitName(self: *Operation, trait_name: []const u8) bool {
            return hasTraitId(self, interfaces.traitIdRuntime(trait_name));
        }
    };
}

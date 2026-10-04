const std = @import("std");
const Context = @import("../context/root.zig").Context;
const interfaces = @import("../interfaces/root.zig");

pub const OperationName = struct {
    name: []const u8,

    split_known: bool = false,
    has_dialect_namespace: bool = false,
    split_index: usize = 0,

    registered_info: ?*const interfaces.OperationInfo = null,

    pub fn init(name: []const u8) OperationName {
        if (std.mem.indexOfScalar(u8, name, '.')) |idx| {
            return .{
                .name = name,
                .split_known = true,
                .has_dialect_namespace = true,
                .split_index = idx,
            };
        }
        return .{
            .name = name,
            .split_known = true,
        };
    }

    pub fn registered(info: *const interfaces.OperationInfo) OperationName {
        var op_name = init(info.name);
        op_name.registered_info = info;
        return op_name;
    }

    pub inline fn isRegistered(self: OperationName) bool {
        return self.registered_info != null;
    }

    pub inline fn getRegisteredInfo(self: OperationName) ?*const interfaces.OperationInfo {
        return self.registered_info;
    }

    pub inline fn resolveRegisteredInfo(self: *OperationName, context: *Context) ?*const interfaces.OperationInfo {
        return self.registered_info orelse self.resolveRegisteredInfoSlow(context);
    }

    noinline fn resolveRegisteredInfoSlow(self: *OperationName, context: *Context) ?*const interfaces.OperationInfo {
        if (context.lookupOperation(self.name)) |info| {
            self.registered_info = info;
            return info;
        }
        return null;
    }

    pub fn getTraits(self: OperationName) interfaces.OperationTraits {
        if (self.registered_info) |info| {
            return info.traits;
        }
        return .{};
    }

    pub fn getInterface(self: OperationName, comptime IFace: type) ?*const IFace.VTable {
        const info = self.registered_info orelse return null;
        const vt_any = info.getInterface(IFace.id) orelse return null;
        return @ptrCast(@alignCast(vt_any));
    }

    pub fn hasTraitId(self: OperationName, trait_id: interfaces.TraitId) bool {
        const info = self.registered_info orelse return false;
        return info.hasTraitId(trait_id);
    }

    pub inline fn getDialectNamespace(self: OperationName) []const u8 {
        if (self.split_known) {
            if (self.has_dialect_namespace) return self.name[0..self.split_index];
            return "";
        }
        if (std.mem.indexOfScalar(u8, self.name, '.')) |idx| {
            return self.name[0..idx];
        }
        return "";
    }

    pub inline fn getStringRef(self: OperationName) []const u8 {
        if (self.split_known) {
            if (self.has_dialect_namespace) return self.name[self.split_index + 1 ..];
            return self.name;
        }
        if (std.mem.indexOfScalar(u8, self.name, '.')) |idx| {
            return self.name[idx + 1 ..];
        }
        return self.name;
    }

    pub fn format(self: OperationName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.name);
    }
};

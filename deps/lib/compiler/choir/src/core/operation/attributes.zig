const std = @import("std");
const core = @import("../root.zig");
const Attribute = core.Attribute;
const NamedAttribute = core.NamedAttribute;

pub fn AttributeIterator(comptime Operation: type) type {
    return struct {
        op: *const Operation,
        raw_attrs: []const NamedAttribute,
        inherent_names: []const []const u8,
        raw_index: usize = 0,
        inherent_index: usize = 0,

        const Self = @This();

        pub fn next(self: *Self) ?NamedAttribute {
            while (self.raw_index < self.raw_attrs.len or
                self.inherent_index < self.inherent_names.len)
            {
                if (self.raw_index >= self.raw_attrs.len) return self.nextInherent();
                if (self.inherent_index >= self.inherent_names.len) {
                    const attr = self.raw_attrs[self.raw_index];
                    self.raw_index += 1;
                    return attr;
                }

                const raw_attr = self.raw_attrs[self.raw_index];
                const inherent_name = self.inherent_names[self.inherent_index];
                switch (std.mem.order(u8, raw_attr.name, inherent_name)) {
                    .lt => {
                        self.raw_index += 1;
                        return raw_attr;
                    },
                    .eq => {
                        self.raw_index += 1;
                        self.inherent_index += 1;
                        return self.inherent(inherent_name) orelse raw_attr;
                    },
                    .gt => {
                        self.inherent_index += 1;
                        if (self.inherent(inherent_name)) |attr| return attr;
                    },
                }
            }
            return null;
        }

        fn nextInherent(self: *Self) ?NamedAttribute {
            while (self.inherent_index < self.inherent_names.len) {
                const name = self.inherent_names[self.inherent_index];
                self.inherent_index += 1;
                if (self.inherent(name)) |attr| return attr;
            }
            return null;
        }

        fn inherent(self: *const Self, name: []const u8) ?NamedAttribute {
            const value = self.op.properties.getInherentAttr(self.op, name) orelse return null;
            return .{ .name = name, .value = value };
        }
    };
}

pub fn Methods(comptime Operation: type) type {
    const AllAttrs = AttributeIterator(Operation);
    return struct {
        pub const SetDiscardableAttrError = error{InherentAttributeName} || std.mem.Allocator.Error;
        pub const AttributeIterator: type = AllAttrs;

        pub const DiscardableAttrIterator = struct {
            op: *const Operation,
            index: usize = 0,

            pub fn next(self: *DiscardableAttrIterator) ?NamedAttribute {
                const raw_attrs = self.op.raw_dictionary_attrs.items();
                while (self.index < raw_attrs.len) {
                    const attr = raw_attrs[self.index];
                    self.index += 1;
                    if (self.op.isDiscardableAttrName(attr.name)) return attr;
                }
                return null;
            }
        };

        pub fn getAttrs(self: *const Operation) AllAttrs {
            return .{
                .op = self,
                .raw_attrs = self.raw_dictionary_attrs.items(),
                .inherent_names = self.getInherentAttributeNames(),
            };
        }

        pub fn getNumAttrs(self: *const Operation) usize {
            var attrs = getAttrs(self);
            var count: usize = 0;
            while (attrs.next() != null) count += 1;
            return count;
        }

        pub fn getRawDictionaryAttrs(self: *const Operation) []const NamedAttribute {
            return self.raw_dictionary_attrs.items();
        }

        pub fn getDiscardableAttrs(self: *const Operation) DiscardableAttrIterator {
            return .{ .op = self };
        }

        pub fn countDiscardableAttrs(self: *const Operation) usize {
            var count: usize = 0;
            for (self.raw_dictionary_attrs.items()) |attr| {
                if (self.isDiscardableAttrName(attr.name)) count += 1;
            }
            return count;
        }

        pub fn getDiscardableAttr(self: *const Operation, name: []const u8) ?Attribute {
            if (!self.isDiscardableAttrName(name)) return null;
            return self.raw_dictionary_attrs.get(name);
        }

        pub fn getDiscardableAttrAs(
            self: *const Operation,
            comptime T: type,
            name: []const u8,
        ) ?*const T {
            const attr = getDiscardableAttr(self, name) orelse return null;
            return attr.cast(T);
        }

        pub fn setDiscardableAttr(
            self: *Operation,
            attr_name: []const u8,
            value: Attribute,
        ) SetDiscardableAttrError!void {
            if (!self.isDiscardableAttrName(attr_name)) return error.InherentAttributeName;
            try setRawAttr(self, attr_name, value);
        }

        fn setRawAttr(self: *Operation, attr_name: []const u8, value: Attribute) !void {
            _ = try self.raw_dictionary_attrs.set(self.allocator, attr_name, value);
        }

        pub fn removeDiscardableAttr(self: *Operation, attr_name: []const u8) bool {
            if (!self.isDiscardableAttrName(attr_name)) return false;
            return self.raw_dictionary_attrs.erase(attr_name) != null;
        }

        pub fn getAttr(self: *const Operation, name: []const u8) ?Attribute {
            if (self.properties.getInherentAttr(self, name)) |attr| return attr;
            return self.raw_dictionary_attrs.get(name);
        }

        pub fn getAttrAs(
            self: *const Operation,
            comptime T: type,
            name: []const u8,
        ) ?*const T {
            const attr = getAttr(self, name) orelse return null;
            return attr.cast(T);
        }

        pub fn setAttr(self: *Operation, attr_name: []const u8, value: Attribute) !void {
            if (try self.properties.setInherentAttr(self, attr_name, value)) return;
            if (self.properties.getInherentAttr(self, attr_name) != null) {
                return error.ReadOnlyInherentAttribute;
            }
            try setRawAttr(self, attr_name, value);
        }

        pub fn removeAttr(self: *Operation, attr_name: []const u8) bool {
            if (self.properties.removeInherentAttr(self, attr_name)) return true;
            if (self.properties.getInherentAttr(self, attr_name) != null) return false;
            return self.raw_dictionary_attrs.erase(attr_name) != null;
        }

        pub fn getPropertiesAsAttr(self: *const Operation) !?Attribute {
            return self.properties.getPropertiesAsAttr(self);
        }

        pub fn getPropertiesRef(self: *const Operation) ?Operation.PropertyRef {
            return self.properties.asRef();
        }

        pub fn setPropertiesFromAttr(self: *Operation, attr: Attribute) !void {
            try self.properties.setPropertiesFromAttr(self, attr);
        }

        pub fn copyProperties(self: *Operation, properties: Operation.PropertyRef) !void {
            try self.properties.copyFrom(properties);
        }
    };
}

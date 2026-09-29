const Context = @import("../context/root.zig").Context;
const core = @import("../root.zig");
const Value = core.Value;
const Type = core.Type;
const Attribute = core.Attribute;
const NamedAttribute = core.NamedAttribute;
const Location = core.Location;
const Region = core.Region;
const Block = core.Block;

pub fn State(comptime Operation: type) type {
    return struct {
        name: OperationName,
        location: Location,
        operands: []const *Value,
        result_types: []const Type,
        attributes: []const NamedAttribute,
        raw_attributes: []const NamedAttribute,
        properties_attr: ?Attribute,
        properties_ref: ?PropertyRef,
        num_regions: usize,
        region_bodies: []const *Region,
        successors: []const *Block,

        const Self = @This();
        const OperationName: type = Operation.OperationName;
        const PropertyRef: type = Operation.PropertyRef;

        pub fn init(name: []const u8, loc: Location) Self {
            return .{
                .name = OperationName.init(name),
                .location = loc,
                .operands = &.{},
                .result_types = &.{},
                .attributes = &.{},
                .raw_attributes = &.{},
                .properties_attr = null,
                .properties_ref = null,
                .num_regions = 0,
                .region_bodies = &.{},
                .successors = &.{},
            };
        }

        pub fn initFromOperationHeader(op: *const Operation) !Self {
            var state = init(op.name.name, op.location);
            state.name = op.name;
            state.addOperands(op.operand_values);
            state.addTypes(op.result_types);
            state.addRawAttributes(op.raw_dictionary_attrs.items());
            for (op.regions.items) |_| {
                state.addRegion();
            }
            state.addSuccessors(op.successors.items);
            if (op.getPropertiesRef()) |properties| {
                try state.setProperties(properties);
            }
            return state;
        }

        pub fn addOperands(self: *Self, ops: []const *Value) void {
            self.operands = ops;
        }

        pub fn addTypes(self: *Self, types: []const Type) void {
            self.result_types = types;
        }

        pub fn addAttributes(self: *Self, attrs: []const NamedAttribute) void {
            self.attributes = attrs;
        }

        pub fn addRawAttributes(self: *Self, attrs: []const NamedAttribute) void {
            self.raw_attributes = attrs;
        }

        pub fn setPropertiesAttr(self: *Self, attr: Attribute) !void {
            if (self.properties_attr != null or self.properties_ref != null) {
                return error.DuplicateOperationPropertiesPayload;
            }
            self.properties_attr = attr;
        }

        pub fn setPropertiesAttrIfRegistered(self: *Self, context: *Context, attr: Attribute) !bool {
            try context.ensureDialectForOperation(self.name.name);
            const info = context.lookupOperation(self.name.name) orelse return false;
            if (!info.hasPropertiesModel()) return false;
            try self.setPropertiesAttr(attr);
            return true;
        }

        pub fn setProperties(self: *Self, properties: PropertyRef) !void {
            if (self.properties_attr != null or self.properties_ref != null) {
                return error.DuplicateOperationPropertiesPayload;
            }
            self.properties_ref = properties;
        }

        pub fn setPropertiesFromOperation(self: *Self, op: *const Operation) !void {
            const properties = op.getPropertiesRef() orelse return error.UnsupportedOperationProperties;
            try self.setProperties(properties);
        }

        pub fn addRegion(self: *Self) void {
            self.num_regions += 1;
        }

        pub fn addRegionBodies(self: *Self, regions: []const *Region) void {
            self.region_bodies = regions;
        }

        pub fn addSuccessors(self: *Self, succs: []const *Block) void {
            self.successors = succs;
        }
    };
}

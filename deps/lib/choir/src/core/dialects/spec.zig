const std = @import("std");
const core = @import("../root.zig");
const registry = @import("registry.zig");
const Type = core.Type;
const IrValue = core.Value;
const Location = core.Location;
const Operation = core.Operation;
const Block = core.Block;
const Region = core.Region;
const OperationBuilder = core.OperationBuilder;
const Attribute = core.Attribute;
const interfaces = core.interfaces;
const core_traits = core.traits;
const VerifyOpInterface = core.VerifyOpInterface;
const VerifyRegionOpInterface = core.VerifyRegionOpInterface;
const Context = core.Context;
const Dialect = registry.Dialect;
const OpInterfaceFallbackEntry = registry.OpInterfaceFallbackEntry;
const TypeInterfaceFallbackEntry = registry.TypeInterfaceFallbackEntry;

pub const OperationTraitSpec = struct {
    id: interfaces.TraitId,
    entry: ?interfaces.TraitEntry = null,
    traits: interfaces.OperationTraits = .{},
};

pub const AttributeStorage = union(enum) {
    any,
    i64,
    bool,
    string,
    dialect: []const u8,
};

pub const AttributeSpec = struct {
    name: []const u8,
    storage: AttributeStorage = .any,
};

pub const OperationSpec = struct {
    name: []const u8,
    traits: interfaces.OperationTraits = .{},
    shape: interfaces.OperationShape = .{},
    operand_names: []const []const u8 = &.{},
    result_names: []const []const u8 = &.{},
    region_names: []const []const u8 = &.{},
    successor_names: []const []const u8 = &.{},
    inherent_attribute_names: []const []const u8 = &.{},
    required_attribute_names: []const []const u8 = &.{},
    attribute_specs: []const AttributeSpec = &.{},
    operand_segments: ?interfaces.OperationSegmentSpec = null,
    result_segments: ?interfaces.OperationSegmentSpec = null,
    operand_type_constraints: []const interfaces.OperationTypeConstraint = &.{},
    result_type_constraints: []const interfaces.OperationTypeConstraint = &.{},
    properties_model: ?interfaces.OperationPropertiesModel = null,
    interfaces: []const interfaces.InterfaceEntry = &.{},
    dynamic_traits: []const OperationTraitSpec = &.{},
};

const OperationLayout = struct {
    operands: []const []const u8 = &.{},
    results: []const []const u8 = &.{},
    regions: []const []const u8 = &.{},
    successors: []const []const u8 = &.{},
};

pub fn operand(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) *IrValue {
    return op.getOperand(operandIndex(spec, component_name)).?;
}

pub fn optionalOperand(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?*IrValue {
    return op.getOperand(operandIndex(spec, component_name));
}

pub fn result(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) *IrValue {
    return op.getResult(resultIndex(spec, component_name)).?;
}

pub fn optionalResult(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?*IrValue {
    return op.getResult(resultIndex(spec, component_name));
}

pub fn region(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) *Region {
    return op.getRegion(regionIndex(spec, component_name)).?;
}

pub fn optionalRegion(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?*Region {
    return op.getRegion(regionIndex(spec, component_name));
}

pub fn successor(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) *Block {
    return op.getSuccessor(successorIndex(spec, component_name)).?;
}

pub fn optionalSuccessor(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?*Block {
    return op.getSuccessor(successorIndex(spec, component_name));
}

pub fn setOperandSegmentSizes(comptime spec: OperationSpec, op: *Operation, sizes: []const usize) !void {
    const segment_spec = spec.operand_segments orelse @compileError("operation has no operand segments: " ++ spec.name);
    try setSegmentSizes(segment_spec, op, sizes);
}

pub fn setResultSegmentSizes(comptime spec: OperationSpec, op: *Operation, sizes: []const usize) !void {
    const segment_spec = spec.result_segments orelse @compileError("operation has no result segments: " ++ spec.name);
    try setSegmentSizes(segment_spec, op, sizes);
}

pub fn setSegmentSizes(comptime segment_spec: interfaces.OperationSegmentSpec, op: *Operation, sizes: []const usize) !void {
    try op.setAttr(segment_spec.attribute_name, try segmentSizeAttribute(segment_spec, op.getContext(), sizes));
}

pub fn segmentSizeAttribute(comptime segment_spec: interfaces.OperationSegmentSpec, ctx: *Context, sizes: []const usize) !Attribute {
    if (sizes.len != segment_spec.segments.len) return error.OperationSegmentSizeCountMismatch;
    var attrs: [segment_spec.segments.len]Attribute = undefined;
    for (sizes, 0..) |size, index| {
        if (!segment_spec.segments[index].allows(size)) return error.OperationSegmentSizeOutOfRange;
        const value = std.math.cast(i64, size) orelse return error.OperationSegmentSizeOverflow;
        attrs[index] = try ctx.getI64Attr(value);
    }
    return ctx.getArrayAttr(attrs[0..]);
}

pub fn operandSegmentValues(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?[]const *IrValue {
    const segment_spec = spec.operand_segments orelse @compileError("operation has no operand segments: " ++ spec.name);
    const index = comptime operandIndex(spec, component_name);
    const bounds = segmentBounds(segment_spec, op, index) orelse return null;
    if (bounds.offset > op.operand_values.len) return null;
    if (bounds.size > op.operand_values.len - bounds.offset) return null;
    return op.operand_values[bounds.offset .. bounds.offset + bounds.size];
}

pub fn operandSegmentValue(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?*IrValue {
    const values = operandSegmentValues(spec, op, component_name) orelse return null;
    if (values.len != 1) return null;
    return values[0];
}

pub fn resultSegmentValues(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?[]IrValue {
    const segment_spec = spec.result_segments orelse @compileError("operation has no result segments: " ++ spec.name);
    const index = comptime resultIndex(spec, component_name);
    const bounds = segmentBounds(segment_spec, op, index) orelse return null;
    if (bounds.offset > op.results.items.len) return null;
    if (bounds.size > op.results.items.len - bounds.offset) return null;
    return op.results.items[bounds.offset .. bounds.offset + bounds.size];
}

pub fn resultSegmentValue(comptime spec: OperationSpec, op: *Operation, comptime component_name: []const u8) ?*IrValue {
    const values = resultSegmentValues(spec, op, component_name) orelse return null;
    if (values.len != 1) return null;
    return &values[0];
}

pub fn operandIndex(comptime spec: OperationSpec, comptime component_name: []const u8) usize {
    return componentIndex(spec.operand_names, "operand", component_name);
}

pub fn resultIndex(comptime spec: OperationSpec, comptime component_name: []const u8) usize {
    return componentIndex(spec.result_names, "result", component_name);
}

pub fn regionIndex(comptime spec: OperationSpec, comptime component_name: []const u8) usize {
    return componentIndex(spec.region_names, "region", component_name);
}

pub fn successorIndex(comptime spec: OperationSpec, comptime component_name: []const u8) usize {
    return componentIndex(spec.successor_names, "successor", component_name);
}

fn componentIndex(comptime names: []const []const u8, comptime kind: []const u8, comptime component_name: []const u8) usize {
    if (component_name.len == 0) @compileError("operation " ++ kind ++ " name cannot be empty");
    const index = comptime lookup: {
        for (names, 0..) |name, index| {
            if (std.mem.eql(u8, name, component_name)) break :lookup index;
        }
        @compileError("unknown operation " ++ kind ++ " name: " ++ component_name);
    };
    return index;
}

const SegmentBounds = struct {
    offset: usize,
    size: usize,
};

fn segmentBounds(comptime segment_spec: interfaces.OperationSegmentSpec, op: *const Operation, index: usize) ?SegmentBounds {
    const size = segment_spec.size(op, index) orelse return null;
    const offset = segment_spec.offset(op, index) orelse return null;
    return .{
        .offset = offset,
        .size = size,
    };
}

fn tryComponentNames(comptime values: anytype, comptime field_name: []const u8) void {
    _ = componentNamesFromValue(values, field_name);
}

fn componentNamesFromValue(comptime values: anytype, comptime field_name: []const u8) []const []const u8 {
    const Values = @TypeOf(values);
    if (Values == interfaces.CountRange) return &.{};
    return switch (@typeInfo(Values)) {
        .comptime_int, .int => &.{},
        .pointer => |pointer_info| switch (pointer_info.size) {
            .one => switch (@typeInfo(pointer_info.child)) {
                .array => |array_info| blk: {
                    if (array_info.child == u8) {
                        @compileError("operation " ++ field_name ++ " field must use a list of component names, not one component name");
                    }
                    break :blk componentNamesFromArray(values.*, field_name);
                },
                .@"struct" => |struct_info| blk: {
                    if (struct_info.field_names.len == 0) return &.{};
                    break :blk componentNamesFromTuple(values.*, field_name);
                },
                else => &.{},
            },
            .slice => componentNamesFromSlice(values, field_name),
            else => &.{},
        },
        .array => |array_info| blk: {
            if (array_info.child == u8) {
                @compileError("operation " ++ field_name ++ " field must use a list of component names, not one component name");
            }
            break :blk componentNamesFromArray(values, field_name);
        },
        .@"struct" => |struct_info| blk: {
            if (struct_info.field_names.len == 0) return &.{};
            break :blk componentNamesFromTuple(values, field_name);
        },
        else => &.{},
    };
}

fn componentNamesFromSlice(comptime values: anytype, comptime field_name: []const u8) []const []const u8 {
    const names = comptime blk: {
        var out: [values.len][]const u8 = undefined;
        for (values, 0..) |value, index| {
            out[index] = componentName(value, field_name);
        }
        validateComponentNames(out[0..], field_name);
        break :blk out;
    };
    return &names;
}

fn componentNamesFromArray(comptime values: anytype, comptime field_name: []const u8) []const []const u8 {
    const names = comptime blk: {
        var out: [values.len][]const u8 = undefined;
        for (values, 0..) |value, index| {
            out[index] = componentName(value, field_name);
        }
        validateComponentNames(out[0..], field_name);
        break :blk out;
    };
    return &names;
}

fn componentNamesFromTuple(comptime values: anytype, comptime field_name: []const u8) []const []const u8 {
    const struct_info = @typeInfo(@TypeOf(values)).@"struct";
    const names = comptime blk: {
        var out: [struct_info.field_names.len][]const u8 = undefined;
        for (struct_info.field_names, 0..) |name, index| {
            out[index] = componentName(@field(values, name), field_name);
        }
        validateComponentNames(out[0..], field_name);
        break :blk out;
    };
    return &names;
}

fn componentName(comptime value: anytype, comptime field_name: []const u8) []const u8 {
    const name: []const u8 = value;
    if (name.len == 0) @compileError("operation " ++ field_name ++ " component name cannot be empty");
    return name;
}

fn validateComponentNames(comptime names: []const []const u8, comptime field_name: []const u8) void {
    inline for (names, 0..) |name, index| {
        inline for (names[0..index]) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                @compileError("operation " ++ field_name ++ " component name is duplicated: " ++ name);
            }
        }
    }
}

pub const attribute = struct {
    pub fn any(comptime name: []const u8) AttributeSpec {
        return attributeSpec(name, .any);
    }

    pub fn integer(comptime name: []const u8) AttributeSpec {
        return attributeSpec(name, .i64);
    }

    pub fn boolean(comptime name: []const u8) AttributeSpec {
        return attributeSpec(name, .bool);
    }

    pub fn string(comptime name: []const u8) AttributeSpec {
        return attributeSpec(name, .string);
    }

    pub fn dialect(comptime name: []const u8, comptime dialect_attr_name: []const u8) AttributeSpec {
        if (dialect_attr_name.len == 0) @compileError("dialect attribute storage name cannot be empty");
        return attributeSpec(name, .{ .dialect = dialect_attr_name });
    }
};

fn attributeSpec(comptime name: []const u8, comptime storage: AttributeStorage) AttributeSpec {
    if (name.len == 0) @compileError("operation attribute name cannot be empty");
    return .{ .name = name, .storage = storage };
}

fn attributeSpecFromValue(comptime value: anytype, comptime field_name: []const u8) AttributeSpec {
    const Value = @TypeOf(value);
    if (Value == AttributeSpec) return validateAttributeSpec(value);
    return switch (@typeInfo(Value)) {
        .pointer => |pointer_info| switch (pointer_info.size) {
            .one => switch (@typeInfo(pointer_info.child)) {
                .array => |array_info| blk: {
                    if (array_info.child != u8) @compileError("operation declaration field " ++ field_name ++ " must contain attribute names or AttributeSpec values");
                    const name: []const u8 = value;
                    break :blk attribute.any(name);
                },
                else => @compileError("operation declaration field " ++ field_name ++ " must contain attribute names or AttributeSpec values"),
            },
            .slice => blk: {
                if (pointer_info.child != u8) @compileError("operation declaration field " ++ field_name ++ " must contain attribute names or AttributeSpec values");
                const name: []const u8 = value;
                break :blk attribute.any(name);
            },
            else => @compileError("operation declaration field " ++ field_name ++ " must contain attribute names or AttributeSpec values"),
        },
        .array => |array_info| blk: {
            if (array_info.child != u8) @compileError("operation declaration field " ++ field_name ++ " must contain attribute names or AttributeSpec values");
            const name: []const u8 = &value;
            break :blk attribute.any(name);
        },
        else => @compileError("operation declaration field " ++ field_name ++ " must contain attribute names or AttributeSpec values"),
    };
}

fn validateAttributeSpec(comptime spec: AttributeSpec) AttributeSpec {
    if (spec.name.len == 0) @compileError("operation attribute name cannot be empty");
    switch (spec.storage) {
        .dialect => |dialect_attr_name| {
            if (dialect_attr_name.len == 0) @compileError("dialect attribute storage name cannot be empty");
        },
        else => {},
    }
    return spec;
}

fn attributeSpecsFromDecl(comptime spec: anytype, comptime name: []const u8) []const AttributeSpec {
    if (comptime !@hasField(@TypeOf(spec), name)) return &.{};
    return attributeSpecsFromValue(@field(spec, name), name);
}

fn attributeSpecsFromValue(comptime values: anytype, comptime field_name: []const u8) []const AttributeSpec {
    const Values = @TypeOf(values);
    if (Values == []const AttributeSpec) return values;
    return switch (@typeInfo(Values)) {
        .pointer => |pointer_info| switch (pointer_info.size) {
            .one => switch (@typeInfo(pointer_info.child)) {
                .array => |array_info| blk: {
                    if (array_info.child == u8) {
                        @compileError("operation declaration field " ++ field_name ++ " must use a list of attribute specs, not one attribute name");
                    }
                    break :blk attributeSpecsFromArray(values.*, field_name);
                },
                .@"struct" => |struct_info| blk: {
                    if (!struct_info.is_tuple) @compileError("operation declaration field " ++ field_name ++ " must be a comptime slice, array, or tuple");
                    break :blk attributeSpecsFromTuple(values.*, field_name);
                },
                else => @compileError("operation declaration field " ++ field_name ++ " must be a comptime slice, array, or tuple"),
            },
            .slice => attributeSpecsFromSlice(values, field_name),
            else => @compileError("operation declaration field " ++ field_name ++ " must be a comptime slice, array, or tuple"),
        },
        .array => |array_info| blk: {
            if (array_info.child == u8) {
                @compileError("operation declaration field " ++ field_name ++ " must use a list of attribute specs, not one attribute name");
            }
            break :blk attributeSpecsFromArray(values, field_name);
        },
        .@"struct" => |struct_info| blk: {
            if (!struct_info.is_tuple) @compileError("operation declaration field " ++ field_name ++ " must be a comptime slice, array, or tuple");
            break :blk attributeSpecsFromTuple(values, field_name);
        },
        else => @compileError("operation declaration field " ++ field_name ++ " must be a comptime slice, array, or tuple"),
    };
}

fn attributeSpecsFromSlice(comptime values: anytype, comptime field_name: []const u8) []const AttributeSpec {
    const specs = comptime blk: {
        var out: [values.len]AttributeSpec = undefined;
        for (values, 0..) |value, index| {
            out[index] = attributeSpecFromValue(value, field_name);
        }
        validateAttributeSpecs(out[0..], field_name);
        break :blk out;
    };
    return &specs;
}

fn attributeSpecsFromArray(comptime values: anytype, comptime field_name: []const u8) []const AttributeSpec {
    const specs = comptime blk: {
        var out: [values.len]AttributeSpec = undefined;
        for (values, 0..) |value, index| {
            out[index] = attributeSpecFromValue(value, field_name);
        }
        validateAttributeSpecs(out[0..], field_name);
        break :blk out;
    };
    return &specs;
}

fn attributeSpecsFromTuple(comptime values: anytype, comptime field_name: []const u8) []const AttributeSpec {
    const struct_info = @typeInfo(@TypeOf(values)).@"struct";
    const specs = comptime blk: {
        var out: [struct_info.field_names.len]AttributeSpec = undefined;
        for (struct_info.field_names, 0..) |name, index| {
            out[index] = attributeSpecFromValue(@field(values, name), field_name);
        }
        validateAttributeSpecs(out[0..], field_name);
        break :blk out;
    };
    return &specs;
}

fn validateAttributeSpecs(comptime specs: []const AttributeSpec, comptime field_name: []const u8) void {
    @setEvalBranchQuota(32_000);
    inline for (specs, 0..) |spec, index| {
        _ = validateAttributeSpec(spec);
        inline for (specs[0..index]) |existing| {
            if (std.mem.eql(u8, existing.name, spec.name)) {
                @compileError("operation declaration field " ++ field_name ++ " duplicates attribute: " ++ spec.name);
            }
        }
    }
}

fn attributeNamesFromSpecs(comptime specs: []const AttributeSpec) []const []const u8 {
    const names = comptime blk: {
        var out: [specs.len][]const u8 = undefined;
        for (specs, 0..) |spec, index| {
            out[index] = spec.name;
        }
        break :blk out;
    };
    return &names;
}

fn attribute_names_with_required_storage(
    comptime attrs: []const []const u8,
    comptime required_attrs: []const []const u8,
) type {
    return struct {
        const values = blk: {
            var extra: usize = 0;
            for (required_attrs, 0..) |required, required_index| {
                if (required.len == 0) @compileError("required attribute name cannot be empty");
                for (required_attrs[0..required_index]) |existing_required| {
                    if (std.mem.eql(u8, existing_required, required)) {
                        @compileError("required attribute name is duplicated");
                    }
                }
                var found = false;
                for (attrs) |attr| {
                    if (std.mem.eql(u8, attr, required)) {
                        found = true;
                        break;
                    }
                }
                if (!found) extra += 1;
            }
            var out: [attrs.len + extra][]const u8 = undefined;
            for (attrs, 0..) |attr, index| {
                if (attr.len == 0) @compileError("operation attribute name cannot be empty");
                for (attrs[0..index]) |existing| {
                    if (std.mem.eql(u8, existing, attr)) {
                        @compileError("operation attribute name is duplicated");
                    }
                }
                out[index] = attr;
            }
            var index = attrs.len;
            for (required_attrs) |required| {
                var found = false;
                for (attrs) |attr| {
                    if (std.mem.eql(u8, attr, required)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    out[index] = required;
                    index += 1;
                }
            }
            break :blk out;
        };
    };
}

fn attributeNamesWithRequired(
    comptime attrs: []const []const u8,
    comptime required_attrs: []const []const u8,
) []const []const u8 {
    if (required_attrs.len == 0) return attrs;
    return &attribute_names_with_required_storage(attrs, required_attrs).values;
}

fn attribute_specs_with_required_storage(
    comptime attrs: []const AttributeSpec,
    comptime required_attrs: []const AttributeSpec,
) type {
    return struct {
        const values = blk: {
            var extra: usize = 0;
            for (required_attrs, 0..) |required, required_index| {
                _ = validateAttributeSpec(required);
                for (required_attrs[0..required_index]) |existing_required| {
                    if (std.mem.eql(u8, existing_required.name, required.name)) {
                        @compileError("required attribute name is duplicated");
                    }
                }
                var found = false;
                for (attrs) |candidate| {
                    if (std.mem.eql(u8, candidate.name, required.name)) {
                        validateCompatibleAttributeSpecs(candidate, required);
                        found = true;
                        break;
                    }
                }
                if (!found) extra += 1;
            }
            var out: [attrs.len + extra]AttributeSpec = undefined;
            for (attrs, 0..) |candidate, attr_index| {
                var merged = validateAttributeSpec(candidate);
                for (attrs[0..attr_index]) |existing| {
                    if (std.mem.eql(u8, existing.name, candidate.name)) {
                        @compileError("operation attribute name is duplicated");
                    }
                }
                for (required_attrs) |required| {
                    if (std.mem.eql(u8, required.name, candidate.name)) {
                        validateCompatibleAttributeSpecs(candidate, required);
                        if (std.meta.activeTag(merged.storage) == .any) merged = required;
                        break;
                    }
                }
                out[attr_index] = merged;
            }
            var index = attrs.len;
            for (required_attrs) |required| {
                var found = false;
                for (attrs) |candidate| {
                    if (std.mem.eql(u8, candidate.name, required.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    out[index] = required;
                    index += 1;
                }
            }
            break :blk out;
        };
    };
}

fn attributeSpecsWithRequired(
    comptime attrs: []const AttributeSpec,
    comptime required_attrs: []const AttributeSpec,
) []const AttributeSpec {
    if (required_attrs.len == 0) return attrs;
    return &attribute_specs_with_required_storage(attrs, required_attrs).values;
}

fn validateCompatibleAttributeSpecs(comptime lhs: AttributeSpec, comptime rhs: AttributeSpec) void {
    if (!std.mem.eql(u8, lhs.name, rhs.name)) return;
    if (std.meta.activeTag(lhs.storage) == .any or std.meta.activeTag(rhs.storage) == .any) return;
    switch (lhs.storage) {
        .i64 => if (std.meta.activeTag(rhs.storage) != .i64) @compileError("operation attribute storage is duplicated with incompatible kinds"),
        .bool => if (std.meta.activeTag(rhs.storage) != .bool) @compileError("operation attribute storage is duplicated with incompatible kinds"),
        .string => if (std.meta.activeTag(rhs.storage) != .string) @compileError("operation attribute storage is duplicated with incompatible kinds"),
        .dialect => |lhs_name| switch (rhs.storage) {
            .dialect => |rhs_name| {
                if (!std.mem.eql(u8, lhs_name, rhs_name)) {
                    @compileError("operation dialect attribute storage name is duplicated with incompatible names");
                }
            },
            else => @compileError("operation attribute storage is duplicated with incompatible kinds"),
        },
        .any => {},
    }
}

fn attribute_specs_with_names_storage(
    comptime specs: []const AttributeSpec,
    comptime names: []const []const u8,
) type {
    return struct {
        const values = blk: {
            var missing: usize = 0;
            for (names) |name| {
                var found = false;
                for (specs) |spec| {
                    if (std.mem.eql(u8, spec.name, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) missing += 1;
            }
            var out: [specs.len + missing]AttributeSpec = undefined;
            for (specs, 0..) |spec, index| {
                out[index] = validateAttributeSpec(spec);
            }
            var index = specs.len;
            for (names) |name| {
                var found = false;
                for (specs) |spec| {
                    if (std.mem.eql(u8, spec.name, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    out[index] = attribute.any(name);
                    index += 1;
                }
            }
            validateAttributeSpecs(out[0..], "attribute_specs");
            break :blk out;
        };
    };
}

fn attributeSpecsWithNames(
    comptime specs: []const AttributeSpec,
    comptime names: []const []const u8,
) []const AttributeSpec {
    if (names.len == 0) return specs;
    return &attribute_specs_with_names_storage(specs, names).values;
}

pub const TypeSpec = struct {
    name: []const u8,
    interfaces: []const interfaces.InterfaceEntry = &.{},
};

pub const DialectSpec = struct {
    name: []const u8,
    operations: []const OperationSpec = &.{},
    types: []const TypeSpec = &.{},
    dialect_attributes: []const []const u8 = &.{},
    interfaces: []const interfaces.InterfaceEntry = &.{},
    op_interface_fallbacks: []const OpInterfaceFallbackEntry = &.{},
    type_interface_fallbacks: []const TypeInterfaceFallbackEntry = &.{},
};

pub const DialectSpecOptions = struct {
    types: []const TypeSpec = &.{},
    dialect_attributes: []const []const u8 = &.{},
    interfaces: []const interfaces.InterfaceEntry = &.{},
    op_interface_fallbacks: []const OpInterfaceFallbackEntry = &.{},
    type_interface_fallbacks: []const TypeInterfaceFallbackEntry = &.{},
};

pub fn dialectSpec(comptime DialectType: type, comptime options: DialectSpecOptions) DialectSpec {
    if (!@hasDecl(DialectType, "name")) @compileError("dialect type must declare name");
    return .{
        .name = DialectType.name,
        .operations = operations(DialectType),
        .types = options.types,
        .dialect_attributes = options.dialect_attributes,
        .interfaces = options.interfaces,
        .op_interface_fallbacks = options.op_interface_fallbacks,
        .type_interface_fallbacks = options.type_interface_fallbacks,
    };
}

pub fn operationName(comptime dialect_name: []const u8, comptime mnemonic: []const u8) []const u8 {
    if (dialect_name.len == 0) @compileError("dialect name cannot be empty");
    if (mnemonic.len == 0) @compileError("operation mnemonic cannot be empty");
    return dialect_name ++ "." ++ mnemonic;
}

pub const shape = struct {
    pub fn of(comptime spec: anytype) interfaces.OperationShape {
        comptime validateSpec(@TypeOf(spec));
        return .{
            .operands = field(spec, "operands"),
            .results = field(spec, "results"),
            .regions = field(spec, "regions"),
            .successors = field(spec, "successors"),
        };
    }

    pub fn fixed(
        comptime operands: anytype,
        comptime results: anytype,
        comptime regions: anytype,
        comptime successors: anytype,
    ) interfaces.OperationShape {
        return of(.{
            .operands = operands,
            .results = results,
            .regions = regions,
            .successors = successors,
        });
    }

    pub fn leaf(comptime operands: anytype, comptime results: anytype) interfaces.OperationShape {
        return of(.{
            .operands = operands,
            .results = results,
            .regions = 0,
            .successors = 0,
        });
    }

    pub fn noNested(comptime spec: anytype) interfaces.OperationShape {
        comptime validateNoNestedSpec(@TypeOf(spec));
        const base = of(spec);
        return .{
            .operands = base.operands,
            .results = base.results,
            .regions = interfaces.CountRange.exactly(0),
            .successors = interfaces.CountRange.exactly(0),
        };
    }

    pub fn exactly(comptime count: usize) interfaces.CountRange {
        return interfaces.CountRange.exactly(count);
    }

    pub fn atLeast(comptime count: usize) interfaces.CountRange {
        return interfaces.CountRange.atLeast(count);
    }

    pub fn atMost(comptime count: usize) interfaces.CountRange {
        return interfaces.CountRange.atMost(count);
    }

    pub fn between(comptime min: usize, comptime max: usize) interfaces.CountRange {
        return interfaces.CountRange.between(min, max);
    }

    pub fn any() interfaces.CountRange {
        return .{};
    }

    pub fn range(comptime value: anytype) interfaces.CountRange {
        return rangeFrom(value);
    }

    fn field(comptime spec: anytype, comptime name: []const u8) interfaces.CountRange {
        if (comptime @hasField(@TypeOf(spec), name)) {
            return rangeFrom(@field(spec, name));
        }
        return .{};
    }

    fn rangeFrom(comptime value: anytype) interfaces.CountRange {
        const Value = @TypeOf(value);
        if (Value == interfaces.CountRange) return value;
        return switch (@typeInfo(Value)) {
            .comptime_int => blk: {
                if (value < 0) @compileError("operation shape count cannot be negative");
                break :blk interfaces.CountRange.exactly(@as(usize, value));
            },
            .int => |int_info| blk: {
                if (int_info.signedness == .signed and value < 0) {
                    @compileError("operation shape count cannot be negative");
                }
                break :blk interfaces.CountRange.exactly(@intCast(value));
            },
            .pointer => |pointer_info| switch (pointer_info.size) {
                .one => switch (@typeInfo(pointer_info.child)) {
                    .array => |array_info| blk: {
                        if (array_info.child == u8) {
                            @compileError("operation shape fields must use a list of component names, not one component name");
                        }
                        tryComponentNames(value.*, "shape");
                        break :blk interfaces.CountRange.exactly(array_info.len);
                    },
                    .@"struct" => |struct_info| blk: {
                        tryComponentNames(value.*, "shape");
                        break :blk interfaces.CountRange.exactly(struct_info.field_names.len);
                    },
                    else => @compileError("operation shape fields must be integer counts, CountRange values, or component name lists"),
                },
                .slice => blk: {
                    tryComponentNames(value, "shape");
                    break :blk interfaces.CountRange.exactly(value.len);
                },
                else => @compileError("operation shape fields must be integer counts, CountRange values, or component name lists"),
            },
            .array => |array_info| blk: {
                if (array_info.child == u8) {
                    @compileError("operation shape fields must use a list of component names, not one component name");
                }
                tryComponentNames(value, "shape");
                break :blk interfaces.CountRange.exactly(array_info.len);
            },
            .@"struct" => |struct_info| blk: {
                tryComponentNames(value, "shape");
                break :blk interfaces.CountRange.exactly(struct_info.field_names.len);
            },
            else => @compileError("operation shape fields must be integer counts or CountRange values"),
        };
    }

    fn validateSpec(comptime Spec: type) void {
        switch (@typeInfo(Spec)) {
            .@"struct" => |struct_info| {
                inline for (struct_info.field_names) |field_name| {
                    if (!std.mem.eql(u8, field_name, "operands") and
                        !std.mem.eql(u8, field_name, "results") and
                        !std.mem.eql(u8, field_name, "regions") and
                        !std.mem.eql(u8, field_name, "successors"))
                    {
                        @compileError("unknown operation shape field: " ++ field_name);
                    }
                }
            },
            else => @compileError("operation shape spec must be a struct literal"),
        }
    }

    fn validateNoNestedSpec(comptime Spec: type) void {
        validateSpec(Spec);
        if (@hasField(Spec, "regions")) @compileError("noNested operation shape cannot specify regions");
        if (@hasField(Spec, "successors")) @compileError("noNested operation shape cannot specify successors");
    }
};

pub const segments = struct {
    pub const operand_attribute_name = "operand_segment_sizes";
    pub const result_attribute_name = "result_segment_sizes";

    pub fn operands(comptime values: anytype) interfaces.OperationSegmentSpec {
        return sized(operand_attribute_name, values);
    }

    pub fn results(comptime values: anytype) interfaces.OperationSegmentSpec {
        return sized(result_attribute_name, values);
    }

    pub fn sized(comptime attribute_name: []const u8, comptime values: anytype) interfaces.OperationSegmentSpec {
        if (attribute_name.len == 0) @compileError("operation segment attribute name cannot be empty");
        const segment_ranges = ranges(values);
        if (segment_ranges.len == 0) @compileError("operation segment declaration cannot be empty");
        return .{
            .attribute_name = attribute_name,
            .segments = segment_ranges,
        };
    }

    fn ranges(comptime values: anytype) []const interfaces.CountRange {
        const Values = @TypeOf(values);
        if (Values == []const interfaces.CountRange) return values;
        return switch (@typeInfo(Values)) {
            .pointer => |pointer_info| switch (pointer_info.size) {
                .one => switch (@typeInfo(pointer_info.child)) {
                    .array => rangesFromArray(values.*),
                    .@"struct" => |struct_info| blk: {
                        if (!struct_info.is_tuple) @compileError("operation segment values must be a comptime slice, array, or tuple");
                        break :blk rangesFromTuple(values.*);
                    },
                    else => @compileError("operation segment values must be a comptime slice, array, or tuple"),
                },
                .slice => rangesFromSlice(values),
                else => @compileError("operation segment values must be a comptime slice, array, or tuple"),
            },
            .array => rangesFromArray(values),
            .@"struct" => |struct_info| blk: {
                if (!struct_info.is_tuple) @compileError("operation segment values must be a comptime slice, array, or tuple");
                break :blk rangesFromTuple(values);
            },
            else => @compileError("operation segment values must be a comptime slice, array, or tuple"),
        };
    }

    fn rangesFromSlice(comptime values: anytype) []const interfaces.CountRange {
        const value = comptime blk: {
            var out: [values.len]interfaces.CountRange = undefined;
            for (values, 0..) |segment, index| {
                out[index] = shape.range(segment);
            }
            break :blk out;
        };
        return &value;
    }

    fn rangesFromArray(comptime values: anytype) []const interfaces.CountRange {
        const value = comptime blk: {
            var out: [values.len]interfaces.CountRange = undefined;
            for (values, 0..) |segment, index| {
                out[index] = shape.range(segment);
            }
            break :blk out;
        };
        return &value;
    }

    fn rangesFromTuple(comptime values: anytype) []const interfaces.CountRange {
        const struct_info = @typeInfo(@TypeOf(values)).@"struct";
        const value = comptime blk: {
            var out: [struct_info.field_names.len]interfaces.CountRange = undefined;
            for (struct_info.field_names, 0..) |name, index| {
                out[index] = shape.range(@field(values, name));
            }
            break :blk out;
        };
        return &value;
    }
};

pub const opSpec = struct {
    pub const Options = struct {
        traits: interfaces.OperationTraits = .{},
        attrs: []const []const u8 = &.{},
        required_attrs: []const []const u8 = &.{},
        attribute_specs: []const AttributeSpec = &.{},
        operand_segments: ?interfaces.OperationSegmentSpec = null,
        result_segments: ?interfaces.OperationSegmentSpec = null,
        operand_types: []const interfaces.OperationTypeConstraint = &.{},
        result_types: []const interfaces.OperationTypeConstraint = &.{},
        properties: ?interfaces.OperationPropertiesModel = null,
        interfaces: []const interfaces.InterfaceEntry = &.{},
        dynamic_traits: []const OperationTraitSpec = &.{},
    };

    pub fn dialect(comptime Target: type) type {
        const Names = namesFor(Target);
        return struct {
            pub fn name(comptime mnemonic: []const u8) []const u8 {
                return Names.name(mnemonic);
            }

            pub fn state(comptime OpType: type, loc: Location) Operation.State {
                return Names.state(OpType, loc);
            }

            pub fn define(comptime spec: anytype) OperationSpec {
                comptime validateDecl(@TypeOf(spec), "mnemonic");
                return shapedWithLayout(Names.name(@field(spec, "mnemonic")), shapeFromDecl(spec), layoutFromDecl(spec), optionsFromDecl(spec));
            }

            pub fn leaf(comptime spec: anytype) OperationSpec {
                comptime validateDecl(@TypeOf(spec), "mnemonic");
                return shapedWithLayout(Names.name(@field(spec, "mnemonic")), leafShapeFromDecl(spec), layoutFromDecl(spec), optionsFromDecl(spec));
            }

            pub fn terminator(comptime spec: anytype) OperationSpec {
                comptime validateDecl(@TypeOf(spec), "mnemonic");
                return shapedWithLayout(Names.name(@field(spec, "mnemonic")), terminatorShapeFromDecl(spec), layoutFromDecl(spec), terminatorOptionsFromDecl(spec));
            }
        };
    }

    pub fn define(comptime spec: anytype) OperationSpec {
        comptime validateDecl(@TypeOf(spec), "name");
        return shapedWithLayout(@field(spec, "name"), shapeFromDecl(spec), layoutFromDecl(spec), optionsFromDecl(spec));
    }

    pub fn terminator(comptime spec: anytype) OperationSpec {
        comptime validateDecl(@TypeOf(spec), "name");
        return shapedWithLayout(@field(spec, "name"), terminatorShapeFromDecl(spec), layoutFromDecl(spec), terminatorOptionsFromDecl(spec));
    }

    pub fn shaped(comptime full_name: []const u8, comptime op_shape: interfaces.OperationShape, comptime options: Options) OperationSpec {
        return shapedWithLayout(full_name, op_shape, .{}, options);
    }

    pub fn dynamicTraits(comptime values: anytype) []const OperationTraitSpec {
        return asSlice(OperationTraitSpec, values, "dynamic_traits");
    }

    pub fn verifier(comptime verify_fn: *const fn (op_ptr: *const anyopaque) anyerror!void) interfaces.InterfaceEntry {
        return VerifyOpInterface.entryFor(verify_fn);
    }

    fn shapedWithLayout(comptime full_name: []const u8, comptime op_shape: interfaces.OperationShape, comptime op_layout: OperationLayout, comptime options: Options) OperationSpec {
        if (full_name.len == 0) @compileError("operation name cannot be empty");
        validateLayout(op_shape, op_layout);
        return .{
            .name = full_name,
            .shape = op_shape,
            .operand_names = op_layout.operands,
            .result_names = op_layout.results,
            .region_names = op_layout.regions,
            .successor_names = op_layout.successors,
            .traits = options.traits,
            .inherent_attribute_names = attributeNamesWithRequired(options.attrs, options.required_attrs),
            .required_attribute_names = options.required_attrs,
            .attribute_specs = attributeSpecsWithNames(options.attribute_specs, attributeNamesWithRequired(options.attrs, options.required_attrs)),
            .operand_segments = options.operand_segments,
            .result_segments = options.result_segments,
            .operand_type_constraints = options.operand_types,
            .result_type_constraints = options.result_types,
            .properties_model = options.properties,
            .interfaces = options.interfaces,
            .dynamic_traits = options.dynamic_traits,
        };
    }

    fn layoutFromDecl(comptime spec: anytype) OperationLayout {
        return .{
            .operands = layoutField(spec, "operands", "operand_names"),
            .results = layoutField(spec, "results", "result_names"),
            .regions = layoutField(spec, "regions", "region_names"),
            .successors = layoutField(spec, "successors", "successor_names"),
        };
    }

    fn shapeFromDecl(comptime spec: anytype) interfaces.OperationShape {
        const Spec = @TypeOf(spec);
        if (comptime @hasField(Spec, "shape")) {
            if (@hasField(Spec, "operands")) @compileError("operation declaration cannot specify both shape and operands");
            if (@hasField(Spec, "results")) @compileError("operation declaration cannot specify both shape and results");
            if (@hasField(Spec, "regions")) @compileError("operation declaration cannot specify both shape and regions");
            if (@hasField(Spec, "successors")) @compileError("operation declaration cannot specify both shape and successors");
            return shapeFromValue(@field(spec, "shape"));
        }
        return .{
            .operands = shapeField(spec, "operands"),
            .results = shapeField(spec, "results"),
            .regions = shapeField(spec, "regions"),
            .successors = shapeField(spec, "successors"),
        };
    }

    fn terminatorShapeFromDecl(comptime spec: anytype) interfaces.OperationShape {
        const Spec = @TypeOf(spec);
        if (@hasField(Spec, "shape")) @compileError("terminator operation declaration cannot specify shape");
        return .{
            .operands = shapeField(spec, "operands"),
            .results = shapeFieldOrExact(spec, "results", 0),
            .regions = shapeFieldOrExact(spec, "regions", 0),
            .successors = shapeFieldOrExact(spec, "successors", 0),
        };
    }

    fn shapeFromValue(comptime value: anytype) interfaces.OperationShape {
        const Value = @TypeOf(value);
        if (Value == interfaces.OperationShape) return value;
        return shape.of(value);
    }

    fn leafShapeFromDecl(comptime spec: anytype) interfaces.OperationShape {
        const Spec = @TypeOf(spec);
        if (@hasField(Spec, "shape")) @compileError("leaf operation declaration cannot specify shape");
        if (@hasField(Spec, "regions")) @compileError("leaf operation declaration cannot specify regions");
        if (@hasField(Spec, "successors")) @compileError("leaf operation declaration cannot specify successors");
        return .{
            .operands = shapeField(spec, "operands"),
            .results = shapeField(spec, "results"),
            .regions = interfaces.CountRange.exactly(0),
            .successors = interfaces.CountRange.exactly(0),
        };
    }

    fn shapeField(comptime spec: anytype, comptime name: []const u8) interfaces.CountRange {
        if (comptime @hasField(@TypeOf(spec), name)) return shape.rangeFrom(@field(spec, name));
        return .{};
    }

    fn layoutField(comptime spec: anytype, comptime shape_name: []const u8, comptime names_name: []const u8) []const []const u8 {
        const inferred = if (comptime @hasField(@TypeOf(spec), shape_name))
            componentNamesFromValue(@field(spec, shape_name), shape_name)
        else
            &.{};
        if (comptime @hasField(@TypeOf(spec), names_name)) {
            const explicit = componentNamesFromValue(@field(spec, names_name), names_name);
            if (inferred.len != 0) {
                @compileError("operation declaration cannot specify both named " ++ shape_name ++ " and " ++ names_name);
            }
            return explicit;
        }
        return inferred;
    }

    fn validateLayout(comptime op_shape: interfaces.OperationShape, comptime op_layout: OperationLayout) void {
        validateLayoutRange(op_shape.operands, op_layout.operands, "operand");
        validateLayoutRange(op_shape.results, op_layout.results, "result");
        validateLayoutRange(op_shape.regions, op_layout.regions, "region");
        validateLayoutRange(op_shape.successors, op_layout.successors, "successor");
    }

    fn validateLayoutRange(comptime range: interfaces.CountRange, comptime names: []const []const u8, comptime kind: []const u8) void {
        if (range.max) |max| {
            if (names.len > max) {
                @compileError("operation " ++ kind ++ " names cannot exceed the operation shape maximum");
            }
        }
    }

    fn shapeFieldOrExact(comptime spec: anytype, comptime name: []const u8, comptime count: usize) interfaces.CountRange {
        if (comptime @hasField(@TypeOf(spec), name)) return shape.rangeFrom(@field(spec, name));
        return interfaces.CountRange.exactly(count);
    }

    fn optionsFromDecl(comptime spec: anytype) Options {
        const attr_specs = attributeSpecsFromDecl(spec, "attrs");
        const required_attr_specs = attributeSpecsFromDecl(spec, "required_attrs");
        return .{
            .traits = declField(spec, "traits", interfaces.OperationTraits{}),
            .attrs = attributeNamesFromSpecs(attr_specs),
            .required_attrs = attributeNamesFromSpecs(required_attr_specs),
            .attribute_specs = attributeSpecsWithRequired(attr_specs, required_attr_specs),
            .operand_segments = segmentDecl(spec, "operand_segments"),
            .result_segments = segmentDecl(spec, "result_segments"),
            .operand_types = declSlice(interfaces.OperationTypeConstraint, spec, "operand_types"),
            .result_types = declSlice(interfaces.OperationTypeConstraint, spec, "result_types"),
            .properties = declField(spec, "properties", @as(?interfaces.OperationPropertiesModel, null)),
            .interfaces = declSlice(interfaces.InterfaceEntry, spec, "interfaces"),
            .dynamic_traits = if (comptime @hasField(@TypeOf(spec), "dynamic_traits")) dynamicTraits(@field(spec, "dynamic_traits")) else &.{},
        };
    }

    fn terminatorOptionsFromDecl(comptime spec: anytype) Options {
        return optionsWithDynamicTrait(optionsFromDecl(spec), trait(core_traits.Terminator));
    }

    fn declField(comptime spec: anytype, comptime name: []const u8, comptime default: anytype) @TypeOf(default) {
        if (comptime @hasField(@TypeOf(spec), name)) return @field(spec, name);
        return default;
    }

    fn declSlice(comptime Element: type, comptime spec: anytype, comptime name: []const u8) []const Element {
        if (comptime !@hasField(@TypeOf(spec), name)) return &.{};
        return asSlice(Element, @field(spec, name), name);
    }

    fn segmentDecl(comptime spec: anytype, comptime name: []const u8) ?interfaces.OperationSegmentSpec {
        if (comptime !@hasField(@TypeOf(spec), name)) return null;
        const value = @field(spec, name);
        if (@TypeOf(value) != interfaces.OperationSegmentSpec) {
            @compileError("operation declaration field " ++ name ++ " must be an OperationSegmentSpec");
        }
        return value;
    }

    fn asSlice(comptime Element: type, comptime values: anytype, comptime name: []const u8) []const Element {
        const Values = @TypeOf(values);
        if (Values == []const Element) return values;
        switch (@typeInfo(Values)) {
            .pointer => |pointer_info| {
                switch (pointer_info.size) {
                    .one => switch (@typeInfo(pointer_info.child)) {
                        .array => |array_info| {
                            const typed = comptime blk: {
                                var out: [array_info.len]Element = undefined;
                                for (values.*, 0..) |value, index| {
                                    out[index] = asElement(Element, value);
                                }
                                break :blk out;
                            };
                            return &typed;
                        },
                        .@"struct" => |struct_info| {
                            if (!struct_info.is_tuple) @compileError("operation declaration field " ++ name ++ " must be a comptime slice, array, or tuple");
                            const typed = comptime blk: {
                                var out: [struct_info.field_names.len]Element = undefined;
                                for (struct_info.field_names, 0..) |field_name, index| {
                                    out[index] = asElement(Element, @field(values.*, field_name));
                                }
                                break :blk out;
                            };
                            return &typed;
                        },
                        else => @compileError("operation declaration field " ++ name ++ " must be a comptime slice or array pointer"),
                    },
                    .slice => {
                        const typed = comptime blk: {
                            var out: [values.len]Element = undefined;
                            for (values, 0..) |value, index| {
                                out[index] = asElement(Element, value);
                            }
                            break :blk out;
                        };
                        return &typed;
                    },
                    else => @compileError("operation declaration field " ++ name ++ " must be a comptime slice or array pointer"),
                }
            },
            .array => |array_info| {
                const typed = comptime blk: {
                    var out: [array_info.len]Element = undefined;
                    for (values, 0..) |value, index| {
                        out[index] = asElement(Element, value);
                    }
                    break :blk out;
                };
                return &typed;
            },
            .@"struct" => |struct_info| {
                if (!struct_info.is_tuple) @compileError("operation declaration field " ++ name ++ " must be a comptime slice, array, or tuple");
                const typed = comptime blk: {
                    var out: [struct_info.field_names.len]Element = undefined;
                    for (struct_info.field_names, 0..) |field_name, index| {
                        out[index] = asElement(Element, @field(values, field_name));
                    }
                    break :blk out;
                };
                return &typed;
            },
            else => @compileError("operation declaration field " ++ name ++ " must be a comptime slice or array pointer"),
        }
    }

    fn asElement(comptime Element: type, comptime value: anytype) Element {
        const Value = @TypeOf(value);
        if (Element == OperationTraitSpec and Value == type) return trait(value);
        if (Value == Element) return value;
        return switch (@typeInfo(Element)) {
            .@"struct" => |element_info| blk: {
                var out: Element = undefined;
                for (element_info.field_names) |field_name| {
                    @field(out, field_name) = @field(value, field_name);
                }
                break :blk out;
            },
            else => value,
        };
    }

    fn optionsWithDynamicTrait(comptime options: Options, comptime trait_spec: OperationTraitSpec) Options {
        return .{
            .traits = options.traits.merge(trait_spec.traits),
            .attrs = options.attrs,
            .required_attrs = options.required_attrs,
            .attribute_specs = options.attribute_specs,
            .operand_segments = options.operand_segments,
            .result_segments = options.result_segments,
            .operand_types = options.operand_types,
            .result_types = options.result_types,
            .properties = options.properties,
            .interfaces = options.interfaces,
            .dynamic_traits = dynamicTraitsWith(options.dynamic_traits, trait_spec),
        };
    }

    fn dynamicTraitsWith(comptime dynamic_traits: []const OperationTraitSpec, comptime trait_spec: OperationTraitSpec) []const OperationTraitSpec {
        for (dynamic_traits) |existing| {
            if (existing.id == trait_spec.id) @compileError("operation dynamic trait is duplicated");
        }
        const values = comptime blk: {
            var out: [dynamic_traits.len + 1]OperationTraitSpec = undefined;
            for (dynamic_traits, 0..) |existing, index| {
                out[index] = existing;
            }
            out[dynamic_traits.len] = trait_spec;
            break :blk out;
        };
        return &values;
    }

    fn validateDecl(comptime Spec: type, comptime name_field: []const u8) void {
        switch (@typeInfo(Spec)) {
            .@"struct" => |struct_info| {
                if (!@hasField(Spec, name_field)) @compileError("operation declaration must declare " ++ name_field);
                inline for (struct_info.field_names) |field_name| {
                    if (!isDeclField(field_name, name_field)) {
                        @compileError("unknown operation declaration field: " ++ field_name);
                    }
                }
            },
            else => @compileError("operation declaration must be a struct literal"),
        }
    }

    fn isDeclField(comptime field_name: []const u8, comptime name_field: []const u8) bool {
        return std.mem.eql(u8, field_name, name_field) or
            std.mem.eql(u8, field_name, "shape") or
            std.mem.eql(u8, field_name, "operands") or
            std.mem.eql(u8, field_name, "operand_names") or
            std.mem.eql(u8, field_name, "results") or
            std.mem.eql(u8, field_name, "result_names") or
            std.mem.eql(u8, field_name, "regions") or
            std.mem.eql(u8, field_name, "region_names") or
            std.mem.eql(u8, field_name, "successors") or
            std.mem.eql(u8, field_name, "successor_names") or
            std.mem.eql(u8, field_name, "traits") or
            std.mem.eql(u8, field_name, "attrs") or
            std.mem.eql(u8, field_name, "required_attrs") or
            std.mem.eql(u8, field_name, "operand_segments") or
            std.mem.eql(u8, field_name, "result_segments") or
            std.mem.eql(u8, field_name, "operand_types") or
            std.mem.eql(u8, field_name, "result_types") or
            std.mem.eql(u8, field_name, "properties") or
            std.mem.eql(u8, field_name, "interfaces") or
            std.mem.eql(u8, field_name, "dynamic_traits");
    }

    fn namesFor(comptime Target: type) type {
        if (comptime isDialectType(Target)) return operationNames(Target);
        if (comptime isOperationNamesType(Target)) return Target;
        @compileError("opSpec.dialect expects a dialect type or operationNames result");
    }

    fn isDialectType(comptime Target: type) bool {
        if (!@hasDecl(Target, "name")) return false;
        return switch (@typeInfo(@TypeOf(@field(Target, "name")))) {
            .pointer => true,
            else => false,
        };
    }

    fn isOperationNamesType(comptime Target: type) bool {
        if (!@hasDecl(Target, "name")) return false;
        if (!@hasDecl(Target, "state")) return false;
        return switch (@typeInfo(@TypeOf(@field(Target, "name")))) {
            .@"fn" => true,
            else => false,
        };
    }
};

pub const typeConstraint = struct {
    pub fn exact(comptime index: usize, comptime type_name: []const u8) interfaces.OperationTypeConstraint {
        return .{
            .index = index,
            .type_name = type_name,
        };
    }

    pub fn parameterized(comptime index: usize, comptime type_name: []const u8) interfaces.OperationTypeConstraint {
        return .{
            .index = index,
            .type_name = type_name,
            .allow_parameterized = true,
        };
    }
};

pub fn operationAttribute(comptime spec: OperationSpec, comptime attr_name: []const u8) AttributeSpec {
    inline for (spec.attribute_specs) |attribute_spec| {
        if (comptime std.mem.eql(u8, attribute_spec.name, attr_name)) return attribute_spec;
    }
    @compileError("unknown operation attribute: " ++ attr_name);
}

pub fn operationDialectAttributeName(comptime spec: OperationSpec, comptime attr_name: []const u8) []const u8 {
    const attribute_spec = comptime operationAttribute(spec, attr_name);
    return switch (attribute_spec.storage) {
        .dialect => |dialect_attr_name| dialect_attr_name,
        .any => @compileError("operation attribute does not declare dialect storage: " ++ attr_name),
        else => @compileError("operation attribute is not dialect-backed: " ++ attr_name),
    };
}

fn validateOperationAttributeStorage(comptime spec: OperationSpec, comptime attr_name: []const u8, comptime expected: std.meta.Tag(AttributeStorage)) void {
    const attribute_spec = comptime operationAttribute(spec, attr_name);
    const actual = comptime std.meta.activeTag(attribute_spec.storage);
    if (actual == expected) return;
    if (actual == .any) @compileError("operation attribute does not declare storage kind: " ++ attr_name);
    @compileError("operation attribute storage kind does not match accessor: " ++ attr_name);
}

fn operationAttributeAccessors(comptime OpType: type, comptime spec: OperationSpec) type {
    return struct {
        pub fn setI64Attr(self: OpType, comptime attr_name: []const u8, value: i64) !void {
            validateOperationAttributeStorage(spec, attr_name, .i64);
            try self.op.setAttr(attr_name, try self.op.getContext().getI64Attr(value));
        }

        pub fn getI64Attr(self: OpType, comptime attr_name: []const u8) ?i64 {
            validateOperationAttributeStorage(spec, attr_name, .i64);
            const attribute_value = self.op.getAttrAs(Attribute.IntegerAttr, attr_name) orelse return null;
            return attribute_value.getValue();
        }

        pub fn setBoolAttr(self: OpType, comptime attr_name: []const u8, value: bool) !void {
            validateOperationAttributeStorage(spec, attr_name, .bool);
            try self.op.setAttr(attr_name, try self.op.getContext().getBoolAttr(value));
        }

        pub fn getBoolAttr(self: OpType, comptime attr_name: []const u8) ?bool {
            validateOperationAttributeStorage(spec, attr_name, .bool);
            const attribute_value = self.op.getAttrAs(Attribute.BoolAttr, attr_name) orelse return null;
            return attribute_value.getValue();
        }

        pub fn setStringAttr(self: OpType, comptime attr_name: []const u8, value: []const u8) !void {
            validateOperationAttributeStorage(spec, attr_name, .string);
            try self.op.setAttr(attr_name, try self.op.getContext().getStringAttr(value));
        }

        pub fn getStringAttr(self: OpType, comptime attr_name: []const u8) ?[]const u8 {
            validateOperationAttributeStorage(spec, attr_name, .string);
            const attribute_value = self.op.getAttrAs(Attribute.StringAttr, attr_name) orelse return null;
            return attribute_value.getValue();
        }

        pub fn setDialectAttrPayload(self: OpType, comptime attr_name: []const u8, payload: []const u8) !void {
            try self.op.setAttr(attr_name, try self.op.getContext().getDialectAttr(operationDialectAttributeName(spec, attr_name), payload));
        }

        pub fn getDialectAttrPayload(self: OpType, comptime attr_name: []const u8) ?[]const u8 {
            const attribute_value = self.op.getAttr(attr_name) orelse return null;
            if (!std.mem.eql(u8, attribute_value.abstract.name, operationDialectAttributeName(spec, attr_name))) return null;
            const dialect_attr = attribute_value.cast(Attribute.DialectAttr) orelse return null;
            return dialect_attr.payload;
        }

        pub fn dialectAttrName(comptime attr_name: []const u8) []const u8 {
            return operationDialectAttributeName(spec, attr_name);
        }
    };
}

pub const operationTemplate = struct {
    pub const FoldFn = *const fn (
        op: *const anyopaque,
        results: *interfaces.FoldResults,
    ) anyerror!void;

    pub const FixedResultTypeFn = *const fn (ctx: *Context) anyerror!Type;

    pub fn dialect(comptime DialectType: type) type {
        return struct {
            pub fn binarySameType(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
            ) type {
                return operationTemplate.binarySameType(DialectType, mnemonic, options);
            }

            pub fn binarySameTypeFold(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
                comptime fold_fn: FoldFn,
            ) type {
                return operationTemplate.binarySameTypeFold(DialectType, mnemonic, options, fold_fn);
            }

            pub fn binaryFixedResult(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
                comptime result_type_fn: FixedResultTypeFn,
            ) type {
                return operationTemplate.binaryFixedResult(DialectType, mnemonic, options, result_type_fn);
            }

            pub fn unarySameType(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
            ) type {
                return operationTemplate.unarySameType(DialectType, mnemonic, options);
            }

            pub fn unarySameTypeFold(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
                comptime fold_fn: FoldFn,
            ) type {
                return operationTemplate.unarySameTypeFold(DialectType, mnemonic, options, fold_fn);
            }

            pub fn unaryFixedResult(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
                comptime result_type_fn: FixedResultTypeFn,
            ) type {
                return operationTemplate.unaryFixedResult(DialectType, mnemonic, options, result_type_fn);
            }

            pub fn unarySameTypeStringAttr(
                comptime mnemonic: []const u8,
                comptime attr_name: []const u8,
                comptime attr_value: []const u8,
                comptime options: opSpec.Options,
            ) type {
                return operationTemplate.unarySameTypeStringAttr(DialectType, mnemonic, attr_name, attr_value, options);
            }

            pub fn unaryExplicitTypeFold(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
                comptime fold_fn: FoldFn,
            ) type {
                return operationTemplate.unaryExplicitTypeFold(DialectType, mnemonic, options, fold_fn);
            }

            pub fn unaryExplicitType(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
            ) type {
                return operationTemplate.unaryExplicitType(DialectType, mnemonic, options);
            }

            pub fn unaryNoResult(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
            ) type {
                return operationTemplate.unaryNoResult(DialectType, mnemonic, options);
            }

            pub fn ternarySameType(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
            ) type {
                return operationTemplate.ternarySameType(DialectType, mnemonic, options);
            }

            pub fn ternarySameTypeFold(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
                comptime fold_fn: FoldFn,
            ) type {
                return operationTemplate.ternarySameTypeFold(DialectType, mnemonic, options, fold_fn);
            }

            pub fn selectSameType(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
            ) type {
                return operationTemplate.selectSameType(DialectType, mnemonic, options);
            }

            pub fn selectSameTypeFold(
                comptime mnemonic: []const u8,
                comptime options: opSpec.Options,
                comptime fold_fn: FoldFn,
            ) type {
                return operationTemplate.selectSameTypeFold(DialectType, mnemonic, options, fold_fn);
            }

            pub fn explicitLeaf(
                comptime OpType: type,
                comptime spec: anytype,
            ) type {
                return operationTemplate.explicitLeaf(DialectType, OpType, spec);
            }

            pub fn explicit(
                comptime OpType: type,
                comptime spec: anytype,
            ) type {
                return operationTemplate.explicit(DialectType, OpType, spec);
            }

            pub fn explicitTerminator(
                comptime OpType: type,
                comptime spec: anytype,
            ) type {
                return operationTemplate.explicitTerminator(DialectType, OpType, spec);
            }
        };
    }

    pub fn binarySameType(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
    ) type {
        return binarySameTypeImpl(DialectType, mnemonic, options, null);
    }

    pub fn binarySameTypeFold(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: FoldFn,
    ) type {
        return binarySameTypeImpl(DialectType, mnemonic, options, fold_fn);
    }

    pub fn binaryFixedResult(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime result_type_fn: FixedResultTypeFn,
    ) type {
        return binaryFixedResultImpl(DialectType, mnemonic, options, result_type_fn);
    }

    pub fn unarySameType(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
    ) type {
        return unarySameTypeImpl(DialectType, mnemonic, options, null);
    }

    pub fn unarySameTypeFold(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: FoldFn,
    ) type {
        return unarySameTypeImpl(DialectType, mnemonic, options, fold_fn);
    }

    pub fn unaryFixedResult(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime result_type_fn: FixedResultTypeFn,
    ) type {
        return unaryFixedResultImpl(DialectType, mnemonic, options, result_type_fn);
    }

    pub fn unarySameTypeStringAttr(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime attr_name: []const u8,
        comptime attr_value: []const u8,
        comptime options: opSpec.Options,
    ) type {
        return unarySameTypeStringAttrImpl(DialectType, mnemonic, attr_name, attr_value, options);
    }

    pub fn unaryExplicitTypeFold(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: FoldFn,
    ) type {
        return unaryExplicitTypeImpl(DialectType, mnemonic, options, fold_fn);
    }

    pub fn unaryExplicitType(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
    ) type {
        return unaryExplicitTypeImpl(DialectType, mnemonic, options, null);
    }

    pub fn unaryNoResult(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
    ) type {
        return unaryNoResultImpl(DialectType, mnemonic, options);
    }

    pub fn ternarySameType(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
    ) type {
        return ternarySameTypeImpl(DialectType, mnemonic, options, null);
    }

    pub fn ternarySameTypeFold(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: FoldFn,
    ) type {
        return ternarySameTypeImpl(DialectType, mnemonic, options, fold_fn);
    }

    pub fn selectSameType(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
    ) type {
        return selectSameTypeImpl(DialectType, mnemonic, options, null);
    }

    pub fn selectSameTypeFold(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: FoldFn,
    ) type {
        return selectSameTypeImpl(DialectType, mnemonic, options, fold_fn);
    }

    pub fn explicitLeaf(
        comptime DialectType: type,
        comptime OpType: type,
        comptime spec: anytype,
    ) type {
        const op_specs = opSpec.dialect(DialectType);
        const generated_spec = op_specs.leaf(spec);
        const accessors = operationAttributeAccessors(OpType, generated_spec);
        return struct {
            pub const operation_spec = generated_spec;
            pub const operation_name = generated_spec.name;
            pub const setI64Attr = accessors.setI64Attr;
            pub const getI64Attr = accessors.getI64Attr;
            pub const setBoolAttr = accessors.setBoolAttr;
            pub const getBoolAttr = accessors.getBoolAttr;
            pub const setStringAttr = accessors.setStringAttr;
            pub const getStringAttr = accessors.getStringAttr;
            pub const setDialectAttrPayload = accessors.setDialectAttrPayload;
            pub const getDialectAttrPayload = accessors.getDialectAttrPayload;
            pub const dialectAttrName = accessors.dialectAttrName;

            pub fn createLeaf(
                ctx: *Context,
                loc: Location,
                operands: []const *IrValue,
                result_types: []const Type,
            ) !OpType {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(operands);
                state.addTypes(result_types);
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getOperand(self: OpType, comptime component_name: []const u8) *IrValue {
                return operand(operation_spec, self.op, component_name);
            }

            pub fn getOptionalOperand(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return optionalOperand(operation_spec, self.op, component_name);
            }

            pub fn getOperandSegment(self: OpType, comptime component_name: []const u8) ?[]const *IrValue {
                return operandSegmentValues(operation_spec, self.op, component_name);
            }

            pub fn getOperandSegmentValue(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return operandSegmentValue(operation_spec, self.op, component_name);
            }

            pub fn getNamedResult(self: OpType, comptime component_name: []const u8) *IrValue {
                return result(operation_spec, self.op, component_name);
            }

            pub fn getOptionalResult(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return optionalResult(operation_spec, self.op, component_name);
            }

            pub fn getResultSegment(self: OpType, comptime component_name: []const u8) ?[]IrValue {
                return resultSegmentValues(operation_spec, self.op, component_name);
            }

            pub fn getResultSegmentValue(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return resultSegmentValue(operation_spec, self.op, component_name);
            }

            pub fn getResult(self: OpType) *IrValue {
                if (operation_spec.result_names.len != 1) {
                    @compileError("operationTemplate.explicitLeaf getResult requires exactly one named result");
                }
                return result(operation_spec, self.op, operation_spec.result_names[0]);
            }
        };
    }

    pub fn explicit(
        comptime DialectType: type,
        comptime OpType: type,
        comptime spec: anytype,
    ) type {
        const op_specs = opSpec.dialect(DialectType);
        const generated_spec = op_specs.define(spec);
        const accessors = operationAttributeAccessors(OpType, generated_spec);
        return struct {
            pub const operation_spec = generated_spec;
            pub const operation_name = generated_spec.name;
            pub const setI64Attr = accessors.setI64Attr;
            pub const getI64Attr = accessors.getI64Attr;
            pub const setBoolAttr = accessors.setBoolAttr;
            pub const getBoolAttr = accessors.getBoolAttr;
            pub const setStringAttr = accessors.setStringAttr;
            pub const getStringAttr = accessors.getStringAttr;
            pub const setDialectAttrPayload = accessors.setDialectAttrPayload;
            pub const getDialectAttrPayload = accessors.getDialectAttrPayload;
            pub const dialectAttrName = accessors.dialectAttrName;

            pub fn createOperation(
                ctx: *Context,
                loc: Location,
                operands: []const *IrValue,
                result_types: []const Type,
                region_bodies: []const *Region,
                successors: []const *Block,
            ) !OpType {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(operands);
                state.addTypes(result_types);
                state.addRegionBodies(region_bodies);
                state.addSuccessors(successors);
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getOperand(self: OpType, comptime component_name: []const u8) *IrValue {
                return operand(operation_spec, self.op, component_name);
            }

            pub fn getOptionalOperand(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return optionalOperand(operation_spec, self.op, component_name);
            }

            pub fn getOperandSegment(self: OpType, comptime component_name: []const u8) ?[]const *IrValue {
                return operandSegmentValues(operation_spec, self.op, component_name);
            }

            pub fn getOperandSegmentValue(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return operandSegmentValue(operation_spec, self.op, component_name);
            }

            pub fn getNamedResult(self: OpType, comptime component_name: []const u8) *IrValue {
                return result(operation_spec, self.op, component_name);
            }

            pub fn getOptionalResult(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return optionalResult(operation_spec, self.op, component_name);
            }

            pub fn getResultSegment(self: OpType, comptime component_name: []const u8) ?[]IrValue {
                return resultSegmentValues(operation_spec, self.op, component_name);
            }

            pub fn getResultSegmentValue(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return resultSegmentValue(operation_spec, self.op, component_name);
            }

            pub fn getRegion(self: OpType, comptime component_name: []const u8) *Region {
                return region(operation_spec, self.op, component_name);
            }

            pub fn getOptionalRegion(self: OpType, comptime component_name: []const u8) ?*Region {
                return optionalRegion(operation_spec, self.op, component_name);
            }

            pub fn getSuccessor(self: OpType, comptime component_name: []const u8) *Block {
                return successor(operation_spec, self.op, component_name);
            }

            pub fn getOptionalSuccessor(self: OpType, comptime component_name: []const u8) ?*Block {
                return optionalSuccessor(operation_spec, self.op, component_name);
            }
        };
    }

    pub fn explicitTerminator(
        comptime DialectType: type,
        comptime OpType: type,
        comptime spec: anytype,
    ) type {
        const op_specs = opSpec.dialect(DialectType);
        const generated_spec = op_specs.terminator(spec);
        const accessors = operationAttributeAccessors(OpType, generated_spec);
        return struct {
            pub const operation_spec = generated_spec;
            pub const operation_name = generated_spec.name;
            pub const setI64Attr = accessors.setI64Attr;
            pub const getI64Attr = accessors.getI64Attr;
            pub const setBoolAttr = accessors.setBoolAttr;
            pub const getBoolAttr = accessors.getBoolAttr;
            pub const setStringAttr = accessors.setStringAttr;
            pub const getStringAttr = accessors.getStringAttr;
            pub const setDialectAttrPayload = accessors.setDialectAttrPayload;
            pub const getDialectAttrPayload = accessors.getDialectAttrPayload;
            pub const dialectAttrName = accessors.dialectAttrName;

            pub fn createTerminator(
                ctx: *Context,
                loc: Location,
                operands: []const *IrValue,
                successors: []const *Block,
            ) !OpType {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(operands);
                state.addSuccessors(successors);
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getOperand(self: OpType, comptime component_name: []const u8) *IrValue {
                return operand(operation_spec, self.op, component_name);
            }

            pub fn getOptionalOperand(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return optionalOperand(operation_spec, self.op, component_name);
            }

            pub fn getOperandSegment(self: OpType, comptime component_name: []const u8) ?[]const *IrValue {
                return operandSegmentValues(operation_spec, self.op, component_name);
            }

            pub fn getOperandSegmentValue(self: OpType, comptime component_name: []const u8) ?*IrValue {
                return operandSegmentValue(operation_spec, self.op, component_name);
            }

            pub fn getSuccessor(self: OpType, comptime component_name: []const u8) *Block {
                return successor(operation_spec, self.op, component_name);
            }

            pub fn getOptionalSuccessor(self: OpType, comptime component_name: []const u8) ?*Block {
                return optionalSuccessor(operation_spec, self.op, component_name);
            }
        };
    }

    fn binarySameTypeImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: ?FoldFn,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(2, 1), options);
        if (fold_fn) |fold_impl| {
            return struct {
                op: *Operation,

                pub const operation_spec = generated_spec;
                pub const operation_name = operation_spec.name;
                pub const fold = fold_impl;

                pub fn create(ctx: *Context, loc: Location, lhs: *IrValue, rhs: *IrValue) !@This() {
                    var builder = OperationBuilder.init(ctx);
                    var state = Operation.State.init(operation_name, loc);
                    state.addOperands(&.{ lhs, rhs });
                    state.addTypes(&.{lhs.type});
                    const op = try builder.create(state);
                    return .{ .op = op };
                }

                pub fn getResult(self: *const @This()) *IrValue {
                    return self.op.getResult(0).?;
                }

                pub fn getLhs(self: @This()) *IrValue {
                    return self.op.getOperand(0).?;
                }

                pub fn getRhs(self: @This()) *IrValue {
                    return self.op.getOperand(1).?;
                }
            };
        }

        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, lhs: *IrValue, rhs: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{ lhs, rhs });
                state.addTypes(&.{lhs.type});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getLhs(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }

            pub fn getRhs(self: @This()) *IrValue {
                return self.op.getOperand(1).?;
            }
        };
    }

    fn binaryFixedResultImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime result_type_fn: FixedResultTypeFn,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(2, 1), options);
        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, lhs: *IrValue, rhs: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{ lhs, rhs });
                state.addTypes(&.{try result_type_fn(ctx)});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getLhs(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }

            pub fn getRhs(self: @This()) *IrValue {
                return self.op.getOperand(1).?;
            }
        };
    }

    fn unarySameTypeImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: ?FoldFn,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(1, 1), options);
        if (fold_fn) |fold_impl| {
            return struct {
                op: *Operation,

                pub const operation_spec = generated_spec;
                pub const operation_name = operation_spec.name;
                pub const fold = fold_impl;

                pub fn create(ctx: *Context, loc: Location, input: *IrValue) !@This() {
                    var builder = OperationBuilder.init(ctx);
                    var state = Operation.State.init(operation_name, loc);
                    state.addOperands(&.{input});
                    state.addTypes(&.{input.type});
                    const op = try builder.create(state);
                    return .{ .op = op };
                }

                pub fn getResult(self: *const @This()) *IrValue {
                    return self.op.getResult(0).?;
                }

                pub fn getInput(self: @This()) *IrValue {
                    return self.op.getOperand(0).?;
                }
            };
        }

        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, input: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{input});
                state.addTypes(&.{input.type});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getInput(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }
        };
    }

    fn unaryFixedResultImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime result_type_fn: FixedResultTypeFn,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(1, 1), options);
        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, input: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{input});
                state.addTypes(&.{try result_type_fn(ctx)});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getInput(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }
        };
    }

    fn unarySameTypeStringAttrImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime attr_name: []const u8,
        comptime attr_value: []const u8,
        comptime options: opSpec.Options,
    ) type {
        const generated_options = optionsWithAttr(options, attr_name);
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(1, 1), generated_options);
        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, input: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{input});
                state.addTypes(&.{input.type});
                const op = try builder.create(state);
                try op.setAttr(attr_name, try ctx.getStringAttr(attr_value));
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getInput(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }

            pub fn getStringAttr(self: @This()) ?[]const u8 {
                const attr = self.op.getAttrAs(Attribute.StringAttr, attr_name) orelse return null;
                return attr.getValue();
            }
        };
    }

    fn unaryExplicitTypeImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: ?FoldFn,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(1, 1), options);
        if (fold_fn) |fold_impl| {
            return struct {
                op: *Operation,

                pub const operation_spec = generated_spec;
                pub const operation_name = operation_spec.name;
                pub const fold = fold_impl;

                pub fn create(ctx: *Context, loc: Location, input: *IrValue, result_type: Type) !@This() {
                    var builder = OperationBuilder.init(ctx);
                    var state = Operation.State.init(operation_name, loc);
                    state.addOperands(&.{input});
                    state.addTypes(&.{result_type});
                    const op = try builder.create(state);
                    return .{ .op = op };
                }

                pub fn getResult(self: *const @This()) *IrValue {
                    return self.op.getResult(0).?;
                }

                pub fn getInput(self: @This()) *IrValue {
                    return self.op.getOperand(0).?;
                }
            };
        }

        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, input: *IrValue, result_type: Type) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{input});
                state.addTypes(&.{result_type});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getInput(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }
        };
    }

    fn unaryNoResultImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(1, 0), options);
        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, input: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{input});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getInput(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }
        };
    }

    fn ternarySameTypeImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: ?FoldFn,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(3, 1), options);
        if (fold_fn) |fold_impl| {
            return struct {
                op: *Operation,

                pub const operation_spec = generated_spec;
                pub const operation_name = operation_spec.name;
                pub const fold = fold_impl;

                pub fn create(ctx: *Context, loc: Location, a: *IrValue, b: *IrValue, c: *IrValue) !@This() {
                    var builder = OperationBuilder.init(ctx);
                    var state = Operation.State.init(operation_name, loc);
                    state.addOperands(&.{ a, b, c });
                    state.addTypes(&.{a.type});
                    const op = try builder.create(state);
                    return .{ .op = op };
                }

                pub fn getResult(self: *const @This()) *IrValue {
                    return self.op.getResult(0).?;
                }

                pub fn getA(self: @This()) *IrValue {
                    return self.op.getOperand(0).?;
                }

                pub fn getB(self: @This()) *IrValue {
                    return self.op.getOperand(1).?;
                }

                pub fn getC(self: @This()) *IrValue {
                    return self.op.getOperand(2).?;
                }
            };
        }

        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, a: *IrValue, b: *IrValue, c: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{ a, b, c });
                state.addTypes(&.{a.type});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getA(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }

            pub fn getB(self: @This()) *IrValue {
                return self.op.getOperand(1).?;
            }

            pub fn getC(self: @This()) *IrValue {
                return self.op.getOperand(2).?;
            }
        };
    }

    fn selectSameTypeImpl(
        comptime DialectType: type,
        comptime mnemonic: []const u8,
        comptime options: opSpec.Options,
        comptime fold_fn: ?FoldFn,
    ) type {
        const generated_spec = opSpec.shaped(operationName(DialectType.name, mnemonic), shape.leaf(3, 1), options);
        if (fold_fn) |fold_impl| {
            return struct {
                op: *Operation,

                pub const operation_spec = generated_spec;
                pub const operation_name = operation_spec.name;
                pub const fold = fold_impl;

                pub fn create(ctx: *Context, loc: Location, condition: *IrValue, true_value: *IrValue, false_value: *IrValue) !@This() {
                    var builder = OperationBuilder.init(ctx);
                    var state = Operation.State.init(operation_name, loc);
                    state.addOperands(&.{ condition, true_value, false_value });
                    state.addTypes(&.{true_value.type});
                    const op = try builder.create(state);
                    return .{ .op = op };
                }

                pub fn getResult(self: *const @This()) *IrValue {
                    return self.op.getResult(0).?;
                }

                pub fn getCondition(self: @This()) *IrValue {
                    return self.op.getOperand(0).?;
                }

                pub fn getTrueValue(self: @This()) *IrValue {
                    return self.op.getOperand(1).?;
                }

                pub fn getFalseValue(self: @This()) *IrValue {
                    return self.op.getOperand(2).?;
                }
            };
        }

        return struct {
            op: *Operation,

            pub const operation_spec = generated_spec;
            pub const operation_name = operation_spec.name;

            pub fn create(ctx: *Context, loc: Location, condition: *IrValue, true_value: *IrValue, false_value: *IrValue) !@This() {
                var builder = OperationBuilder.init(ctx);
                var state = Operation.State.init(operation_name, loc);
                state.addOperands(&.{ condition, true_value, false_value });
                state.addTypes(&.{true_value.type});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *IrValue {
                return self.op.getResult(0).?;
            }

            pub fn getCondition(self: @This()) *IrValue {
                return self.op.getOperand(0).?;
            }

            pub fn getTrueValue(self: @This()) *IrValue {
                return self.op.getOperand(1).?;
            }

            pub fn getFalseValue(self: @This()) *IrValue {
                return self.op.getOperand(2).?;
            }
        };
    }

    fn optionsWithAttr(comptime options: opSpec.Options, comptime attr_name: []const u8) opSpec.Options {
        return .{
            .traits = options.traits,
            .attrs = attrsWithName(options.attrs, attr_name),
            .required_attrs = attrsWithName(options.required_attrs, attr_name),
            .attribute_specs = attributeSpecsWithNames(options.attribute_specs, attrsWithName(options.attrs, attr_name)),
            .operand_segments = options.operand_segments,
            .result_segments = options.result_segments,
            .operand_types = options.operand_types,
            .result_types = options.result_types,
            .properties = options.properties,
            .interfaces = options.interfaces,
            .dynamic_traits = options.dynamic_traits,
        };
    }

    fn attrsWithName(comptime attrs: []const []const u8, comptime attr_name: []const u8) []const []const u8 {
        if (attr_name.len == 0) @compileError("operation attribute name cannot be empty");
        for (attrs) |existing| {
            if (std.mem.eql(u8, existing, attr_name)) @compileError("operation attribute name is duplicated");
        }
        const values = comptime blk: {
            var out: [attrs.len + 1][]const u8 = undefined;
            for (attrs, 0..) |attr, index| {
                out[index] = attr;
            }
            out[attrs.len] = attr_name;
            break :blk out;
        };
        return &values;
    }
};

pub fn operationNames(comptime DialectType: type) type {
    return struct {
        pub fn name(comptime mnemonic: []const u8) []const u8 {
            return operationName(DialectType.name, mnemonic);
        }

        pub fn state(comptime OpType: type, loc: Location) Operation.State {
            return Operation.State.init(operationNameFor(OpType), loc);
        }
    };
}

pub fn operationNameFor(comptime OpType: type) []const u8 {
    if (@hasDecl(OpType, "operation_name")) return OpType.operation_name;
    if (@hasDecl(OpType, "operation_spec")) return OpType.operation_spec.name;
    if (nestedOperationSpec(OpType)) |spec| return spec.name;
    @compileError("operation type must declare operation_name, operation_spec, or a nested operation template");
}

pub fn trait(comptime Trait: type) OperationTraitSpec {
    return .{
        .id = Trait.id,
        .entry = Trait.entry(),
        .traits = if (@hasDecl(Trait, "traits")) Trait.traits else .{},
    };
}

pub fn operation(comptime OpType: type) OperationSpec {
    return operationSpecWithName(operationNameFor(OpType), OpType);
}

fn operationSpecWithName(comptime name: []const u8, comptime OpType: type) OperationSpec {
    if (comptime @hasDecl(OpType, "operation_spec")) {
        validateOperationSpecSource(OpType);
        const metadata = OpType.operation_spec;
        if (!std.mem.eql(u8, metadata.name, name)) {
            @compileError("operation_spec.name must match operation_name");
        }
        return operationSpecFromMetadata(name, metadata, OpType);
    }

    if (comptime nestedOperationSpec(OpType)) |metadata| {
        validateNestedOperationSpecSource(OpType);
        if (!std.mem.eql(u8, metadata.name, name)) {
            @compileError("nested operation template name must match operation_name");
        }
        return operationSpecFromMetadata(name, metadata, OpType);
    }

    @compileError("operation type must declare operation_spec or a nested operation template");
}

fn operationSpecFromMetadata(comptime name: []const u8, comptime metadata: OperationSpec, comptime OpType: type) OperationSpec {
    return .{
        .name = name,
        .traits = metadata.traits,
        .shape = metadata.shape,
        .operand_names = metadata.operand_names,
        .result_names = metadata.result_names,
        .region_names = metadata.region_names,
        .successor_names = metadata.successor_names,
        .inherent_attribute_names = attributeNamesWithRequired(metadata.inherent_attribute_names, metadata.required_attribute_names),
        .required_attribute_names = metadata.required_attribute_names,
        .attribute_specs = attributeSpecsWithNames(metadata.attribute_specs, attributeNamesWithRequired(metadata.inherent_attribute_names, metadata.required_attribute_names)),
        .operand_segments = metadata.operand_segments,
        .result_segments = metadata.result_segments,
        .operand_type_constraints = metadata.operand_type_constraints,
        .result_type_constraints = metadata.result_type_constraints,
        .properties_model = metadata.properties_model,
        .interfaces = operationInterfaces(OpType, metadata.interfaces),
        .dynamic_traits = metadata.dynamic_traits,
    };
}

fn validateOperationSpecSource(comptime OpType: type) void {
    if (@hasDecl(OpType, "traits")) @compileError("operation_spec operations must not declare traits");
    if (@hasDecl(OpType, "shape")) @compileError("operation_spec operations must not declare shape");
    if (@hasDecl(OpType, "operand_names")) @compileError("operation_spec operations must not declare operand_names");
    if (@hasDecl(OpType, "result_names")) @compileError("operation_spec operations must not declare result_names");
    if (@hasDecl(OpType, "region_names")) @compileError("operation_spec operations must not declare region_names");
    if (@hasDecl(OpType, "successor_names")) @compileError("operation_spec operations must not declare successor_names");
    if (@hasDecl(OpType, "inherent_attribute_names")) @compileError("operation_spec operations must not declare inherent_attribute_names");
    if (@hasDecl(OpType, "required_attribute_names")) @compileError("operation_spec operations must not declare required_attribute_names");
    if (@hasDecl(OpType, "attribute_specs")) @compileError("operation_spec operations must not declare attribute_specs");
    if (@hasDecl(OpType, "operand_segments")) @compileError("operation_spec operations must not declare operand_segments");
    if (@hasDecl(OpType, "result_segments")) @compileError("operation_spec operations must not declare result_segments");
    if (@hasDecl(OpType, "operand_type_constraints")) @compileError("operation_spec operations must not declare operand_type_constraints");
    if (@hasDecl(OpType, "result_type_constraints")) @compileError("operation_spec operations must not declare result_type_constraints");
    if (@hasDecl(OpType, "properties_model")) @compileError("operation_spec operations must not declare properties_model");
    if (@hasDecl(OpType, "operation_interfaces")) @compileError("operation_spec operations must not declare operation_interfaces");
    if (@hasDecl(OpType, "dynamic_traits")) @compileError("operation_spec operations must not declare dynamic_traits");
}

fn validateNestedOperationSpecSource(comptime OpType: type) void {
    if (@hasDecl(OpType, "operation_spec")) @compileError("nested operation template operations must not declare operation_spec");
    if (@hasDecl(OpType, "traits")) @compileError("nested operation template operations must not declare traits");
    if (@hasDecl(OpType, "shape")) @compileError("nested operation template operations must not declare shape");
    if (@hasDecl(OpType, "operand_names")) @compileError("nested operation template operations must not declare operand_names");
    if (@hasDecl(OpType, "result_names")) @compileError("nested operation template operations must not declare result_names");
    if (@hasDecl(OpType, "region_names")) @compileError("nested operation template operations must not declare region_names");
    if (@hasDecl(OpType, "successor_names")) @compileError("nested operation template operations must not declare successor_names");
    if (@hasDecl(OpType, "inherent_attribute_names")) @compileError("nested operation template operations must not declare inherent_attribute_names");
    if (@hasDecl(OpType, "required_attribute_names")) @compileError("nested operation template operations must not declare required_attribute_names");
    if (@hasDecl(OpType, "attribute_specs")) @compileError("nested operation template operations must not declare attribute_specs");
    if (@hasDecl(OpType, "operand_segments")) @compileError("nested operation template operations must not declare operand_segments");
    if (@hasDecl(OpType, "result_segments")) @compileError("nested operation template operations must not declare result_segments");
    if (@hasDecl(OpType, "operand_type_constraints")) @compileError("nested operation template operations must not declare operand_type_constraints");
    if (@hasDecl(OpType, "result_type_constraints")) @compileError("nested operation template operations must not declare result_type_constraints");
    if (@hasDecl(OpType, "properties_model")) @compileError("nested operation template operations must not declare properties_model");
    if (@hasDecl(OpType, "operation_interfaces")) @compileError("nested operation template operations must not declare operation_interfaces");
    if (@hasDecl(OpType, "dynamic_traits")) @compileError("nested operation template operations must not declare dynamic_traits");
}

fn operation_spec_storage(comptime DialectType: type, comptime count: usize) type {
    const decls = comptime std.meta.declarations(DialectType);
    return struct {
        const values = blk: {
            var out: [count]OperationSpec = undefined;
            var index: usize = 0;
            for (decls) |decl_name| {
                if (std.mem.eql(u8, decl_name, "spec")) continue;
                const decl_value = @field(DialectType, decl_name);
                if (isDialectOperationValue(decl_value)) {
                    out[index] = operation(decl_value);
                    index += 1;
                }
            }
            break :blk out;
        };
    };
}

pub fn operations(comptime DialectType: type) []const OperationSpec {
    const decls = comptime std.meta.declarations(DialectType);
    comptime var count: usize = 0;
    inline for (decls) |decl_name| {
        if (comptime std.mem.eql(u8, decl_name, "spec")) continue;
        const decl_value = @field(DialectType, decl_name);
        if (comptime isDialectOperationValue(decl_value)) count += 1;
    }
    return &operation_spec_storage(DialectType, count).values;
}

pub fn typeName(name: []const u8) TypeSpec {
    return .{ .name = name };
}

pub fn typeNames(comptime Names: type) []const TypeSpec {
    const decls = comptime std.meta.declarations(Names);
    comptime var count: usize = 0;
    inline for (decls) |decl_name| {
        const decl_value = @field(Names, decl_name);
        if (comptime typeSpecFromValue(decl_value) != null) count += 1;
    }

    const values = comptime blk: {
        var out: [count]TypeSpec = undefined;
        var index: usize = 0;
        for (decls) |decl_name| {
            const decl_value = @field(Names, decl_name);
            if (typeSpecFromValue(decl_value)) |spec| {
                out[index] = spec;
                index += 1;
            }
        }
        break :blk out;
    };
    return &values;
}

pub fn loadDialectSpec(ctx: *Context, spec: DialectSpec) !void {
    if (dialectSpecLoaded(ctx, spec)) return;
    try ensureDialectSpecLoaded(ctx, spec);
    try ctx.prepareDialectLoadRecordStorage(spec.name, spec.operations.len, spec.types.len);
    try registerDialectAttributes(ctx, spec.dialect_attributes);
    try ctx.registerOperationBatch(spec.operations);

    for (spec.operations) |op| try registerOperationDetails(ctx, op);

    try ctx.registerTypeBatch(spec.types);
    for (spec.types) |typ| {
        for (typ.interfaces) |entry| {
            ctx.registerTypeInterface(typ.name, entry) catch |err| switch (err) {
                error.DuplicateInterface => {},
                else => return err,
            };
        }
    }

    for (spec.interfaces) |entry| {
        ctx.registerDialectInterface(spec.name, entry) catch |err| switch (err) {
            error.DuplicateInterface => {},
            else => return err,
        };
    }

    for (spec.op_interface_fallbacks) |entry| {
        ctx.registerDialectOpInterfaceFallback(spec.name, entry.id, entry.fallback) catch |err| switch (err) {
            error.DuplicateInterface => {},
            else => return err,
        };
    }

    for (spec.type_interface_fallbacks) |entry| {
        ctx.registerDialectTypeInterfaceFallback(spec.name, entry.id, entry.fallback) catch |err| switch (err) {
            error.DuplicateInterface => {},
            else => return err,
        };
    }
}

fn registerOperationDetails(ctx: *Context, op: OperationSpec) !void {
    if (op.shape.hasConstraints()) {
        try ctx.registerOperationShape(op.name, op.shape);
    }
    if (op.operand_segments) |segment_spec| {
        try ctx.registerOperationOperandSegments(op.name, segment_spec);
    }
    if (op.result_segments) |segment_spec| {
        try ctx.registerOperationResultSegments(op.name, segment_spec);
    }
    for (op.operand_type_constraints) |constraint| {
        ctx.registerOperationOperandTypeConstraint(op.name, constraint) catch |err| switch (err) {
            error.DuplicateOperandTypeConstraint => {},
            else => return err,
        };
    }
    for (op.result_type_constraints) |constraint| {
        ctx.registerOperationResultTypeConstraint(op.name, constraint) catch |err| switch (err) {
            error.DuplicateResultTypeConstraint => {},
            else => return err,
        };
    }
    for (op.inherent_attribute_names) |attr_name| {
        ctx.registerOperationInherentAttributeName(op.name, attr_name) catch |err| switch (err) {
            error.DuplicateInherentAttributeName => {},
            else => return err,
        };
    }
    for (op.required_attribute_names) |attr_name| {
        ctx.registerOperationRequiredAttributeName(op.name, attr_name) catch |err| switch (err) {
            error.DuplicateRequiredAttributeName => {},
            error.DuplicateInherentAttributeName => {},
            else => return err,
        };
    }
    if (op.properties_model) |model| {
        ctx.registerOperationPropertiesModel(op.name, model) catch |err| switch (err) {
            error.DuplicateOperationProperties => {},
            else => return err,
        };
    }
    for (op.interfaces) |entry| {
        ctx.registerOperationInterface(op.name, entry) catch |err| switch (err) {
            error.DuplicateInterface => {},
            else => return err,
        };
    }
    for (op.dynamic_traits) |trait_spec| {
        _ = try ctx.registerOperation(op.name, trait_spec.traits);
        if (trait_spec.entry) |entry| {
            ctx.registerTraitDefinition(entry) catch |err| switch (err) {
                error.DuplicateTrait => {},
                else => return err,
            };
        }
        ctx.registerOperationTraitId(op.name, trait_spec.id) catch |err| switch (err) {
            error.DuplicateTrait => {},
            else => return err,
        };
    }
}

fn registerDialectAttributes(ctx: *Context, names: []const []const u8) !void {
    const equality = interfaces.AttributeEqualInterface.entry(&core.attribute.dialect_attr_eql_vtable);
    for (names) |name| {
        _ = try ctx.registerAttributeType(name, &.{equality});
    }
}

fn ensureDialectSpecLoaded(ctx: *Context, spec: DialectSpec) !void {
    if (ctx.dialect_registry.loaded.get(spec.name) != null) return;
    if (ctx.dialect_registry.load_state.get(spec.name)) |state| switch (state) {
        .loading => return,
        .loaded => {},
    };

    const table_allocator = core.context.configurationTableAllocator(ctx);
    const name_allocator = core.context.configurationNameAllocator(ctx);
    const interned = try ctx.dialect_registry.internDialectName(
        table_allocator,
        name_allocator,
        spec.name,
    );
    const state = try ctx.dialect_registry.load_state.getOrPut(table_allocator, interned);
    state.key_ptr.* = interned;
    const created_state = !state.found_existing;
    if (created_state) state.value_ptr.* = .loading;
    errdefer {
        if (created_state) _ = ctx.dialect_registry.load_state.remove(interned);
    }

    const dialect = try table_allocator.create(Dialect);
    errdefer table_allocator.destroy(dialect);
    dialect.* = Dialect.init(interned, ctx);

    const loaded = try ctx.dialect_registry.loaded.getOrPut(interned);
    loaded.key_ptr.* = interned;
    if (loaded.found_existing) {
        table_allocator.destroy(dialect);
    } else {
        loaded.value_ptr.* = dialect;
    }

    state.value_ptr.* = .loaded;
}

fn dialectSpecLoaded(ctx: *Context, spec: DialectSpec) bool {
    for (spec.dialect_attributes) |name| {
        if (ctx.lookupAttributeType(name) == null) return false;
    }
    if (spec.operations.len != 0) return ctx.lookupOperation(spec.operations[0].name) != null;
    if (spec.types.len != 0) return ctx.lookupType(spec.types[0].name) != null;
    if (ctx.dialect_registry.load_state.get(spec.name)) |state| return state == .loaded;
    return ctx.dialect_registry.loaded.get(spec.name) != null;
}

test "loadDialectSpec registers dialect attributes before context activation" {
    const testing = std.testing;
    const DialectType = struct {
        pub const name = "sealed_attrs";
        pub const spec = dialectSpec(@This(), .{
            .dialect_attributes = &.{"sealed_attrs.mode"},
        });
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var ctx = try Context.init(failing.allocator(), Context.Limits.testing);
    defer ctx.deinit(failing.allocator());
    try loadDialectSpec(&ctx, DialectType.spec);
    ctx.activate();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const before = ctx.capacityUsage();
    try loadDialectSpec(&ctx, DialectType.spec);
    const first = try ctx.getDialectAttr("sealed_attrs.mode", "first");
    const second = try ctx.getDialectAttr("sealed_attrs.mode", "second");
    try testing.expect(!first.eql(second));
    try testing.expect(first.eql(try ctx.getDialectAttr("sealed_attrs.mode", "first")));
    try testing.expect(ctx.isFrozen());
    try testing.expectEqualDeep(before.configuration_tables, ctx.capacityUsage().configuration_tables);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectError(error.ContextFrozen, ctx.getDialectAttr("sealed_attrs.undeclared", ""));
}

test "loadDialectSpec is read-only after representative operation registration" {
    const testing = std.testing;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const ops = [_]OperationSpec{.{
        .name = "loaded_spec.op",
        .traits = .{ .is_idempotent = true },
    }};
    const spec = DialectSpec{
        .name = "loaded_spec",
        .operations = &ops,
    };

    try loadDialectSpec(&ctx, spec);
    ctx.freeze();
    try loadDialectSpec(&ctx, spec);

    const info = ctx.lookupOperation("loaded_spec.op") orelse return error.OperationMissing;
    try testing.expect(info.traits.is_idempotent);
}

test "loadDialectSpec marks direct spec loads as loaded dialects" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const ops = [_]OperationSpec{.{
        .name = "direct_loaded.op",
        .traits = .{},
    }};

    try loadDialectSpec(&ctx, .{
        .name = "direct_loaded",
        .operations = &ops,
    });
    try loadDialectSpec(&ctx, .{ .name = "direct_empty" });

    try testing.expect(ctx.isDialectLoaded("direct_loaded"));
    try testing.expect(ctx.isDialectLoaded("direct_empty"));

    const state = Operation.State.init("direct_loaded.op", .unknown);
    const op = try ctx.createOperation(state);
    try testing.expectEqualStrings("direct_loaded.op", op.name.name);

    _ = try ctx.getOrLoadDialect("direct_empty");
}

test "direct dialect spec loading cleans every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var ctx = try Context.init(allocator, Context.Limits.testing);
            defer ctx.deinit(allocator);
            try loadDialectSpec(&ctx, .{ .name = "allocation_direct" });
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "direct dialect type batch cleans every allocation failure" {
    const Harness = struct {
        const type_specs = [_]TypeSpec{
            .{ .name = "allocation_types.first" },
            .{ .name = "allocation_types.second" },
        };

        fn run(allocator: std.mem.Allocator) !void {
            var ctx = try Context.init(allocator, Context.Limits.testing);
            defer ctx.deinit(allocator);
            try loadDialectSpec(&ctx, .{
                .name = "allocation_types",
                .types = &type_specs,
            });
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "direct dialect operation batch cleans every allocation failure" {
    const Harness = struct {
        const operation_specs = [_]OperationSpec{
            .{
                .name = "allocation_operations.first",
                .traits = .{ .is_idempotent = true },
                .inherent_attribute_names = &.{ "alpha", "required" },
                .required_attribute_names = &.{"required"},
            },
            .{
                .name = "allocation_operations.second",
                .traits = .{ .is_commutative = true },
            },
        };

        fn run(allocator: std.mem.Allocator) !void {
            var ctx = try Context.init(allocator, Context.Limits.testing);
            defer ctx.deinit(allocator);
            try loadDialectSpec(&ctx, .{
                .name = "allocation_operations",
                .operations = &operation_specs,
            });
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "dialect operation batch merges duplicate traits into one stable entry" {
    const testing = std.testing;
    const operation_specs = [_]OperationSpec{
        .{
            .name = "duplicate_operations.same",
            .traits = .{ .is_idempotent = true },
        },
        .{
            .name = "duplicate_operations.same",
            .traits = .{ .is_commutative = true },
        },
    };

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try loadDialectSpec(&ctx, .{
        .name = "duplicate_operations",
        .operations = &operation_specs,
    });

    const info = ctx.lookupOperation(operation_specs[0].name) orelse return error.OperationMissing;
    try testing.expect(info.traits.is_idempotent);
    try testing.expect(info.traits.is_commutative);
    try testing.expectEqual(@as(usize, 1), ctx.getOperationRegistry().count());
}

fn operationInterfaces(comptime OpType: type, comptime metadata_interfaces: []const interfaces.InterfaceEntry) []const interfaces.InterfaceEntry {
    const explicit_interfaces = comptime if (@hasDecl(OpType, "operation_interfaces")) OpType.operation_interfaces else metadata_interfaces;
    const has_verify = comptime @hasDecl(OpType, "verify");
    const has_verify_regions = comptime @hasDecl(OpType, "verifyRegions");
    const has_verify_symbol_uses = comptime @hasDecl(OpType, "verifySymbolUses");
    const has_cse = comptime @hasDecl(OpType, "cseIncludeAttr");
    const has_fold = comptime @hasDecl(OpType, "fold");
    const include_verify = has_verify and !interfaceListHasId(explicit_interfaces, VerifyOpInterface.id);
    const include_verify_regions = has_verify_regions and !interfaceListHasId(explicit_interfaces, VerifyRegionOpInterface.id);
    const include_verify_symbol_uses = has_verify_symbol_uses and !interfaceListHasId(explicit_interfaces, interfaces.SymbolUserOpInterface.id);
    const include_cse = has_cse and !interfaceListHasId(explicit_interfaces, interfaces.CseOpInterface.id);
    const include_fold = has_fold and !interfaceListHasId(explicit_interfaces, interfaces.FoldOpInterface.id);

    comptime var count: usize = explicit_interfaces.len;
    if (include_verify) count += 1;
    if (include_verify_regions) count += 1;
    if (include_verify_symbol_uses) count += 1;
    if (include_cse) count += 1;
    if (include_fold) count += 1;

    const values = comptime blk: {
        var out: [count]interfaces.InterfaceEntry = undefined;
        var index: usize = 0;
        for (explicit_interfaces) |entry| {
            out[index] = entry;
            index += 1;
        }
        if (include_verify) {
            out[index] = VerifyOpInterface.entryFor(OpType.verify);
            index += 1;
        }
        if (include_verify_regions) {
            out[index] = VerifyRegionOpInterface.entryFor(OpType.verifyRegions);
            index += 1;
        }
        if (include_verify_symbol_uses) {
            out[index] = interfaces.SymbolUserOpInterface.entryFor(OpType.verifySymbolUses);
            index += 1;
        }
        if (include_cse) {
            out[index] = cseEntry(OpType);
            index += 1;
        }
        if (include_fold) {
            out[index] = interfaces.FoldOpInterface.entryFor(OpType.fold);
            index += 1;
        }
        break :blk out;
    };
    return &values;
}

fn interfaceListHasId(comptime entries: []const interfaces.InterfaceEntry, comptime id: interfaces.InterfaceId) bool {
    for (entries) |entry| {
        if (entry.id == id) return true;
    }
    return false;
}

fn cseEntry(comptime OpType: type) interfaces.InterfaceEntry {
    if (comptime @hasDecl(OpType, "cseCommuteOperands")) {
        return interfaces.CseOpInterface.keyPolicyEntryFor(
            OpType.cseIncludeAttr,
            OpType.cseCommuteOperands,
        );
    }
    return interfaces.CseOpInterface.entryFor(OpType.cseIncludeAttr);
}

fn isDialectOperationValue(comptime value: anytype) bool {
    if (@typeInfo(@TypeOf(value)) != .type) return false;
    switch (@typeInfo(value)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(value, "operation_name") or
        @hasDecl(value, "operation_spec") or
        nestedOperationSpec(value) != null;
}

fn nestedOperationSpec(comptime OpType: type) ?OperationSpec {
    inline for (.{ "def", "leaf", "term", "template" }) |decl_name| {
        if (comptime @hasDecl(OpType, decl_name)) {
            if (nestedOperationSpecFromValue(@field(OpType, decl_name))) |spec| return spec;
        }
    }
    return null;
}

fn nestedOperationSpecFromValue(comptime value: anytype) ?OperationSpec {
    if (@typeInfo(@TypeOf(value)) != .type) return null;
    switch (@typeInfo(value)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return null,
    }
    if (!@hasDecl(value, "operation_spec")) return null;
    return value.operation_spec;
}

fn isStringValue(comptime value: anytype) bool {
    return asString(value).len != 0;
}

fn typeSpecFromValue(comptime value: anytype) ?TypeSpec {
    if (@TypeOf(value) == TypeSpec) return value;
    const name = asString(value);
    if (name.len == 0) return null;
    return typeName(name);
}

fn asString(comptime value: anytype) []const u8 {
    const value_type = @TypeOf(value);
    return switch (@typeInfo(value_type)) {
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8) value else "",
            .one => switch (@typeInfo(ptr_info.child)) {
                .array => |arr_info| if (arr_info.child == u8) value[0..] else "",
                else => "",
            },
            else => "",
        },
        else => "",
    };
}

test "operationName composes dialect and mnemonic" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "example";
        const operation_names = operationNames(@This());
        pub const ExampleOp = struct {
            pub const operation_name = operation_names.name("thing");
        };
    };

    try testing.expectEqualStrings("example.thing", ExampleDialect.ExampleOp.operation_name);
}

test "shape DSL maps integers and count ranges into operation shapes" {
    const testing = std.testing;

    const op_shape = shape.of(.{
        .operands = 2,
        .results = shape.atLeast(1),
        .regions = shape.atMost(1),
        .successors = shape.between(0, 2),
    });

    try testing.expect(op_shape.operands.allows(2));
    try testing.expect(!op_shape.operands.allows(1));
    try testing.expect(op_shape.results.allows(3));
    try testing.expect(!op_shape.results.allows(0));
    try testing.expect(op_shape.regions.allows(0));
    try testing.expect(op_shape.regions.allows(1));
    try testing.expect(!op_shape.regions.allows(2));
    try testing.expect(op_shape.successors.allows(2));
    try testing.expect(!op_shape.successors.allows(3));
}

test "shape DSL leaf constrains nested IR to zero" {
    const testing = std.testing;

    const leaf_shape = shape.leaf(shape.atMost(1), 1);

    try testing.expect(leaf_shape.operands.allows(0));
    try testing.expect(leaf_shape.operands.allows(1));
    try testing.expect(!leaf_shape.operands.allows(2));
    try testing.expect(leaf_shape.results.allows(1));
    try testing.expect(!leaf_shape.results.allows(0));
    try testing.expect(leaf_shape.regions.allows(0));
    try testing.expect(!leaf_shape.regions.allows(1));
    try testing.expect(leaf_shape.successors.allows(0));
    try testing.expect(!leaf_shape.successors.allows(1));
}

test "operations derives operation specs from descriptors" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "derived";
        const op_specs = opSpec.dialect(@This());
        pub const ExampleOp = struct {
            pub const operation_spec = op_specs.define(.{
                .mnemonic = "thing",
                .traits = interfaces.OperationTraits{ .is_idempotent = true },
            });
        };
        pub const spec = dialectSpec(@This(), .{});
    };

    try testing.expectEqual(@as(usize, 1), ExampleDialect.spec.operations.len);
    try testing.expectEqualStrings("derived.thing", ExampleDialect.spec.operations[0].name);
    try testing.expect(ExampleDialect.spec.operations[0].traits.is_idempotent);
}

test "operation descriptor DSL exports compact operation metadata" {
    const testing = std.testing;

    const MarkerInterface = struct {
        pub const id = interfaces.interfaceId("opdsl.marker");
        pub const VTable = struct { marker: u8 };
        const table = VTable{ .marker = 3 };
    };

    const ExampleProperties = struct {
        value: u8 = 0,

        fn init(storage: *anyopaque, _: std.mem.Allocator) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(storage));
            self.* = .{};
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        fn copyProperties(dest: *anyopaque, source: *const anyopaque) anyerror!void {
            const dest_self: *@This() = @ptrCast(@alignCast(dest));
            const source_self: *const @This() = @ptrCast(@alignCast(source));
            dest_self.* = source_self.*;
        }

        const model = interfaces.OperationPropertiesModel{
            .name = "opdsl.example.properties",
            .size = @sizeOf(@This()),
            .alignment = std.mem.Alignment.fromByteUnits(@alignOf(@This())),
            .init = init,
            .deinit = deinit,
            .copyProperties = copyProperties,
        };
    };

    const Trait = struct {
        pub const trait_name = "opdsl.trait";
        pub const id = interfaces.traitId(trait_name);
        fn verify(_: *const anyopaque) anyerror!void {}
        pub const vtable = interfaces.TraitVTable{ .verify = verify };
        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };

    const DialectForTest = struct {
        pub const name = "opdsl";
        const operation_names = operationNames(@This());
        const op_specs = opSpec.dialect(operation_names);
        pub const ExampleOp = struct {
            pub const operation_spec = op_specs.define(.{
                .mnemonic = "example",
                .operands = .{ "lhs", "rhs" },
                .results = .{"out"},
                .regions = 0,
                .successors = 0,
                .operand_segments = segments.operands(.{ 1, shape.atMost(1) }),
                .result_segments = segments.results(.{1}),
                .traits = interfaces.OperationTraits{ .is_idempotent = true },
                .attrs = &.{ "value", "predicate" },
                .required_attrs = &.{"value"},
                .properties = ExampleProperties.model,
                .interfaces = &.{
                    .{ .id = MarkerInterface.id, .vtable = &MarkerInterface.table },
                },
                .dynamic_traits = .{Trait},
            });
            pub const operation_name = operation_spec.name;
        };
        pub const spec = dialectSpec(@This(), .{});
    };

    const spec = DialectForTest.ExampleOp.operation_spec;
    const registered_spec = DialectForTest.spec.operations[0];
    try testing.expectEqualStrings("opdsl.example", DialectForTest.ExampleOp.operation_name);
    try testing.expectEqualStrings("opdsl.example", spec.name);
    try testing.expectEqualStrings("opdsl.example", registered_spec.name);
    try testing.expect(spec.shape.operands.allows(2));
    try testing.expect(!spec.shape.operands.allows(1));
    try testing.expect(spec.shape.results.allows(1));
    try testing.expectEqual(@as(usize, 0), operandIndex(spec, "lhs"));
    try testing.expectEqual(@as(usize, 1), operandIndex(spec, "rhs"));
    try testing.expectEqual(@as(usize, 0), resultIndex(spec, "out"));
    try testing.expectEqualStrings("lhs", spec.operand_names[0]);
    try testing.expectEqualStrings("out", spec.result_names[0]);
    try testing.expectEqualStrings("lhs", registered_spec.operand_names[0]);
    try testing.expectEqualStrings("operand_segment_sizes", spec.operand_segments.?.attribute_name);
    try testing.expectEqual(@as(usize, 2), spec.operand_segments.?.segments.len);
    try testing.expect(spec.operand_segments.?.segments[1].allows(1));
    try testing.expect(!spec.operand_segments.?.segments[1].allows(2));
    try testing.expectEqualStrings("result_segment_sizes", registered_spec.result_segments.?.attribute_name);
    try testing.expectEqual(@as(usize, 1), registered_spec.result_segments.?.segments.len);
    try testing.expect(spec.traits.is_idempotent);
    try testing.expectEqual(@as(usize, 2), spec.inherent_attribute_names.len);
    try testing.expectEqualStrings("predicate", spec.inherent_attribute_names[1]);
    try testing.expectEqual(@as(usize, 1), spec.required_attribute_names.len);
    try testing.expectEqualStrings("value", spec.required_attribute_names[0]);
    try testing.expect(spec.properties_model != null);
    try testing.expectEqual(@as(usize, 1), spec.interfaces.len);
    try testing.expectEqual(MarkerInterface.id, spec.interfaces[0].id);
    try testing.expectEqual(@as(usize, 1), spec.dynamic_traits.len);
    try testing.expectEqual(Trait.id, spec.dynamic_traits[0].id);
}

test "operation segment helpers set attributes and read named segments" {
    const testing = std.testing;

    const DialectForTest = struct {
        pub const name = "segment_helpers";
        const op_specs = opSpec.dialect(@This());
        pub const ExampleOp = struct {
            pub const operation_spec = op_specs.leaf(.{
                .mnemonic = "example",
                .operands = shape.between(1, 2),
                .operand_names = .{ "required", "optional" },
                .results = shape.between(1, 2),
                .result_names = .{ "primary", "extra" },
                .operand_segments = segments.operands(.{ 1, shape.atMost(1) }),
                .result_segments = segments.results(.{ 1, shape.atMost(1) }),
            });
            pub const operation_name = operation_spec.name;
        };
        pub const spec = dialectSpec(@This(), .{});
    };

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, DialectForTest.spec);

    const value_type = try ctx.getDialectTypeFromName("segment_helpers.ty");
    var producer_state = Operation.State.init("segment_helpers.producer", .unknown);
    producer_state.addTypes(&.{ value_type, value_type });
    const producer = try ctx.createOperation(producer_state);
    const required = producer.getResult(0).?;
    const optional = producer.getResult(1).?;

    var full_state = Operation.State.init(DialectForTest.ExampleOp.operation_name, .unknown);
    full_state.addOperands(&.{ required, optional });
    full_state.addTypes(&.{ value_type, value_type });
    const full = try ctx.createOperation(full_state);
    try setOperandSegmentSizes(DialectForTest.ExampleOp.operation_spec, full, &[_]usize{ 1, 1 });
    try setResultSegmentSizes(DialectForTest.ExampleOp.operation_spec, full, &[_]usize{ 1, 1 });

    try testing.expectEqual(required, operandSegmentValue(DialectForTest.ExampleOp.operation_spec, full, "required").?);
    try testing.expectEqual(optional, operandSegmentValue(DialectForTest.ExampleOp.operation_spec, full, "optional").?);
    try testing.expectEqual(full.getResult(0).?, resultSegmentValue(DialectForTest.ExampleOp.operation_spec, full, "primary").?);
    try testing.expectEqual(full.getResult(1).?, resultSegmentValue(DialectForTest.ExampleOp.operation_spec, full, "extra").?);

    var partial_state = Operation.State.init(DialectForTest.ExampleOp.operation_name, .unknown);
    partial_state.addOperands(&.{required});
    partial_state.addTypes(&.{value_type});
    const partial = try ctx.createOperation(partial_state);
    try setOperandSegmentSizes(DialectForTest.ExampleOp.operation_spec, partial, &[_]usize{ 1, 0 });
    try setResultSegmentSizes(DialectForTest.ExampleOp.operation_spec, partial, &[_]usize{ 1, 0 });

    const optional_operands = operandSegmentValues(DialectForTest.ExampleOp.operation_spec, partial, "optional") orelse return error.TestExpectedOperandSegment;
    const extra_results = resultSegmentValues(DialectForTest.ExampleOp.operation_spec, partial, "extra") orelse return error.TestExpectedResultSegment;
    try testing.expectEqual(@as(usize, 0), optional_operands.len);
    try testing.expectEqual(@as(usize, 0), extra_results.len);
    try testing.expect(operandSegmentValue(DialectForTest.ExampleOp.operation_spec, partial, "optional") == null);
    try testing.expect(resultSegmentValue(DialectForTest.ExampleOp.operation_spec, partial, "extra") == null);
}

test "operation descriptor required attrs are inherent attrs" {
    const testing = std.testing;

    const DialectForTest = struct {
        pub const name = "required";
        const op_specs = opSpec.dialect(@This());
        pub const ExampleOp = struct {
            pub const operation_spec = op_specs.leaf(.{
                .mnemonic = "example",
                .required_attrs = &.{"value"},
            });
            pub const operation_name = operation_spec.name;
        };
        pub const spec = dialectSpec(@This(), .{});
    };

    const spec = DialectForTest.ExampleOp.operation_spec;
    try testing.expectEqual(@as(usize, 1), spec.inherent_attribute_names.len);
    try testing.expectEqualStrings("value", spec.inherent_attribute_names[0]);
    try testing.expectEqual(@as(usize, 1), spec.required_attribute_names.len);
    try testing.expectEqualStrings("value", spec.required_attribute_names[0]);

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, DialectForTest.spec);
    const info = ctx.lookupOperation(DialectForTest.ExampleOp.operation_name) orelse return error.TestExpectedRequiredAttrOp;
    try testing.expect(info.hasInherentAttributeName("value"));
    try testing.expect(info.hasRequiredAttributeName("value"));
}

test "operation descriptor DSL carries typed attribute specs" {
    const testing = std.testing;

    const spec = comptime opSpec.define(.{
        .name = "attrs.example",
        .attrs = .{attribute.string("label")},
        .required_attrs = .{
            attribute.integer("value"),
            attribute.dialect("payload", "attrs.payload"),
        },
    });

    try testing.expectEqual(@as(usize, 3), spec.inherent_attribute_names.len);
    try testing.expectEqualStrings("label", spec.inherent_attribute_names[0]);
    try testing.expectEqualStrings("value", spec.required_attribute_names[0]);
    try testing.expectEqualStrings("payload", spec.required_attribute_names[1]);
    try testing.expectEqual(@as(usize, 3), spec.attribute_specs.len);
    try testing.expectEqual(.string, std.meta.activeTag(operationAttribute(spec, "label").storage));
    try testing.expectEqual(.i64, std.meta.activeTag(operationAttribute(spec, "value").storage));
    try testing.expectEqualStrings("attrs.payload", operationDialectAttributeName(spec, "payload"));

    const required_upgrade = comptime opSpec.define(.{
        .name = "attrs.required_upgrade",
        .attrs = .{"payload"},
        .required_attrs = .{attribute.dialect("payload", "attrs.payload")},
    });
    try testing.expectEqual(@as(usize, 1), required_upgrade.attribute_specs.len);
    try testing.expectEqualStrings("attrs.payload", operationDialectAttributeName(required_upgrade, "payload"));
}

test "operation descriptor DSL accepts trait types in dynamic trait lists" {
    const testing = std.testing;

    const Trait = struct {
        pub const trait_name = "opdsl.direct_trait";
        pub const id = interfaces.traitId(trait_name);
        pub const traits = interfaces.OperationTraits{ .is_symbol_table = true };
        pub const vtable = interfaces.TraitVTable{};
        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };

    const ExplicitTrait = struct {
        pub const trait_name = "opdsl.explicit_trait";
        pub const id = interfaces.traitId(trait_name);
        pub const vtable = interfaces.TraitVTable{};
        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };

    const spec = opSpec.define(.{
        .name = "opdsl.direct_traits",
        .dynamic_traits = .{ Trait, trait(ExplicitTrait) },
    });

    try testing.expectEqual(@as(usize, 2), spec.dynamic_traits.len);
    try testing.expectEqual(Trait.id, spec.dynamic_traits[0].id);
    try testing.expectEqual(ExplicitTrait.id, spec.dynamic_traits[1].id);

    const option_traits = opSpec.dynamicTraits(.{Trait});
    try testing.expectEqual(@as(usize, 1), option_traits.len);
    try testing.expectEqual(Trait.id, option_traits[0].id);
    try testing.expect(option_traits[0].traits.is_symbol_table);
}

test "operation descriptor DSL accepts full operation declaration records" {
    const testing = std.testing;

    const spec = comptime opSpec.define(.{
        .name = "record.example",
        .operands = .{ "condition", "value" },
        .results = .{"result"},
        .regions = .{"body"},
        .successors = .{"exit"},
        .traits = interfaces.OperationTraits{ .is_idempotent = true },
        .attrs = &.{"value"},
    });

    try testing.expectEqualStrings("record.example", spec.name);
    try testing.expect(spec.shape.operands.allows(2));
    try testing.expect(!spec.shape.operands.allows(1));
    try testing.expect(!spec.shape.operands.allows(3));
    try testing.expect(spec.shape.results.allows(1));
    try testing.expect(spec.shape.regions.allows(1));
    try testing.expect(!spec.shape.regions.allows(0));
    try testing.expect(spec.shape.successors.allows(1));
    try testing.expect(!spec.shape.successors.allows(0));
    try testing.expectEqual(@as(usize, 0), operandIndex(spec, "condition"));
    try testing.expectEqual(@as(usize, 1), operandIndex(spec, "value"));
    try testing.expectEqual(@as(usize, 0), resultIndex(spec, "result"));
    try testing.expectEqual(@as(usize, 0), regionIndex(spec, "body"));
    try testing.expectEqual(@as(usize, 0), successorIndex(spec, "exit"));
    try testing.expect(spec.traits.is_idempotent);
    try testing.expectEqual(@as(usize, 1), spec.inherent_attribute_names.len);
    try testing.expectEqualStrings("value", spec.inherent_attribute_names[0]);
}

test "operation descriptor DSL derives terminator declarations" {
    const testing = std.testing;

    const spec = opSpec.terminator(.{
        .name = "record.return",
        .operands = shape.atLeast(1),
    });

    try testing.expectEqualStrings("record.return", spec.name);
    try testing.expect(spec.shape.operands.allows(1));
    try testing.expect(spec.shape.operands.allows(3));
    try testing.expect(!spec.shape.operands.allows(0));
    try testing.expect(spec.shape.results.allows(0));
    try testing.expect(!spec.shape.results.allows(1));
    try testing.expect(spec.shape.regions.allows(0));
    try testing.expect(!spec.shape.regions.allows(1));
    try testing.expect(spec.shape.successors.allows(0));
    try testing.expect(!spec.shape.successors.allows(1));
    try testing.expect(spec.traits.is_terminator);
    try testing.expectEqual(@as(usize, 1), spec.dynamic_traits.len);
    try testing.expectEqual(core_traits.Terminator.id, spec.dynamic_traits[0].id);
}

test "operation descriptor DSL builds dialect operation sets" {
    const testing = std.testing;

    const DialectForTest = struct {
        pub const name = "opset";
        const op_specs = opSpec.dialect(@This());

        pub const LeafOp = struct {
            pub const operation_spec = op_specs.leaf(.{
                .mnemonic = "leaf",
                .operands = shape.atMost(2),
                .results = 1,
                .attrs = &.{"value"},
            });
            pub const operation_name = operation_spec.name;
        };

        pub const spec = dialectSpec(@This(), .{});
    };

    try testing.expectEqualStrings("opset.leaf", DialectForTest.op_specs.name("leaf"));
    try testing.expectEqualStrings("opset.leaf", DialectForTest.LeafOp.operation_name);
    const state = DialectForTest.op_specs.state(DialectForTest.LeafOp, Location.getUnknown());
    try testing.expectEqualStrings("opset.leaf", state.name.name);
    const spec = DialectForTest.spec.operations[0];
    try testing.expect(spec.shape.operands.allows(2));
    try testing.expect(!spec.shape.operands.allows(3));
    try testing.expect(spec.shape.results.allows(1));
    try testing.expect(spec.shape.regions.allows(0));
    try testing.expect(!spec.shape.regions.allows(1));
    try testing.expect(spec.shape.successors.allows(0));
    try testing.expect(!spec.shape.successors.allows(1));

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, DialectForTest.spec);
    const info = ctx.lookupOperation(DialectForTest.LeafOp.operation_name) orelse return error.TestExpectedLeafOp;
    try testing.expect(info.shape.regions.allows(0));
    try testing.expect(!info.shape.regions.allows(1));
    try testing.expect(info.hasInherentAttributeName("value"));
}

fn operationTemplateNoopFold(
    _: *const anyopaque,
    _: *interfaces.FoldResults,
) anyerror!void {}

fn operationTemplateNoopVerify(_: *const anyopaque) anyerror!void {}

fn operationTemplateFixedBoolType(ctx: *Context) anyerror!Type {
    return ctx.getDialectTypeFromName("template_fixed.bool");
}

test "operationTemplate nested definitions register custom wrappers" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_nested";
        const ops = operationTemplate.dialect(@This());

        pub const ScaleOp = struct {
            op: *Operation,

            pub const leaf = ops.explicitLeaf(@This(), .{
                .mnemonic = "scale",
                .operands = .{"input"},
                .results = .{"output"},
                .required_attrs = .{attribute.integer("factor")},
                .traits = interfaces.OperationTraits{ .is_idempotent = true },
                .interfaces = &.{opSpec.verifier(operationTemplateNoopVerify)},
            });
            pub const operation_name = leaf.operation_name;
            pub const verify = operationTemplateNoopVerify;

            pub fn create(ctx: *Context, loc: Location, input: *IrValue, output_type: Type, factor: i64) !@This() {
                const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{output_type});
                try leaf.setI64Attr(self, "factor", factor);
                return self;
            }

            pub fn getInput(self: @This()) *IrValue {
                return leaf.getOperand(self, "input");
            }

            pub fn getResult(self: @This()) *IrValue {
                return leaf.getResult(self);
            }
        };

        pub const spec = dialectSpec(@This(), .{});
    };

    try testing.expect(!@hasDecl(ExampleDialect.ScaleOp, "operation_spec"));
    try testing.expectEqualStrings("template_nested.scale", ExampleDialect.ScaleOp.operation_name);
    try testing.expectEqualStrings("template_nested.scale", operationNameFor(ExampleDialect.ScaleOp));
    const spec = ExampleDialect.spec.operations[0];
    try testing.expectEqualStrings("template_nested.scale", spec.name);
    try testing.expect(spec.traits.is_idempotent);
    try testing.expectEqual(@as(usize, 1), spec.required_attribute_names.len);
    try testing.expectEqualStrings("factor", spec.required_attribute_names[0]);
    try testing.expectEqual(@as(usize, 1), spec.interfaces.len);

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const input_type = try ctx.getDialectTypeFromName("template_nested.i32");
    const output_type = try ctx.getDialectTypeFromName("template_nested.f32");

    var input_state = Operation.State.init("template_nested.seed", loc);
    input_state.addTypes(&.{input_type});
    const input_op = try ctx.createOperation(input_state);
    const input = input_op.getResult(0).?;

    const scale = try ExampleDialect.ScaleOp.create(&ctx, loc, input, output_type, 11);
    try testing.expectEqual(input, scale.getInput());
    try testing.expect(scale.getResult().type.eql(output_type));
    try testing.expectEqual(@as(i64, 11), scale.op.getAttrAs(Attribute.IntegerAttr, "factor").?.value);

    const info = ctx.lookupOperation(ExampleDialect.ScaleOp.operation_name) orelse return error.TestExpectedScaleOp;
    try testing.expect(info.hasInterface(VerifyOpInterface.id));
    try testing.expect(info.hasRequiredAttributeName("factor"));
}

test "operationTemplate explicit leaf mixin derives construction from one spec" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_explicit";
        const ops = operationTemplate.dialect(@This());

        pub const ScaleOp = struct {
            op: *Operation,

            const leaf = ops.explicitLeaf(@This(), .{
                .mnemonic = "scale",
                .operands = .{"input"},
                .results = .{"output"},
                .required_attrs = &.{"factor"},
                .traits = interfaces.OperationTraits{ .is_idempotent = true },
            });
            pub const operation_spec = leaf.operation_spec;
            pub const operation_name = leaf.operation_name;
            pub const createLeaf = leaf.createLeaf;
            pub const getOperand = leaf.getOperand;
            pub const getNamedResult = leaf.getNamedResult;
            pub const getResult = leaf.getResult;

            pub fn create(ctx: *Context, loc: Location, input: *IrValue, output_type: Type, factor: i64) !@This() {
                const self = try @This().createLeaf(ctx, loc, &.{input}, &.{output_type});
                try self.op.setAttr("factor", try ctx.getI64Attr(factor));
                return self;
            }
        };

        pub const spec = dialectSpec(@This(), .{});
    };

    try testing.expectEqualStrings("template_explicit.scale", ExampleDialect.ScaleOp.operation_name);
    try testing.expectEqualStrings("input", ExampleDialect.ScaleOp.operation_spec.operand_names[0]);
    try testing.expectEqualStrings("output", ExampleDialect.ScaleOp.operation_spec.result_names[0]);
    try testing.expect(ExampleDialect.ScaleOp.operation_spec.shape.operands.allows(1));
    try testing.expect(!ExampleDialect.ScaleOp.operation_spec.shape.operands.allows(2));
    try testing.expect(ExampleDialect.ScaleOp.operation_spec.shape.regions.allows(0));
    try testing.expect(!ExampleDialect.ScaleOp.operation_spec.shape.regions.allows(1));

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const input_type = try ctx.getDialectTypeFromName("template_explicit.i32");
    const output_type = try ctx.getDialectTypeFromName("template_explicit.f32");

    var input_state = Operation.State.init("template_explicit.seed", loc);
    input_state.addTypes(&.{input_type});
    const input_op = try ctx.createOperation(input_state);
    const input = input_op.getResult(0).?;

    const scale = try ExampleDialect.ScaleOp.create(&ctx, loc, input, output_type, 7);
    try testing.expectEqual(input, scale.getOperand("input"));
    try testing.expect(scale.getResult().type.eql(output_type));
    try testing.expectEqual(scale.getResult(), scale.getNamedResult("output"));
    try testing.expectEqual(@as(i64, 7), scale.op.getAttrAs(Attribute.IntegerAttr, "factor").?.value);
}

test "operationTemplate explicit leaf mixin derives typed attribute accessors" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_attrs";
        const ops = operationTemplate.dialect(@This());

        pub const PayloadOp = struct {
            op: *Operation,

            const leaf = ops.explicitLeaf(@This(), .{
                .mnemonic = "payload",
                .results = .{"result"},
                .required_attrs = .{
                    attribute.integer("count"),
                    attribute.boolean("enabled"),
                    attribute.string("label"),
                    attribute.dialect("payload", "template_attrs.payload"),
                },
            });
            pub const operation_spec = leaf.operation_spec;
            pub const operation_name = leaf.operation_name;
            pub const createLeaf = leaf.createLeaf;
            pub const getResult = leaf.getResult;
            pub const setI64Attr = leaf.setI64Attr;
            pub const getI64Attr = leaf.getI64Attr;
            pub const setBoolAttr = leaf.setBoolAttr;
            pub const getBoolAttr = leaf.getBoolAttr;
            pub const setStringAttr = leaf.setStringAttr;
            pub const getStringAttr = leaf.getStringAttr;
            pub const setDialectAttrPayload = leaf.setDialectAttrPayload;
            pub const getDialectAttrPayload = leaf.getDialectAttrPayload;
            pub const dialectAttrName = leaf.dialectAttrName;
        };

        pub const spec = dialectSpec(@This(), .{});
    };

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const result_type = try ctx.getDialectTypeFromName("template_attrs.i32");
    var created = try ExampleDialect.PayloadOp.createLeaf(&ctx, loc, &.{}, &.{result_type});
    try created.setI64Attr("count", 42);
    try created.setBoolAttr("enabled", true);
    try created.setStringAttr("label", "sample");
    try created.setDialectAttrPayload("payload", "bytes");

    try testing.expectEqual(@as(i64, 42), created.getI64Attr("count").?);
    try testing.expect(created.getBoolAttr("enabled").?);
    try testing.expectEqualStrings("sample", created.getStringAttr("label").?);
    try testing.expectEqualStrings("bytes", created.getDialectAttrPayload("payload").?);
    try testing.expectEqualStrings("template_attrs.payload", ExampleDialect.PayloadOp.dialectAttrName("payload"));

    const info = ctx.lookupOperation(ExampleDialect.PayloadOp.operation_name) orelse return error.TestExpectedOperation;
    try testing.expect(info.hasInherentAttributeName("payload"));
    try testing.expect(info.hasRequiredAttributeName("payload"));
}

test "operationTemplate explicit leaf mixin derives optional and segment accessors" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_components";
        const ops = operationTemplate.dialect(@This());

        pub const OptionalOp = struct {
            op: *Operation,

            const leaf = ops.explicitLeaf(@This(), .{
                .mnemonic = "optional",
                .operands = shape.atMost(1),
                .operand_names = .{"input"},
                .results = shape.atMost(1),
                .result_names = .{"output"},
            });
            pub const operation_spec = leaf.operation_spec;
            pub const operation_name = leaf.operation_name;
            pub const createLeaf = leaf.createLeaf;
            pub const getOptionalOperand = leaf.getOptionalOperand;
            pub const getOptionalResult = leaf.getOptionalResult;
        };

        pub const SegmentedOp = struct {
            op: *Operation,

            const leaf = ops.explicitLeaf(@This(), .{
                .mnemonic = "segmented",
                .operands = shape.atLeast(1),
                .operand_names = .{ "head", "tail" },
                .results = shape.atLeast(1),
                .result_names = .{ "primary", "extra" },
                .operand_segments = segments.operands(.{ 1, shape.any() }),
                .result_segments = segments.results(.{ 1, shape.any() }),
            });
            pub const operation_spec = leaf.operation_spec;
            pub const operation_name = leaf.operation_name;
            pub const createLeaf = leaf.createLeaf;
            pub const getOperandSegment = leaf.getOperandSegment;
            pub const getOperandSegmentValue = leaf.getOperandSegmentValue;
            pub const getResultSegment = leaf.getResultSegment;
            pub const getResultSegmentValue = leaf.getResultSegmentValue;
        };

        pub const spec = dialectSpec(@This(), .{});
    };

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const i32_type = try ctx.getDialectTypeFromName("template_components.i32");

    var seed_state = Operation.State.init("template_components.seed", loc);
    seed_state.addTypes(&.{i32_type});
    const seed_a_op = try ctx.createOperation(seed_state);
    const seed_b_op = try ctx.createOperation(seed_state);
    const seed_c_op = try ctx.createOperation(seed_state);
    const seed_a = seed_a_op.getResult(0).?;
    const seed_b = seed_b_op.getResult(0).?;
    const seed_c = seed_c_op.getResult(0).?;

    const empty_optional = try ExampleDialect.OptionalOp.createLeaf(&ctx, loc, &.{}, &.{});
    try testing.expect(empty_optional.getOptionalOperand("input") == null);
    try testing.expect(empty_optional.getOptionalResult("output") == null);

    const full_optional = try ExampleDialect.OptionalOp.createLeaf(&ctx, loc, &.{seed_a}, &.{i32_type});
    try testing.expectEqual(seed_a, full_optional.getOptionalOperand("input").?);
    try testing.expect(full_optional.getOptionalResult("output").?.type.eql(i32_type));

    const segmented = try ExampleDialect.SegmentedOp.createLeaf(
        &ctx,
        loc,
        &.{ seed_a, seed_b, seed_c },
        &.{ i32_type, i32_type },
    );
    try setOperandSegmentSizes(ExampleDialect.SegmentedOp.operation_spec, segmented.op, &.{ 1, 2 });
    try setResultSegmentSizes(ExampleDialect.SegmentedOp.operation_spec, segmented.op, &.{ 1, 1 });

    try testing.expectEqual(seed_a, segmented.getOperandSegmentValue("head").?);
    const tail = segmented.getOperandSegment("tail") orelse return error.TestExpectedOperandSegment;
    try testing.expectEqual(@as(usize, 2), tail.len);
    try testing.expectEqual(seed_b, tail[0]);
    try testing.expectEqual(seed_c, tail[1]);

    try testing.expect(segmented.getResultSegmentValue("primary").?.type.eql(i32_type));
    const extra = segmented.getResultSegment("extra") orelse return error.TestExpectedResultSegment;
    try testing.expectEqual(@as(usize, 1), extra.len);
    try testing.expect(extra[0].type.eql(i32_type));
}

test "opSpec names components independently from shape ranges" {
    const testing = std.testing;

    const spec = comptime opSpec.define(.{
        .name = "template_named.branch",
        .operands = shape.atLeast(1),
        .operand_names = .{"condition"},
        .results = shape.atMost(2),
        .result_names = .{"primary"},
        .regions = shape.atLeast(1),
        .region_names = .{"body"},
        .successors = shape.between(1, 2),
        .successor_names = .{"target"},
    });

    try testing.expect(spec.shape.operands.allows(4));
    try testing.expect(spec.shape.results.allows(0));
    try testing.expect(spec.shape.results.allows(2));
    try testing.expect(!spec.shape.results.allows(3));
    try testing.expect(spec.shape.regions.allows(3));
    try testing.expect(spec.shape.successors.allows(1));
    try testing.expectEqualStrings("condition", spec.operand_names[0]);
    try testing.expectEqualStrings("primary", spec.result_names[0]);
    try testing.expectEqualStrings("body", spec.region_names[0]);
    try testing.expectEqualStrings("target", spec.successor_names[0]);
    try testing.expectEqual(@as(usize, 0), operandIndex(spec, "condition"));
    try testing.expectEqual(@as(usize, 0), resultIndex(spec, "primary"));
    try testing.expectEqual(@as(usize, 0), regionIndex(spec, "body"));
    try testing.expectEqual(@as(usize, 0), successorIndex(spec, "target"));
}

test "operationTemplate explicit mixin derives non-leaf construction from one spec" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_explicit_region";
        const ops = operationTemplate.dialect(@This());

        pub const ContainerOp = struct {
            op: *Operation,

            const def = ops.explicit(@This(), .{
                .mnemonic = "container",
                .operands = .{"input"},
                .results = .{"output"},
                .regions = .{"body"},
                .successors = .{"target"},
            });
            pub const operation_spec = def.operation_spec;
            pub const operation_name = def.operation_name;
            pub const createOperation = def.createOperation;
            pub const getOperand = def.getOperand;
            pub const getNamedResult = def.getNamedResult;
            pub const getRegion = def.getRegion;
            pub const getSuccessor = def.getSuccessor;
        };

        pub const spec = dialectSpec(@This(), .{});
    };

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const input_type = try ctx.getDialectTypeFromName("template_explicit_region.i32");
    const output_type = try ctx.getDialectTypeFromName("template_explicit_region.f32");

    var input_state = Operation.State.init("template_explicit_region.seed", loc);
    input_state.addTypes(&.{input_type});
    const input_op = try ctx.createOperation(input_state);
    const input = input_op.getResult(0).?;

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    _ = try body.addBlock();

    var target_region = core.context.initRegion(&ctx);
    defer target_region.deinit();
    const target = try target_region.addBlock();

    const container = try ExampleDialect.ContainerOp.createOperation(
        &ctx,
        loc,
        &.{input},
        &.{output_type},
        &.{&body},
        &.{target},
    );

    try testing.expectEqual(input, container.getOperand("input"));
    try testing.expect(container.getNamedResult("output").type.eql(output_type));
    try testing.expect(container.getRegion("body").getEntryBlock() != null);
    try testing.expectEqual(target, container.getSuccessor("target"));
}

test "operationTemplate explicit terminator mixin derives construction from one spec" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_explicit_terminator";
        const ops = operationTemplate.dialect(@This());

        pub const BranchOp = struct {
            op: *Operation,

            const term = ops.explicitTerminator(@This(), .{
                .mnemonic = "branch",
                .operands = shape.atLeast(1),
                .operand_names = .{"condition"},
                .successors = shape.atLeast(1),
                .successor_names = .{"target"},
            });
            pub const operation_spec = term.operation_spec;
            pub const operation_name = term.operation_name;
            pub const createTerminator = term.createTerminator;
            pub const getOperand = term.getOperand;
            pub const getSuccessor = term.getSuccessor;
        };

        pub const spec = dialectSpec(@This(), .{});
    };

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const bool_type = try ctx.getDialectTypeFromName("template_explicit_terminator.bool");
    var condition_state = Operation.State.init("template_explicit_terminator.seed", loc);
    condition_state.addTypes(&.{bool_type});
    const condition_op = try ctx.createOperation(condition_state);
    const condition = condition_op.getResult(0).?;

    var target_region = core.context.initRegion(&ctx);
    defer target_region.deinit();
    const target = try target_region.addBlock();

    const branch = try ExampleDialect.BranchOp.createTerminator(&ctx, loc, &.{condition}, &.{target});

    try testing.expectEqual(condition, branch.getOperand("condition"));
    try testing.expectEqual(target, branch.getSuccessor("target"));
    try testing.expect(branch.op.hasTraitId(core_traits.Terminator.id));
    const info = ctx.lookupOperation(ExampleDialect.BranchOp.operation_name) orelse return error.TestExpectedBranchOp;
    try testing.expect(info.traits.is_terminator);
    try testing.expect(info.hasTraitId(core_traits.Terminator.id));
}

test "operationTemplate generates same-type leaf operation wrappers" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template";
        const ops = operationTemplate.dialect(@This());

        pub const AddOp: type = ops.binarySameTypeFold("add", .{
            .traits = .{ .is_idempotent = true },
        }, operationTemplateNoopFold);

        pub const NegOp: type = ops.unarySameType("neg", .{
            .traits = .{ .is_idempotent = true },
        });
    };

    try testing.expectEqualStrings("template.add", ExampleDialect.AddOp.operation_name);
    try testing.expectEqualStrings("template.neg", ExampleDialect.NegOp.operation_name);
    try testing.expect(@hasDecl(ExampleDialect.AddOp, "fold"));
    try testing.expect(!@hasDecl(ExampleDialect.NegOp, "fold"));
    try testing.expect(ExampleDialect.AddOp.operation_spec.shape.operands.allows(2));
    try testing.expect(!ExampleDialect.AddOp.operation_spec.shape.operands.allows(1));
    try testing.expect(ExampleDialect.NegOp.operation_spec.shape.results.allows(1));

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const loc = Location.getUnknown();
    const i32_type = try ctx.getDialectTypeFromName("template.i32");

    var lhs_state = Operation.State.init("template.seed", loc);
    lhs_state.addTypes(&.{i32_type});
    const lhs_op = try ctx.createOperation(lhs_state);

    var rhs_state = Operation.State.init("template.seed", loc);
    rhs_state.addTypes(&.{i32_type});
    const rhs_op = try ctx.createOperation(rhs_state);

    const lhs = lhs_op.getResult(0).?;
    const rhs = rhs_op.getResult(0).?;
    const add = try ExampleDialect.AddOp.create(&ctx, loc, lhs, rhs);
    try testing.expectEqual(lhs, add.getLhs());
    try testing.expectEqual(rhs, add.getRhs());
    try testing.expect(add.getResult().type.eql(i32_type));

    const neg = try ExampleDialect.NegOp.create(&ctx, loc, add.getResult());
    try testing.expectEqual(add.getResult(), neg.getInput());
    try testing.expect(neg.getResult().type.eql(i32_type));
}

test "operationTemplate generates fixed-result leaf operation wrappers" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_fixed";
        const ops = operationTemplate.dialect(@This());

        pub const NotOp: type = ops.unaryFixedResult("not", .{
            .traits = .{ .is_idempotent = true },
            .operand_types = &.{typeConstraint.exact(0, "template_fixed.bool")},
            .result_types = &.{typeConstraint.exact(0, "template_fixed.bool")},
        }, operationTemplateFixedBoolType);

        pub const EqOp: type = ops.binaryFixedResult("eq", .{
            .traits = .{ .is_idempotent = true, .is_commutative = true },
            .result_types = &.{typeConstraint.exact(0, "template_fixed.bool")},
            .dynamic_traits = opSpec.dynamicTraits(.{core_traits.SameTypeOperands}),
        }, operationTemplateFixedBoolType);

        pub const spec = dialectSpec(@This(), .{});
    };

    try testing.expectEqualStrings("template_fixed.not", ExampleDialect.NotOp.operation_name);
    try testing.expectEqualStrings("template_fixed.eq", ExampleDialect.EqOp.operation_name);
    try testing.expect(ExampleDialect.NotOp.operation_spec.shape.operands.allows(1));
    try testing.expect(ExampleDialect.EqOp.operation_spec.shape.operands.allows(2));
    try testing.expect(ExampleDialect.EqOp.operation_spec.shape.results.allows(1));

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const bool_type = try ctx.getDialectTypeFromName("template_fixed.bool");
    const i32_type = try ctx.getDialectTypeFromName("template_fixed.i32");

    var bool_state = Operation.State.init("template_fixed.seed", loc);
    bool_state.addTypes(&.{bool_type});
    const bool_op = try ctx.createOperation(bool_state);

    var lhs_state = Operation.State.init("template_fixed.seed", loc);
    lhs_state.addTypes(&.{i32_type});
    const lhs_op = try ctx.createOperation(lhs_state);

    var rhs_state = Operation.State.init("template_fixed.seed", loc);
    rhs_state.addTypes(&.{i32_type});
    const rhs_op = try ctx.createOperation(rhs_state);

    const not = try ExampleDialect.NotOp.create(&ctx, loc, bool_op.getResult(0).?);
    try testing.expectEqual(bool_op.getResult(0).?, not.getInput());
    try testing.expect(not.getResult().type.eql(bool_type));

    const eq = try ExampleDialect.EqOp.create(&ctx, loc, lhs_op.getResult(0).?, rhs_op.getResult(0).?);
    try testing.expectEqual(lhs_op.getResult(0).?, eq.getLhs());
    try testing.expectEqual(rhs_op.getResult(0).?, eq.getRhs());
    try testing.expect(eq.getResult().type.eql(bool_type));

    const not_info = ctx.lookupOperation(ExampleDialect.NotOp.operation_name) orelse return error.TestExpectedNotOp;
    try testing.expectEqual(@as(usize, 1), not_info.getOperandTypeConstraints().len);
    try testing.expectEqual(@as(usize, 1), not_info.getResultTypeConstraints().len);
    const eq_info = ctx.lookupOperation(ExampleDialect.EqOp.operation_name) orelse return error.TestExpectedEqOp;
    try testing.expect(eq_info.traits.is_commutative);
    try testing.expectEqual(@as(usize, 1), eq_info.getResultTypeConstraints().len);
}

test "operationTemplate carries verifier helper metadata" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_verify";
        const ops = operationTemplate.dialect(@This());

        pub const AddOp: type = ops.binarySameType("add", .{
            .interfaces = &.{opSpec.verifier(operationTemplateNoopVerify)},
        });

        pub const spec = dialectSpec(@This(), .{});
    };

    try testing.expectEqualStrings("template_verify.add", ExampleDialect.AddOp.operation_name);
    try testing.expectEqual(@as(usize, 1), ExampleDialect.AddOp.operation_spec.interfaces.len);

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    try loadDialectSpec(&ctx, ExampleDialect.spec);
    const info = ctx.lookupOperation(ExampleDialect.AddOp.operation_name) orelse return error.TestExpectedAddOp;
    try testing.expect(info.hasInterface(VerifyOpInterface.id));
}

test "operationTemplate generates ternary same-type wrappers" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_ternary";
        const ops = operationTemplate.dialect(@This());

        pub const FmaOp: type = ops.ternarySameType("fma", .{
            .traits = .{ .is_idempotent = true },
        });
    };

    try testing.expectEqualStrings("template_ternary.fma", ExampleDialect.FmaOp.operation_name);
    try testing.expect(ExampleDialect.FmaOp.operation_spec.shape.operands.allows(3));
    try testing.expect(!ExampleDialect.FmaOp.operation_spec.shape.operands.allows(2));
    try testing.expect(ExampleDialect.FmaOp.operation_spec.shape.results.allows(1));

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const loc = Location.getUnknown();
    const f32_type = try ctx.getDialectTypeFromName("template_ternary.f32");

    var a_state = Operation.State.init("template_ternary.seed", loc);
    a_state.addTypes(&.{f32_type});
    const a_op = try ctx.createOperation(a_state);

    var b_state = Operation.State.init("template_ternary.seed", loc);
    b_state.addTypes(&.{f32_type});
    const b_op = try ctx.createOperation(b_state);

    var c_state = Operation.State.init("template_ternary.seed", loc);
    c_state.addTypes(&.{f32_type});
    const c_op = try ctx.createOperation(c_state);

    const fma = try ExampleDialect.FmaOp.create(
        &ctx,
        loc,
        a_op.getResult(0).?,
        b_op.getResult(0).?,
        c_op.getResult(0).?,
    );
    try testing.expectEqual(a_op.getResult(0).?, fma.getA());
    try testing.expectEqual(b_op.getResult(0).?, fma.getB());
    try testing.expectEqual(c_op.getResult(0).?, fma.getC());
    try testing.expect(fma.getResult().type.eql(f32_type));
}

test "operationTemplate generates select same-type wrappers" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_select";
        const ops = operationTemplate.dialect(@This());

        pub const SelectOp: type = ops.selectSameTypeFold("select", .{
            .traits = .{ .is_idempotent = true },
        }, operationTemplateNoopFold);
    };

    try testing.expectEqualStrings("template_select.select", ExampleDialect.SelectOp.operation_name);
    try testing.expect(@hasDecl(ExampleDialect.SelectOp, "fold"));
    try testing.expect(ExampleDialect.SelectOp.operation_spec.shape.operands.allows(3));
    try testing.expect(ExampleDialect.SelectOp.operation_spec.shape.results.allows(1));

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const loc = Location.getUnknown();
    const bool_type = try ctx.getDialectTypeFromName("template_select.bool");
    const i32_type = try ctx.getDialectTypeFromName("template_select.i32");

    var cond_state = Operation.State.init("template_select.seed", loc);
    cond_state.addTypes(&.{bool_type});
    const cond_op = try ctx.createOperation(cond_state);

    var true_state = Operation.State.init("template_select.seed", loc);
    true_state.addTypes(&.{i32_type});
    const true_op = try ctx.createOperation(true_state);

    var false_state = Operation.State.init("template_select.seed", loc);
    false_state.addTypes(&.{i32_type});
    const false_op = try ctx.createOperation(false_state);

    const select = try ExampleDialect.SelectOp.create(
        &ctx,
        loc,
        cond_op.getResult(0).?,
        true_op.getResult(0).?,
        false_op.getResult(0).?,
    );
    try testing.expectEqual(cond_op.getResult(0).?, select.getCondition());
    try testing.expectEqual(true_op.getResult(0).?, select.getTrueValue());
    try testing.expectEqual(false_op.getResult(0).?, select.getFalseValue());
    try testing.expect(select.getResult().type.eql(i32_type));
}

test "operationTemplate generates explicit-result unary wrappers" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_cast";
        const ops = operationTemplate.dialect(@This());

        pub const CastOp: type = ops.unaryExplicitTypeFold("cast", .{
            .traits = .{ .is_idempotent = true },
        }, operationTemplateNoopFold);

        pub const SplatOp: type = ops.unaryExplicitType("splat", .{
            .traits = .{ .is_idempotent = true },
        });
    };

    try testing.expectEqualStrings("template_cast.cast", ExampleDialect.CastOp.operation_name);
    try testing.expectEqualStrings("template_cast.splat", ExampleDialect.SplatOp.operation_name);
    try testing.expect(@hasDecl(ExampleDialect.CastOp, "fold"));
    try testing.expect(!@hasDecl(ExampleDialect.SplatOp, "fold"));
    try testing.expect(ExampleDialect.SplatOp.operation_spec.shape.operands.allows(1));
    try testing.expect(ExampleDialect.SplatOp.operation_spec.shape.results.allows(1));

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const loc = Location.getUnknown();
    const input_type = try ctx.getDialectTypeFromName("template_cast.i32");
    const output_type = try ctx.getDialectTypeFromName("template_cast.f32");

    var input_state = Operation.State.init("template_cast.seed", loc);
    input_state.addTypes(&.{input_type});
    const input_op = try ctx.createOperation(input_state);
    const input = input_op.getResult(0).?;

    const cast = try ExampleDialect.CastOp.create(&ctx, loc, input, output_type);
    try testing.expectEqual(input, cast.getInput());
    try testing.expect(cast.getResult().type.eql(output_type));

    const splat = try ExampleDialect.SplatOp.create(&ctx, loc, input, output_type);
    try testing.expectEqual(input, splat.getInput());
    try testing.expect(splat.getResult().type.eql(output_type));
}

test "operationTemplate generates unary attr and no-result wrappers" {
    const testing = std.testing;

    const ExampleDialect = struct {
        pub const name = "template_unary_attr";
        const ops = operationTemplate.dialect(@This());

        pub const BorrowOp: type = ops.unarySameTypeStringAttr(
            "borrow",
            "ownership",
            "borrowed",
            .{},
        );

        pub const SegmentedBorrowOp: type = ops.unarySameTypeStringAttr("segmented_borrow", "ownership", "borrowed", .{
            .operand_segments = segments.operands(.{1}),
        });

        pub const ReleaseOp: type = ops.unaryNoResult("release", .{});

        pub const spec = dialectSpec(@This(), .{});
    };

    try testing.expectEqualStrings("template_unary_attr.borrow", ExampleDialect.BorrowOp.operation_name);
    try testing.expectEqualStrings("template_unary_attr.release", ExampleDialect.ReleaseOp.operation_name);
    try testing.expect(ExampleDialect.BorrowOp.operation_spec.shape.operands.allows(1));
    try testing.expect(ExampleDialect.BorrowOp.operation_spec.shape.results.allows(1));
    try testing.expect(ExampleDialect.ReleaseOp.operation_spec.shape.operands.allows(1));
    try testing.expect(ExampleDialect.ReleaseOp.operation_spec.shape.results.allows(0));
    try testing.expectEqual(@as(usize, 1), ExampleDialect.BorrowOp.operation_spec.inherent_attribute_names.len);
    try testing.expectEqualStrings("ownership", ExampleDialect.BorrowOp.operation_spec.inherent_attribute_names[0]);
    try testing.expectEqualStrings(
        "operand_segment_sizes",
        ExampleDialect.SegmentedBorrowOp.operation_spec.operand_segments.?.attribute_name,
    );
    try testing.expectEqual(@as(usize, 1), ExampleDialect.SegmentedBorrowOp.operation_spec.operand_segments.?.segments.len);

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    try loadDialectSpec(&ctx, ExampleDialect.spec);

    const loc = Location.getUnknown();
    const i32_type = try ctx.getDialectTypeFromName("template_unary_attr.i32");

    var input_state = Operation.State.init("template_unary_attr.seed", loc);
    input_state.addTypes(&.{i32_type});
    const input_op = try ctx.createOperation(input_state);
    const input = input_op.getResult(0).?;

    const borrow = try ExampleDialect.BorrowOp.create(&ctx, loc, input);
    try testing.expectEqual(input, borrow.getInput());
    try testing.expect(borrow.getResult().type.eql(i32_type));
    try testing.expectEqualStrings("borrowed", borrow.getStringAttr().?);

    const release = try ExampleDialect.ReleaseOp.create(&ctx, loc, borrow.getResult());
    try testing.expectEqual(borrow.getResult(), release.getInput());
    try testing.expectEqual(@as(usize, 0), release.op.results.items.len);

    const info = ctx.lookupOperation(ExampleDialect.BorrowOp.operation_name) orelse return error.TestExpectedBorrowOp;
    try testing.expect(info.hasInherentAttributeName("ownership"));
}

test "DialectSpec registers operations, interfaces, traits, types, and dialect interfaces" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const MarkerInterface = struct {
        const id = interfaces.interfaceId("spec.marker");
        const VTable = struct { marker: u8 };
        const table = VTable{ .marker = 7 };
    };

    const TypeMarkerInterface = struct {
        const id = interfaces.interfaceId("spec.type.marker");
        const VTable = struct { marker: u8 };
        const table = VTable{ .marker = 9 };
    };

    const OpFallbackInterface = struct {
        pub const id = interfaces.interfaceId("spec.op.fallback");
        pub const VTable = struct { marker: u8 };
        const table = VTable{ .marker = 11 };
    };

    const ExplicitOpInterface = struct {
        pub const id = interfaces.interfaceId("spec.op.explicit");
        pub const VTable = struct { marker: u8 };
        const table = VTable{ .marker = 12 };
    };

    const TypeFallbackInterface = struct {
        pub const id = interfaces.interfaceId("spec.type.fallback");
        pub const VTable = struct { marker: u8 };
        const table = VTable{ .marker = 13 };
    };

    const ExampleProperties = struct {
        value: u8 = 0,

        fn init(storage: *anyopaque, _: std.mem.Allocator) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(storage));
            self.* = .{};
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        fn copyProperties(dest: *anyopaque, source: *const anyopaque) anyerror!void {
            const dest_self: *@This() = @ptrCast(@alignCast(dest));
            const source_self: *const @This() = @ptrCast(@alignCast(source));
            dest_self.* = source_self.*;
        }

        const model = interfaces.OperationPropertiesModel{
            .name = "spec.example.properties",
            .size = @sizeOf(@This()),
            .alignment = std.mem.Alignment.fromByteUnits(@alignOf(@This())),
            .init = init,
            .deinit = deinit,
            .copyProperties = copyProperties,
        };
    };

    const Trait = struct {
        pub const trait_name = "spec.trait";
        pub const id = interfaces.traitId(trait_name);
        fn verify(_: *const anyopaque) anyerror!void {}
        pub const vtable = interfaces.TraitVTable{ .verify = verify };
        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };

    const Fallbacks = struct {
        fn op(_: *const Operation) ?*const anyopaque {
            return @ptrCast(&OpFallbackInterface.table);
        }

        fn typ(_: *const Context, _: Type) ?*const anyopaque {
            return @ptrCast(&TypeFallbackInterface.table);
        }
    };

    const DialectForTest = struct {
        pub const name = "spec";
        const op_specs = opSpec.dialect(@This());
        pub const ExampleOp = struct {
            pub const operation_spec = op_specs.define(.{
                .mnemonic = "example",
                .traits = interfaces.OperationTraits{ .is_idempotent = true },
                .attrs = &.{ "value", "predicate" },
                .properties = ExampleProperties.model,
                .interfaces = &.{
                    interfaces.InterfaceEntry{
                        .id = ExplicitOpInterface.id,
                        .vtable = &ExplicitOpInterface.table,
                    },
                },
                .dynamic_traits = &.{trait(Trait)},
            });
            pub const operation_name = operation_spec.name;
        };
        pub const type_names = struct {
            pub const value = TypeSpec{
                .name = "spec.value",
                .interfaces = &.{
                    .{ .id = TypeMarkerInterface.id, .vtable = &TypeMarkerInterface.table },
                },
            };
            pub const token = "spec.token";
        };
        pub const spec = dialectSpec(@This(), .{
            .types = typeNames(type_names),
            .interfaces = &.{
                .{ .id = MarkerInterface.id, .vtable = &MarkerInterface.table },
            },
            .op_interface_fallbacks = &.{
                .{ .id = OpFallbackInterface.id, .fallback = Fallbacks.op },
            },
            .type_interface_fallbacks = &.{
                .{ .id = TypeFallbackInterface.id, .fallback = Fallbacks.typ },
            },
        });
    };

    try loadDialectSpec(&ctx, DialectForTest.spec);

    const info = ctx.lookupOperation(DialectForTest.ExampleOp.operation_name) orelse return error.TestExpectedOperation;
    try testing.expect(info.traits.is_idempotent);
    try testing.expect(info.hasInherentAttributeName("predicate"));
    try testing.expect(info.hasInherentAttributeName("value"));
    try testing.expect(info.hasPropertiesModel());
    try testing.expect(info.hasInterface(ExplicitOpInterface.id));
    try testing.expect(info.hasTraitId(Trait.id));
    try testing.expect(ctx.lookupTrait(Trait.id) != null);
    const type_info = ctx.lookupType(DialectForTest.type_names.value.name) orelse return error.TestExpectedType;
    try testing.expect(type_info.hasInterface(TypeMarkerInterface.id));
    try testing.expect(ctx.lookupType(DialectForTest.type_names.token) != null);
    try testing.expect(ctx.getDialectInterface(DialectForTest.name, MarkerInterface.id) != null);

    const op_state = Operation.State.init("spec.fallback_op", .unknown);
    const op = try ctx.createOperation(op_state);
    try testing.expectEqual(@as(u8, 11), op.getInterface(OpFallbackInterface).?.marker);

    const typ = try ctx.getDialectTypeFromName("spec.fallback_type");
    try testing.expectEqual(@as(u8, 13), ctx.typeInterface(typ, TypeFallbackInterface).?.vtable.marker);
}

test "DialectSpec derives verifier and CSE interfaces from operation declarations" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const Hooks = struct {
        fn verify(_: *const anyopaque) anyerror!void {}
        fn verifyRegions(_: *const anyopaque) anyerror!void {}
        fn verifySymbolUses(
            _: *const anyopaque,
            _: *core.SymbolTable.Collection,
        ) anyerror!void {}
        fn cseIncludeAttr(_: *const anyopaque, _: []const u8, _: Attribute) bool {
            return true;
        }
        fn fold(
            _: *const anyopaque,
            _: *interfaces.FoldResults,
        ) anyerror!void {}
    };

    const DialectForTest = struct {
        pub const name = "spec_auto";
        const op_specs = opSpec.dialect(@This());
        pub const ExampleOp = struct {
            pub const operation_spec = op_specs.define(.{ .mnemonic = "example" });
            pub const operation_name = operation_spec.name;
            pub const verify = Hooks.verify;
            pub const verifyRegions = Hooks.verifyRegions;
            pub const verifySymbolUses = Hooks.verifySymbolUses;
            pub const cseIncludeAttr = Hooks.cseIncludeAttr;
            pub const fold = Hooks.fold;
        };
        pub const spec = dialectSpec(@This(), .{});
    };

    try loadDialectSpec(&ctx, DialectForTest.spec);

    const info = ctx.lookupOperation(DialectForTest.ExampleOp.operation_name) orelse return error.TestExpectedOperation;
    try testing.expect(info.hasInterface(VerifyOpInterface.id));
    try testing.expect(info.hasInterface(VerifyRegionOpInterface.id));
    try testing.expect(info.hasInterface(interfaces.SymbolUserOpInterface.id));
    try testing.expect(info.hasInterface(interfaces.CseOpInterface.id));
    try testing.expect(info.hasInterface(interfaces.FoldOpInterface.id));
}

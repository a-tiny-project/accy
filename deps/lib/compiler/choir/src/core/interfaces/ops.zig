const std = @import("std");
const base = @import("base.zig");
const registry_entry = @import("entry.zig");
const traits = @import("traits.zig");
const format = @import("../root.zig").format;
const IrAttribute = @import("../root.zig").Attribute;
const IrBlock = @import("../root.zig").Block;
const IrOperation = @import("../root.zig").Operation;
const IrSymbolTable = @import("../root.zig").SymbolTable;
const IrType = @import("../root.zig").Type;
const IrValue = @import("../root.zig").Value;

const InterfaceId = base.InterfaceId;
const InterfaceEntry = base.InterfaceEntry;
const InterfaceEntries = base.InterfaceEntries;
const TraitId = traits.TraitId;
const OperationTraits = traits.OperationTraits;
const AttributeNameList = registry_entry.InlineList([]const u8, 0);

fn name_less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn type_constraint_less_than(
    _: void,
    a: OperationTypeConstraint,
    b: OperationTypeConstraint,
) bool {
    return a.index < b.index;
}

pub const CountRange = struct {
    min: usize = 0,
    max: ?usize = null,

    pub fn exactly(count: usize) CountRange {
        return .{ .min = count, .max = count };
    }

    pub fn atLeast(count: usize) CountRange {
        return .{ .min = count };
    }

    pub fn atMost(count: usize) CountRange {
        return .{ .max = count };
    }

    pub fn between(min: usize, max: usize) CountRange {
        return .{ .min = min, .max = max };
    }

    pub fn allows(self: CountRange, count: usize) bool {
        if (count < self.min) return false;
        if (self.max) |max| {
            if (count > max) return false;
        }
        return true;
    }

    pub fn hasConstraint(self: CountRange) bool {
        return self.min != 0 or self.max != null;
    }
};

pub const OperationShape = struct {
    operands: CountRange = .{},
    results: CountRange = .{},
    regions: CountRange = .{},
    successors: CountRange = .{},

    pub fn hasConstraints(self: OperationShape) bool {
        return self.operands.hasConstraint() or
            self.results.hasConstraint() or
            self.regions.hasConstraint() or
            self.successors.hasConstraint();
    }

    pub fn eql(self: OperationShape, other: OperationShape) bool {
        return std.meta.eql(self, other);
    }
};

pub const OperationSegmentSpec = struct {
    attribute_name: []const u8,
    segments: []const CountRange,

    pub fn hasSegments(self: OperationSegmentSpec) bool {
        return self.segments.len > 0;
    }

    pub fn eql(self: OperationSegmentSpec, other: OperationSegmentSpec) bool {
        if (!std.mem.eql(u8, self.attribute_name, other.attribute_name)) return false;
        if (self.segments.len != other.segments.len) return false;
        for (self.segments, other.segments) |a, b| {
            if (!std.meta.eql(a, b)) return false;
        }
        return true;
    }

    pub fn size(self: OperationSegmentSpec, op: *const IrOperation, index: usize) ?usize {
        if (index >= self.segments.len) return null;
        const attr = op.getAttrAs(IrAttribute.ArrayAttr, self.attribute_name) orelse return null;
        const values = attr.getValues();
        if (index >= values.len) return null;
        const int_attr = values[index].cast(IrAttribute.IntegerAttr) orelse return null;
        return std.math.cast(usize, int_attr.getValue());
    }

    pub fn offset(self: OperationSegmentSpec, op: *const IrOperation, index: usize) ?usize {
        if (index > self.segments.len) return null;
        const attr = op.getAttrAs(IrAttribute.ArrayAttr, self.attribute_name) orelse return null;
        const values = attr.getValues();
        if (index > values.len) return null;
        var result: usize = 0;
        for (values[0..index]) |value| {
            const int_attr = value.cast(IrAttribute.IntegerAttr) orelse return null;
            const size_value = std.math.cast(usize, int_attr.getValue()) orelse return null;
            result = std.math.add(usize, result, size_value) catch return null;
        }
        return result;
    }
};

pub const OperationTypeConstraint = struct {
    index: usize,
    type_name: []const u8,
    allow_parameterized: bool = false,

    pub fn eql(self: OperationTypeConstraint, other: OperationTypeConstraint) bool {
        return self.index == other.index and
            self.allow_parameterized == other.allow_parameterized and
            std.mem.eql(u8, self.type_name, other.type_name);
    }
};

pub const OperationPropertiesModel = struct {
    name: []const u8,
    size: usize,
    alignment: std.mem.Alignment,
    /// Only owner-defined complete representations qualify immutable capture.
    serialization: enum { unsupported, single_attribute } = .unsupported,

    init: *const fn (storage: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
    deinit: *const fn (storage: *anyopaque, allocator: std.mem.Allocator) void,
    getInherentAttr: ?*const fn (
        op: *const IrOperation,
        storage: *const anyopaque,
        name: []const u8,
    ) ?IrAttribute = null,
    setInherentAttr: ?*const fn (
        op: *IrOperation,
        storage: *anyopaque,
        name: []const u8,
        value: IrAttribute,
    ) anyerror!bool = null,
    removeInherentAttr: ?*const fn (
        op: *IrOperation,
        storage: *anyopaque,
        name: []const u8,
    ) bool = null,
    getPropertiesAsAttr: ?*const fn (
        op: *const IrOperation,
        storage: *const anyopaque,
    ) ?IrAttribute = null,
    setPropertiesFromAttr: ?*const fn (
        op: *IrOperation,
        storage: *anyopaque,
        attr: IrAttribute,
    ) anyerror!void = null,
    copyProperties: *const fn (
        dest: *anyopaque,
        source: *const anyopaque,
    ) anyerror!void,
};

fn single_attribute_properties_model_adapter(
    comptime model_name: []const u8,
    comptime attr_name: []const u8,
) type {
    return struct {
        const Storage = struct {
            value: ?IrAttribute = null,
        };

        comptime {
            std.debug.assert(@typeInfo(Storage).@"struct".field_names.len == 1);
        }

        fn from(storage: *anyopaque) *Storage {
            return @ptrCast(@alignCast(storage));
        }

        fn fromConst(storage: *const anyopaque) *const Storage {
            return @ptrCast(@alignCast(storage));
        }

        fn init(storage: *anyopaque, _: std.mem.Allocator) anyerror!void {
            from(storage).* = .{};
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        fn get(_: *const IrOperation, storage: *const anyopaque, name: []const u8) ?IrAttribute {
            if (!std.mem.eql(u8, name, attr_name)) return null;
            return fromConst(storage).value;
        }

        fn set(_: *IrOperation, storage: *anyopaque, name: []const u8, attr: IrAttribute) anyerror!bool {
            if (!std.mem.eql(u8, name, attr_name)) return false;
            from(storage).value = attr;
            return true;
        }

        fn remove(_: *IrOperation, storage: *anyopaque, name: []const u8) bool {
            if (!std.mem.eql(u8, name, attr_name)) return false;
            const self = from(storage);
            const existed = self.value != null;
            self.value = null;
            return existed;
        }

        fn getProperties(_: *const IrOperation, storage: *const anyopaque) ?IrAttribute {
            return fromConst(storage).value;
        }

        fn setProperties(_: *IrOperation, storage: *anyopaque, attr: IrAttribute) anyerror!void {
            from(storage).value = attr;
        }

        fn copyProperties(dest: *anyopaque, source: *const anyopaque) anyerror!void {
            from(dest).* = fromConst(source).*;
        }

        const model = OperationPropertiesModel{
            .name = model_name,
            .size = @sizeOf(Storage),
            .alignment = std.mem.Alignment.fromByteUnits(@alignOf(Storage)),
            .serialization = .single_attribute,
            .init = init,
            .deinit = deinit,
            .getInherentAttr = get,
            .setInherentAttr = set,
            .removeInherentAttr = remove,
            .getPropertiesAsAttr = getProperties,
            .setPropertiesFromAttr = setProperties,
            .copyProperties = copyProperties,
        };
    };
}

pub fn singleAttributePropertiesModel(
    comptime model_name: []const u8,
    comptime attr_name: []const u8,
) OperationPropertiesModel {
    return single_attribute_properties_model_adapter(model_name, attr_name).model;
}

pub const OperationInfo = struct {
    pub const dynamic_trait_inline_capacity = traits.TraitIds.inline_capacity;
    pub const interface_inline_capacity = InterfaceEntries.inline_capacity;

    pub const AttributeNameCapacity = struct {
        inherent: usize = 0,
        required: usize = 0,
    };

    name: []const u8,

    traits: OperationTraits = .{},

    shape: OperationShape = .{},

    dynamic_trait_ids: traits.TraitIds = .{},

    interfaces: InterfaceEntries = .{},

    inherent_attribute_names: AttributeNameList = .{},

    required_attribute_names: AttributeNameList = .{},

    operand_type_constraints: std.ArrayListUnmanaged(OperationTypeConstraint) = .empty,

    result_type_constraints: std.ArrayListUnmanaged(OperationTypeConstraint) = .empty,

    operand_segments: ?OperationSegmentSpec = null,

    result_segments: ?OperationSegmentSpec = null,

    properties_model: ?OperationPropertiesModel = null,

    /// Registration alone does not prove that the dialect's loader completed.
    /// Every active transaction still takes the checked loading path.
    dialect_load_complete: bool = false,

    pub const AddTraitError = error{DuplicateTrait} || std.mem.Allocator.Error;

    pub const AddInterfaceError = error{DuplicateInterface} || std.mem.Allocator.Error;

    pub const AddInherentAttributeNameError = error{DuplicateInherentAttributeName} || std.mem.Allocator.Error;

    pub const AddRequiredAttributeNameError = error{DuplicateRequiredAttributeName} || AddInherentAttributeNameError;

    pub const SetPropertiesModelError = error{
        DuplicateOperationProperties,
        IncompleteOperationPropertiesCodec,
    };
    pub const SetShapeError = error{ConflictingOperationShape};
    pub const SetSegmentSpecError = error{
        EmptySegmentAttributeName,
        EmptyOperationSegments,
        ConflictingOperandSegments,
        ConflictingResultSegments,
    } || std.mem.Allocator.Error;
    pub const AddTypeConstraintError = error{
        DuplicateOperandTypeConstraint,
        DuplicateResultTypeConstraint,
        ConflictingOperandTypeConstraint,
        ConflictingResultTypeConstraint,
    } || std.mem.Allocator.Error;

    pub fn init(name: []const u8) OperationInfo {
        return .{ .name = name };
    }

    pub fn initEntryStorage(
        name: []const u8,
        trait_storage: *[dynamic_trait_inline_capacity]TraitId,
        interface_storage: *[interface_inline_capacity]InterfaceEntry,
        inherent_attribute_storage: [][]const u8,
        required_attribute_storage: [][]const u8,
    ) OperationInfo {
        return .{
            .name = name,
            .dynamic_trait_ids = traits.TraitIds.initInline(trait_storage),
            .interfaces = InterfaceEntries.initInline(interface_storage),
            .inherent_attribute_names = initAttributeNameList(inherent_attribute_storage),
            .required_attribute_names = initAttributeNameList(required_attribute_storage),
        };
    }

    fn initAttributeNameList(storage: [][]const u8) AttributeNameList {
        if (storage.len == 0) return .{};
        return AttributeNameList.initBorrowed(storage);
    }

    pub fn deinit(self: *OperationInfo, allocator: std.mem.Allocator) void {
        self.dynamic_trait_ids.deinit(allocator);
        self.interfaces.deinit(allocator);
        for (self.inherent_attribute_names.values()) |name| {
            allocator.free(name);
        }
        self.inherent_attribute_names.deinit(allocator);
        for (self.required_attribute_names.values()) |name| {
            allocator.free(name);
        }
        self.required_attribute_names.deinit(allocator);
        for (self.operand_type_constraints.items) |constraint| {
            allocator.free(constraint.type_name);
        }
        self.operand_type_constraints.deinit(allocator);
        for (self.result_type_constraints.items) |constraint| {
            allocator.free(constraint.type_name);
        }
        self.result_type_constraints.deinit(allocator);
        if (self.operand_segments) |segment_spec| {
            freeSegmentSpec(allocator, segment_spec);
        }
        if (self.result_segments) |segment_spec| {
            freeSegmentSpec(allocator, segment_spec);
        }
    }

    pub fn addTrait(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        trait_id: TraitId,
    ) AddTraitError!void {
        try self.dynamic_trait_ids.insert(allocator, trait_id);
    }

    pub fn addInterface(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        entry: InterfaceEntry,
    ) AddInterfaceError!void {
        try self.interfaces.insert(allocator, entry);
    }

    pub fn addOrReplaceInterface(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        entry: InterfaceEntry,
    ) !void {
        try self.interfaces.insertOrReplace(allocator, entry);
    }

    pub fn addInherentAttributeName(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) AddInherentAttributeNameError!void {
        if (self.hasInherentAttributeName(name)) return error.DuplicateInherentAttributeName;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        try self.inherent_attribute_names.append(allocator, owned_name);

        std.mem.sort(
            []const u8,
            self.inherent_attribute_names.valuesMut(),
            {},
            name_less_than,
        );
    }

    pub fn addInherentAttributeNames(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        names: []const []const u8,
    ) AddInherentAttributeNameError!void {
        for (names) |name| {
            try self.addInherentAttributeName(allocator, name);
        }
    }

    pub fn getInherentAttributeNames(self: *const OperationInfo) []const []const u8 {
        return self.inherent_attribute_names.values();
    }

    pub fn hasInherentAttributeName(self: *const OperationInfo, name: []const u8) bool {
        return sortedNameContains(self.inherent_attribute_names.values(), name);
    }

    pub fn addRequiredAttributeName(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) AddRequiredAttributeNameError!void {
        if (!self.hasInherentAttributeName(name)) {
            try self.addInherentAttributeName(allocator, name);
        }
        if (self.hasRequiredAttributeName(name)) return error.DuplicateRequiredAttributeName;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        try self.required_attribute_names.append(allocator, owned_name);

        std.mem.sort(
            []const u8,
            self.required_attribute_names.valuesMut(),
            {},
            name_less_than,
        );
    }

    pub fn addRequiredAttributeNames(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        names: []const []const u8,
    ) AddRequiredAttributeNameError!void {
        for (names) |name| {
            try self.addRequiredAttributeName(allocator, name);
        }
    }

    pub fn getRequiredAttributeNames(self: *const OperationInfo) []const []const u8 {
        return self.required_attribute_names.values();
    }

    pub fn hasRequiredAttributeName(self: *const OperationInfo, name: []const u8) bool {
        return sortedNameContains(self.required_attribute_names.values(), name);
    }

    fn sortedNameContains(names: []const []const u8, name: []const u8) bool {
        var left: usize = 0;
        var right: usize = names.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = std.mem.order(u8, names[mid], name);
            switch (cmp) {
                .eq => return true,
                .lt => left = mid + 1,
                .gt => right = mid,
            }
        }
        return false;
    }

    pub fn setPropertiesModel(
        self: *OperationInfo,
        model: OperationPropertiesModel,
    ) SetPropertiesModelError!void {
        if (self.properties_model != null) return error.DuplicateOperationProperties;
        if ((model.getPropertiesAsAttr == null) != (model.setPropertiesFromAttr == null)) {
            return error.IncompleteOperationPropertiesCodec;
        }
        self.properties_model = model;
    }

    pub fn getPropertiesModel(self: *const OperationInfo) ?*const OperationPropertiesModel {
        if (self.properties_model) |*model| return model;
        return null;
    }

    pub fn hasPropertiesModel(self: *const OperationInfo) bool {
        return self.properties_model != null;
    }

    pub fn setShape(
        self: *OperationInfo,
        shape: OperationShape,
    ) SetShapeError!void {
        if (self.shape.hasConstraints() and !self.shape.eql(shape)) {
            return error.ConflictingOperationShape;
        }
        self.shape = shape;
    }

    pub fn setOperandSegments(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        spec: OperationSegmentSpec,
    ) SetSegmentSpecError!void {
        try self.setSegmentSpec(allocator, &self.operand_segments, spec, error.ConflictingOperandSegments);
    }

    pub fn setResultSegments(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        spec: OperationSegmentSpec,
    ) SetSegmentSpecError!void {
        try self.setSegmentSpec(allocator, &self.result_segments, spec, error.ConflictingResultSegments);
    }

    fn setSegmentSpec(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        slot: *?OperationSegmentSpec,
        spec: OperationSegmentSpec,
        conflict: SetSegmentSpecError,
    ) SetSegmentSpecError!void {
        _ = self;
        if (spec.attribute_name.len == 0) return error.EmptySegmentAttributeName;
        if (spec.segments.len == 0) return error.EmptyOperationSegments;
        if (slot.*) |existing| {
            if (existing.eql(spec)) return;
            return conflict;
        }

        const owned_name = try allocator.dupe(u8, spec.attribute_name);
        errdefer allocator.free(owned_name);
        const owned_segments = try allocator.dupe(CountRange, spec.segments);
        errdefer allocator.free(owned_segments);
        slot.* = .{
            .attribute_name = owned_name,
            .segments = owned_segments,
        };
    }

    pub fn addOperandTypeConstraint(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        constraint: OperationTypeConstraint,
    ) AddTypeConstraintError!void {
        try self.addTypeConstraint(
            allocator,
            &self.operand_type_constraints,
            constraint,
            error.DuplicateOperandTypeConstraint,
            error.ConflictingOperandTypeConstraint,
        );
    }

    pub fn addResultTypeConstraint(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        constraint: OperationTypeConstraint,
    ) AddTypeConstraintError!void {
        try self.addTypeConstraint(
            allocator,
            &self.result_type_constraints,
            constraint,
            error.DuplicateResultTypeConstraint,
            error.ConflictingResultTypeConstraint,
        );
    }

    fn addTypeConstraint(
        self: *OperationInfo,
        allocator: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(OperationTypeConstraint),
        constraint: OperationTypeConstraint,
        duplicate: AddTypeConstraintError,
        conflict: AddTypeConstraintError,
    ) AddTypeConstraintError!void {
        _ = self;
        for (list.items) |existing| {
            if (existing.index == constraint.index) {
                if (existing.eql(constraint)) return duplicate;
                return conflict;
            }
        }

        const owned_name = try allocator.dupe(u8, constraint.type_name);
        errdefer allocator.free(owned_name);
        try list.append(allocator, .{
            .index = constraint.index,
            .type_name = owned_name,
            .allow_parameterized = constraint.allow_parameterized,
        });
        std.mem.sort(OperationTypeConstraint, list.items, {}, type_constraint_less_than);
    }

    pub fn getOperandTypeConstraints(self: *const OperationInfo) []const OperationTypeConstraint {
        return self.operand_type_constraints.items;
    }

    pub fn getResultTypeConstraints(self: *const OperationInfo) []const OperationTypeConstraint {
        return self.result_type_constraints.items;
    }

    pub fn getOperandSegments(self: *const OperationInfo) ?OperationSegmentSpec {
        return self.operand_segments;
    }

    pub fn getResultSegments(self: *const OperationInfo) ?OperationSegmentSpec {
        return self.result_segments;
    }

    pub fn getInterface(self: *const OperationInfo, id: InterfaceId) ?*const anyopaque {
        return self.interfaces.get(id);
    }

    pub fn hasTraitId(self: *const OperationInfo, trait_id: TraitId) bool {
        return self.dynamic_trait_ids.contains(trait_id);
    }

    pub fn getDynamicTraitIds(self: *const OperationInfo) []const TraitId {
        return self.dynamic_trait_ids.values();
    }

    pub fn hasInterface(self: *const OperationInfo, id: InterfaceId) bool {
        return self.getInterface(id) != null;
    }

    pub fn getNumInterfaces(self: *const OperationInfo) usize {
        return self.interfaces.count();
    }
};

pub const OperationRegistry = struct {
    allocator: std.mem.Allocator,

    ops: std.StringHashMapUnmanaged(*OperationInfo),
    batch_regions: ?*BatchEntryStorage.RegionOwner,

    allow_unregistered_operations: bool,

    pub const RegisterPropertiesModelError = OperationInfo.SetPropertiesModelError || GetOrCreateError;
    pub const RegisterShapeError = OperationInfo.SetShapeError || GetOrCreateError;
    pub const RegisterSegmentSpecError = OperationInfo.SetSegmentSpecError || GetOrCreateError;
    pub const RegisterTypeConstraintError = OperationInfo.AddTypeConstraintError || GetOrCreateError;

    pub const GetOrCreateError: type = std.mem.Allocator.Error;

    pub const GetOrCreateResult = struct {
        info: *OperationInfo,
        created: bool,
    };

    pub const RegisterTraitError: type = OperationInfo.AddTraitError;
    pub const RegisterInterfaceError: type = OperationInfo.AddInterfaceError;
    pub const RegisterInherentAttributeNameError: type =
        OperationInfo.AddInherentAttributeNameError;
    pub const RegisterRequiredAttributeNameError: type =
        OperationInfo.AddRequiredAttributeNameError;

    const EntryStorage: type = registry_entry.InlineStorage(
        OperationInfo,
        TraitId,
        OperationInfo.dynamic_trait_inline_capacity,
        InterfaceEntry,
        OperationInfo.interface_inline_capacity,
        []const u8,
        []const u8,
    );
    const BatchEntryStorage: type = EntryStorage.BatchStorage;

    pub fn init(allocator: std.mem.Allocator) OperationRegistry {
        return .{
            .allocator = allocator,
            .ops = .{},
            .batch_regions = null,
            .allow_unregistered_operations = false,
        };
    }

    pub fn deinit(self: *OperationRegistry) void {
        var it = self.ops.valueIterator();
        while (it.next()) |info_ptr| {
            const info = info_ptr.*;
            if (self.findBatchRegionLink(info) != null) {
                info.deinit(self.allocator);
                info.* = undefined;
            } else {
                EntryStorage.destroy(self.allocator, info);
            }
        }
        self.ops.deinit(self.allocator);
        while (self.batch_regions) |region| {
            self.batch_regions = region.next;
            BatchEntryStorage.destroy(self.allocator, region);
        }
    }

    pub fn lookup(self: *const OperationRegistry, op_name: []const u8) ?*OperationInfo {
        return self.ops.get(op_name);
    }

    pub const PrehashedContext = struct {
        hash_value: u64,

        pub fn hash(self: PrehashedContext, _: []const u8) u64 {
            return self.hash_value;
        }

        pub fn eql(_: PrehashedContext, requested: []const u8, stored: []const u8) bool {
            return std.mem.eql(u8, requested, stored);
        }
    };

    pub fn lookupHashed(self: *const OperationRegistry, op_name: []const u8, hash: u64) ?*OperationInfo {
        return self.ops.getAdapted(op_name, PrehashedContext{ .hash_value = hash });
    }

    pub fn getOrCreate(self: *OperationRegistry, op_name: []const u8) GetOrCreateError!*OperationInfo {
        return (try self.getOrCreateTracked(op_name)).info;
    }

    pub fn getOrCreateTracked(self: *OperationRegistry, op_name: []const u8) GetOrCreateError!GetOrCreateResult {
        return self.getOrCreateTrackedWithAttributeNameCapacity(op_name, .{});
    }

    pub fn getOrCreateTrackedWithAttributeNameCapacity(
        self: *OperationRegistry,
        op_name: []const u8,
        capacity: OperationInfo.AttributeNameCapacity,
    ) GetOrCreateError!GetOrCreateResult {
        if (self.ops.get(op_name)) |existing| {
            return .{ .info = existing, .created = false };
        }

        const info = try EntryStorage.create(
            self.allocator,
            op_name,
            capacity.inherent,
            capacity.required,
        );
        errdefer EntryStorage.destroy(self.allocator, info);

        const gop = try self.ops.getOrPut(self.allocator, info.name);
        if (gop.found_existing) {
            EntryStorage.destroy(self.allocator, info);
            return .{ .info = gop.value_ptr.*, .created = false };
        }

        gop.value_ptr.* = info;
        return .{ .info = info, .created = true };
    }

    pub fn getOrCreateOperationBatch(
        self: *OperationRegistry,
        operation_specs: anytype,
    ) GetOrCreateError!void {
        var capacity_value: BatchEntryStorage.Capacity = .{};
        for (operation_specs) |op| {
            if (self.ops.get(op.name) != null) continue;
            capacity_value.add(
                op.name.len,
                op.inherent_attribute_names.len,
                op.required_attribute_names.len,
            ) catch return error.OutOfMemory;
        }
        if (capacity_value.entry_count == 0) return;
        const unused_capacity = std.math.cast(
            u32,
            capacity_value.entry_count,
        ) orelse return error.OutOfMemory;

        const allocation = try BatchEntryStorage.create(
            self.allocator,
            capacity_value,
        );
        errdefer BatchEntryStorage.destroy(self.allocator, allocation.region);

        try self.ops.ensureUnusedCapacity(self.allocator, unused_capacity);
        var cursor = BatchEntryStorage.Cursor.init(allocation.entries);
        for (operation_specs) |op| {
            if (self.ops.get(op.name) != null) continue;
            const info = cursor.create(
                op.name,
                op.inherent_attribute_names.len,
                op.required_attribute_names.len,
            );
            self.ops.putAssumeCapacityNoClobber(info.name, info);
        }
        std.debug.assert(cursor.offset <= allocation.entries.len);

        allocation.region.next = self.batch_regions;
        self.batch_regions = allocation.region;
    }

    pub fn registerOperation(
        self: *OperationRegistry,
        op_name: []const u8,
        traits_val: OperationTraits,
    ) GetOrCreateError!*OperationInfo {
        const info = try self.getOrCreate(op_name);
        info.traits = info.traits.merge(traits_val);
        return info;
    }

    pub fn registerTrait(
        self: *OperationRegistry,
        op_name: []const u8,
        trait_id: TraitId,
    ) RegisterTraitError!void {
        const info = try self.getOrCreate(op_name);
        try info.addTrait(self.allocator, trait_id);
    }

    pub fn registerInterface(
        self: *OperationRegistry,
        op_name: []const u8,
        entry: InterfaceEntry,
    ) RegisterInterfaceError!void {
        const info = try self.getOrCreate(op_name);
        try info.addInterface(self.allocator, entry);
    }

    pub fn registerOrReplaceInterface(
        self: *OperationRegistry,
        op_name: []const u8,
        entry: InterfaceEntry,
    ) GetOrCreateError!void {
        const info = try self.getOrCreate(op_name);
        try info.addOrReplaceInterface(self.allocator, entry);
    }

    pub fn registerInherentAttributeName(
        self: *OperationRegistry,
        op_name: []const u8,
        attr_name: []const u8,
    ) RegisterInherentAttributeNameError!void {
        const info = try self.getOrCreate(op_name);
        try info.addInherentAttributeName(self.allocator, attr_name);
    }

    pub fn registerRequiredAttributeName(
        self: *OperationRegistry,
        op_name: []const u8,
        attr_name: []const u8,
    ) RegisterRequiredAttributeNameError!void {
        const info = try self.getOrCreate(op_name);
        try info.addRequiredAttributeName(self.allocator, attr_name);
    }

    pub fn registerInherentAttributeNames(
        self: *OperationRegistry,
        op_name: []const u8,
        attr_names: []const []const u8,
    ) RegisterInherentAttributeNameError!void {
        const info = try self.getOrCreate(op_name);
        try info.addInherentAttributeNames(self.allocator, attr_names);
    }

    pub fn registerPropertiesModel(
        self: *OperationRegistry,
        op_name: []const u8,
        model: OperationPropertiesModel,
    ) RegisterPropertiesModelError!void {
        const info = try self.getOrCreate(op_name);
        try info.setPropertiesModel(model);
    }

    pub fn registerShape(
        self: *OperationRegistry,
        op_name: []const u8,
        shape: OperationShape,
    ) RegisterShapeError!void {
        const info = try self.getOrCreate(op_name);
        try info.setShape(shape);
    }

    pub fn registerOperandSegments(
        self: *OperationRegistry,
        op_name: []const u8,
        spec: OperationSegmentSpec,
    ) RegisterSegmentSpecError!void {
        const info = try self.getOrCreate(op_name);
        try info.setOperandSegments(self.allocator, spec);
    }

    pub fn registerResultSegments(
        self: *OperationRegistry,
        op_name: []const u8,
        spec: OperationSegmentSpec,
    ) RegisterSegmentSpecError!void {
        const info = try self.getOrCreate(op_name);
        try info.setResultSegments(self.allocator, spec);
    }

    pub fn registerOperandTypeConstraint(
        self: *OperationRegistry,
        op_name: []const u8,
        constraint: OperationTypeConstraint,
    ) RegisterTypeConstraintError!void {
        const info = try self.getOrCreate(op_name);
        try info.addOperandTypeConstraint(self.allocator, constraint);
    }

    pub fn registerResultTypeConstraint(
        self: *OperationRegistry,
        op_name: []const u8,
        constraint: OperationTypeConstraint,
    ) RegisterTypeConstraintError!void {
        const info = try self.getOrCreate(op_name);
        try info.addResultTypeConstraint(self.allocator, constraint);
    }

    pub fn count(self: *const OperationRegistry) usize {
        return self.ops.count();
    }

    pub fn removeOperation(self: *OperationRegistry, op_name: []const u8) bool {
        const removed = self.ops.fetchRemove(op_name) orelse return false;
        const info = removed.value;
        std.debug.assert(removed.key.ptr == info.name.ptr);
        if (self.findBatchRegionLink(info)) |region_link| {
            const region = region_link.*.?;
            info.deinit(self.allocator);
            info.* = undefined;
            if (!self.batchRegionHasLiveInfo(region)) {
                region_link.* = region.next;
                BatchEntryStorage.destroy(self.allocator, region);
            }
        } else {
            EntryStorage.destroy(self.allocator, info);
        }
        return true;
    }

    fn findBatchRegionLink(
        self: *OperationRegistry,
        info: *const OperationInfo,
    ) ?*?*BatchEntryStorage.RegionOwner {
        var region_link = &self.batch_regions;
        while (region_link.*) |region| {
            if (BatchEntryStorage.contains(region, info)) return region_link;
            region_link = &region.next;
        }
        return null;
    }

    fn batchRegionHasLiveInfo(
        self: *const OperationRegistry,
        region: *const BatchEntryStorage.RegionOwner,
    ) bool {
        var it = self.ops.valueIterator();
        while (it.next()) |info_ptr| {
            if (BatchEntryStorage.contains(region, info_ptr.*)) return true;
        }
        return false;
    }
};

fn freeSegmentSpec(allocator: std.mem.Allocator, spec: OperationSegmentSpec) void {
    allocator.free(spec.attribute_name);
    allocator.free(spec.segments);
}

pub const CseOpInterface = struct {
    pub const interface_name = "ir.interface.cse_op";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        includeAttributeInKey: *const fn (
            op: *const anyopaque,
            name: []const u8,
            value: IrAttribute,
        ) bool,
        commuteOperandsInKey: *const fn (op: *const anyopaque) bool,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    fn neverCommuteOperandsInKey(_: *const anyopaque) bool {
        return false;
    }

    pub fn vtableFor(
        comptime includeAttributeInKey: *const fn (
            op: *const anyopaque,
            name: []const u8,
            value: IrAttribute,
        ) bool,
    ) *const VTable {
        return &.{
            .includeAttributeInKey = includeAttributeInKey,
            .commuteOperandsInKey = neverCommuteOperandsInKey,
        };
    }

    pub fn keyPolicyVTableFor(
        comptime includeAttributeInKey: *const fn (
            op: *const anyopaque,
            name: []const u8,
            value: IrAttribute,
        ) bool,
        comptime commuteOperandsInKey: *const fn (op: *const anyopaque) bool,
    ) *const VTable {
        return &.{
            .includeAttributeInKey = includeAttributeInKey,
            .commuteOperandsInKey = commuteOperandsInKey,
        };
    }

    pub fn entryFor(
        comptime includeAttributeInKey: *const fn (
            op: *const anyopaque,
            name: []const u8,
            value: IrAttribute,
        ) bool,
    ) InterfaceEntry {
        return entry(vtableFor(includeAttributeInKey));
    }

    pub fn keyPolicyEntryFor(
        comptime includeAttributeInKey: *const fn (
            op: *const anyopaque,
            name: []const u8,
            value: IrAttribute,
        ) bool,
        comptime commuteOperandsInKey: *const fn (op: *const anyopaque) bool,
    ) InterfaceEntry {
        return entry(keyPolicyVTableFor(includeAttributeInKey, commuteOperandsInKey));
    }
};

pub const SymbolOpInterface = struct {
    pub const interface_name = "ir.interface.symbol_op";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getSymbolName: *const fn (op: *const anyopaque) ?[]const u8,
        setSymbolName: *const fn (op: *const anyopaque, name: []const u8) anyerror!void,
        isDeclaration: *const fn (op: *const anyopaque) bool,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }
};

pub const SymbolUserOpInterface = struct {
    pub const interface_name = "ir.interface.symbol_user_op";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        verifySymbolUses: *const fn (
            op: *const anyopaque,
            symbol_tables: *IrSymbolTable.Collection,
        ) anyerror!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime verifySymbolUses: *const fn (
            op: *const anyopaque,
            symbol_tables: *IrSymbolTable.Collection,
        ) anyerror!void,
    ) *const VTable {
        return &.{ .verifySymbolUses = verifySymbolUses };
    }

    pub fn entryFor(
        comptime verifySymbolUses: *const fn (
            op: *const anyopaque,
            symbol_tables: *IrSymbolTable.Collection,
        ) anyerror!void,
    ) InterfaceEntry {
        return entry(vtableFor(verifySymbolUses));
    }
};

pub const CallOpInterface = struct {
    pub const interface_name = "ir.interface.call_op";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getCalleeSymbol: *const fn (op: *const anyopaque) ?[]const u8,
        getCalleeValue: *const fn (op: *const anyopaque) ?*IrValue,
        getArgumentValues: *const fn (op: *const anyopaque) []const *IrValue,
        getArgumentKeywords: *const fn (op: *const anyopaque) []const []const u8,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }
};

pub const FunctionOpInterface = struct {
    pub const interface_name = "ir.interface.function_op";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        hasBody: *const fn (op: *const anyopaque) bool,
        getEntryBlock: *const fn (op: *const anyopaque) ?*IrBlock,
        getArgumentCount: *const fn (op: *const anyopaque) usize,
        getResultCount: *const fn (op: *const anyopaque) usize,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }
};

pub const RegionKind = enum {
    ssacfg,
    graph,
};

pub const RegionKindInterface = struct {
    pub const interface_name = "ir.interface.region_kind";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getRegionKind: *const fn (op: *const anyopaque, index: usize) RegionKind,
        hasSSADominance: *const fn (op: *const anyopaque, index: usize) bool,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime getRegionKind: *const fn (op: *const anyopaque, index: usize) RegionKind,
        comptime hasSSADominance: *const fn (op: *const anyopaque, index: usize) bool,
    ) *const VTable {
        return &.{
            .getRegionKind = getRegionKind,
            .hasSSADominance = hasSSADominance,
        };
    }

    pub fn entryFor(
        comptime getRegionKind: *const fn (op: *const anyopaque, index: usize) RegionKind,
        comptime hasSSADominance: *const fn (op: *const anyopaque, index: usize) bool,
    ) InterfaceEntry {
        return entry(vtableFor(getRegionKind, hasSSADominance));
    }

    fn graphRegionKind(_: *const anyopaque, _: usize) RegionKind {
        return .graph;
    }

    fn graphHasSSADominance(_: *const anyopaque, _: usize) bool {
        return false;
    }

    pub fn allGraphRegionsEntry() InterfaceEntry {
        return entry(vtableFor(graphRegionKind, graphHasSSADominance));
    }
};

pub const ControlFlowInterface = struct {
    pub const interface_name = "ir.interface.control_flow";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getSuccessorCount: *const fn (op: *const anyopaque) usize,
        getSuccessor: *const fn (op: *const anyopaque, index: usize) ?*IrBlock,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime getSuccessorCount: *const fn (op: *const anyopaque) usize,
        comptime getSuccessor: *const fn (op: *const anyopaque, index: usize) ?*IrBlock,
    ) *const VTable {
        return &.{
            .getSuccessorCount = getSuccessorCount,
            .getSuccessor = getSuccessor,
        };
    }

    pub fn entryFor(
        comptime getSuccessorCount: *const fn (op: *const anyopaque) usize,
        comptime getSuccessor: *const fn (op: *const anyopaque, index: usize) ?*IrBlock,
    ) InterfaceEntry {
        return entry(vtableFor(getSuccessorCount, getSuccessor));
    }
};

pub const InferTypeOpInterface = struct {
    pub const interface_name = "ir.interface.infer_type";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        inferResultTypes: *const fn (
            op: *const anyopaque,
            allocator: std.mem.Allocator,
            out_types: *std.ArrayListUnmanaged(IrType),
        ) anyerror!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime inferResultTypes: *const fn (
            op: *const anyopaque,
            allocator: std.mem.Allocator,
            out_types: *std.ArrayListUnmanaged(IrType),
        ) anyerror!void,
    ) *const VTable {
        return &.{ .inferResultTypes = inferResultTypes };
    }

    pub fn entryFor(
        comptime inferResultTypes: *const fn (
            op: *const anyopaque,
            allocator: std.mem.Allocator,
            out_types: *std.ArrayListUnmanaged(IrType),
        ) anyerror!void,
    ) InterfaceEntry {
        return entry(vtableFor(inferResultTypes));
    }
};

pub const FoldResult = union(enum) {
    value: *IrValue,
    attribute: IrAttribute,
};

pub const FoldResults = struct {
    storage: []FoldResult,
    len: usize = 0,

    pub fn init(storage: []FoldResult) FoldResults {
        return .{ .storage = storage };
    }

    pub fn append(self: *FoldResults, result: FoldResult) error{CapacityExceeded}!void {
        std.debug.assert(self.len <= self.storage.len);
        if (self.len == self.storage.len) return error.CapacityExceeded;
        self.storage[self.len] = result;
        self.len += 1;
    }

    pub fn slice(self: *const FoldResults) []const FoldResult {
        std.debug.assert(self.len <= self.storage.len);
        return self.storage[0..self.len];
    }
};

pub const FoldOpInterface = struct {
    pub const interface_name = "ir.interface.fold_op";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        fold: *const fn (
            op: *const anyopaque,
            results: *FoldResults,
        ) anyerror!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime fold: *const fn (
            op: *const anyopaque,
            results: *FoldResults,
        ) anyerror!void,
    ) *const VTable {
        return &.{ .fold = fold };
    }

    pub fn entryFor(
        comptime fold: *const fn (
            op: *const anyopaque,
            results: *FoldResults,
        ) anyerror!void,
    ) InterfaceEntry {
        return entry(vtableFor(fold));
    }
};

pub const DiagnosticKind = enum {
    error_,
    warning,
};

pub const EvalError = error{
    UnsupportedOperation,
    UnknownEffect,
    EffectViolation,
    LocationViolation,
    DivisionByZero,
    InvalidOperand,
    InvalidConstant,
    RequiresDynamicInfo,
    InvalidShiftAmount,
    SignedDivisionOverflow,
    InvalidFloatToInteger,
    AbstractValueInConstant,
    InvalidPredicate,
    EvaluationFailed,
    Overflow,
    RecursionDepthExceeded,
    InvalidCondition,
    InvalidSize,
    NegativeSize,
    InvalidHandle,
    HandleAlreadyDropped,
    BorrowOfInvalidHandle,
    MoveOfInvalidHandle,
    BranchQuotaExceeded,
    IterationQuotaExceeded,
    DeviceLocationForbidden,
    UnifiedLocationForbidden,
    YieldMissingOperand,
    NoYield,
    ValueNotFound,
    OutOfMemory,
};

pub const EvalContext = struct {
    state: *anyopaque,
    allocator: std.mem.Allocator,
    emitDiagnostic: *const fn (state: *anyopaque, kind: DiagnosticKind, message: []const u8) EvalError!void,

    evaluateRegion: *const fn (state: *anyopaque, region: *const anyopaque) EvalError!IrAttribute,

    evaluateRegionWithArgs: *const fn (
        state: *anyopaque,
        region: *const anyopaque,
        args: []const IrAttribute,
    ) EvalError!IrAttribute,

    evaluateSymbol: *const fn (
        state: *anyopaque,
        symbol: []const u8,
        args: []const IrAttribute,
    ) EvalError!IrAttribute,

    consumeBranchFuel: *const fn (state: *anyopaque) EvalError!void,

    consumeIterationFuel: *const fn (state: *anyopaque) EvalError!void,

    allocHandle: *const fn (state: *anyopaque, size: i64) EvalError!i64,

    borrowHandle: *const fn (state: *anyopaque, handle: i64) EvalError!i64,

    borrowMutHandle: *const fn (state: *anyopaque, handle: i64) EvalError!i64,

    moveHandle: *const fn (state: *anyopaque, handle: i64) EvalError!i64,

    dropHandle: *const fn (state: *anyopaque, handle: i64) EvalError!void,

    createRewriteBuilder: *const fn (state: *anyopaque, root: *IrOperation) EvalError!*anyopaque,
};

pub const Evaluatable = struct {
    pub const interface_name = "ir.interface.evaluatable";

    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        canEval: *const fn (op: *const anyopaque) bool,

        evaluate: *const fn (
            op: *const anyopaque,
            operands: []const IrAttribute,
            ctx: *const EvalContext,
        ) EvalError!IrAttribute,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime can_eval: *const fn (op: *const anyopaque) bool,
        comptime evaluate: *const fn (
            op: *const anyopaque,
            operands: []const IrAttribute,
            ctx: *const EvalContext,
        ) EvalError!IrAttribute,
    ) *const VTable {
        return &.{
            .canEval = can_eval,
            .evaluate = evaluate,
        };
    }

    pub fn entryFor(
        comptime can_eval: *const fn (op: *const anyopaque) bool,
        comptime evaluate: *const fn (
            op: *const anyopaque,
            operands: []const IrAttribute,
            ctx: *const EvalContext,
        ) EvalError!IrAttribute,
    ) InterfaceEntry {
        return entry(vtableFor(can_eval, evaluate));
    }

    pub fn canAlwaysFold(_: *const anyopaque) bool {
        return true;
    }

    pub fn canNeverFold(_: *const anyopaque) bool {
        return false;
    }
};

pub const YieldOpInterface = struct {
    pub const interface_name = "ir.interface.yield_op";

    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getYieldOperandCount: *const fn (op: *const anyopaque) usize,
        getYieldOperand: *const fn (op: *const anyopaque, index: usize) ?*IrValue,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime getYieldOperandCount: *const fn (op: *const anyopaque) usize,
        comptime getYieldOperand: *const fn (op: *const anyopaque, index: usize) ?*IrValue,
    ) *const VTable {
        return &.{
            .getYieldOperandCount = getYieldOperandCount,
            .getYieldOperand = getYieldOperand,
        };
    }

    pub fn entryFor(
        comptime getYieldOperandCount: *const fn (op: *const anyopaque) usize,
        comptime getYieldOperand: *const fn (op: *const anyopaque, index: usize) ?*IrValue,
    ) InterfaceEntry {
        return entry(vtableFor(getYieldOperandCount, getYieldOperand));
    }
};

pub const HandlerEntryOpInterface = struct {
    pub const interface_name = "ir.interface.handler_entry";

    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getEffectName: *const fn (op: *const anyopaque) ?[]const u8,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(comptime getEffectName: *const fn (op: *const anyopaque) ?[]const u8) *const VTable {
        return &.{ .getEffectName = getEffectName };
    }

    pub fn entryFor(comptime getEffectName: *const fn (op: *const anyopaque) ?[]const u8) InterfaceEntry {
        return entry(vtableFor(getEffectName));
    }
};

pub const TranslationDialectInterface = struct {
    pub const interface_name = "ir.interface.dialect_translation";

    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const TranslationError = error{UnsupportedOperation} || std.mem.Allocator.Error;

    pub const VTable = struct {
        translate: *const fn (op: *const anyopaque, ctx: *const anyopaque) TranslationError!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }
};

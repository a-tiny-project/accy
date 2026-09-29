const std = @import("std");
const accy = @import("accy");
const choir = @import("choir");

const Allocator = std.mem.Allocator;
const composition = choir.composition;

pub const lhs_boundary = composition.BoundaryId{ .value = 1 };
pub const rhs_boundary = composition.BoundaryId{ .value = 2 };
pub const output_boundary = composition.BoundaryId{ .value = 3 };
pub const host_partition = composition.PartitionId{ .value = 10 };
pub const accy_partition = composition.PartitionId{ .value = 11 };
pub const host_fragment = composition.FragmentId{ .value = 20 };
pub const accy_fragment = composition.FragmentId{ .value = 21 };
pub const add_call_site = composition.CallSiteId{ .value = 30 };
pub const composition_variant = composition.CompositionVariantId{ .value = 40 };
pub const source_path = "validation/hybrid_composition.tiny";
pub const host_symbol = "hybrid_composition_host_entry";
pub const accy_symbol = "hybrid_accy_add";
pub const accy_export_name = "add";
pub const module_name = "hybrid_composition";

pub const TensorType = struct {
    element: composition.ElementType,
    length: u32,

    pub fn byteSize(self: TensorType) u64 {
        return std.math.mul(u64, self.element.byteSize(), self.length) catch unreachable;
    }
};

pub const AddExpression = struct {
    symbol: []const u8,
    tensor: TensorType,
    lhs: composition.BoundaryId,
    rhs: composition.BoundaryId,
    output: composition.BoundaryId,
    call_site: composition.CallSiteId,
};

pub const AccyInput = struct {
    module: *accy.choir.SemanticModule,
};

pub const Program = struct {
    partitioned: composition.PartitionedModule,
    add: AddExpression,

    pub fn init(allocator: Allocator) !Program {
        const add = AddExpression{
            .symbol = accy_symbol,
            .tensor = .{ .element = .f32, .length = 8 },
            .lhs = lhs_boundary,
            .rhs = rhs_boundary,
            .output = output_boundary,
            .call_site = add_call_site,
        };
        const dimensions = [_]u64{add.tensor.length};
        var partitioned = try composition.PartitionedModule.init(allocator, module_name);
        errdefer partitioned.deinit();
        try partitioned.addBoundary(.{
            .id = add.lhs,
            .name = "lhs",
            .element_type = add.tensor.element,
            .dimensions = &dimensions,
            .byte_size = add.tensor.byteSize(),
            .access = .read,
            .ownership = .borrowed,
            .alias = .disjoint,
            .provenance = .{ .path = source_path, .symbol = "lhs", .line = 2, .column = 9 },
        });
        try partitioned.addBoundary(.{
            .id = add.rhs,
            .name = "rhs",
            .element_type = add.tensor.element,
            .dimensions = &dimensions,
            .byte_size = add.tensor.byteSize(),
            .access = .read,
            .ownership = .borrowed,
            .alias = .disjoint,
            .provenance = .{ .path = source_path, .symbol = "rhs", .line = 2, .column = 14 },
        });
        try partitioned.addBoundary(.{
            .id = add.output,
            .name = "sum",
            .element_type = add.tensor.element,
            .dimensions = &dimensions,
            .byte_size = add.tensor.byteSize(),
            .access = .write,
            .ownership = .produced,
            .alias = .disjoint,
            .provenance = .{ .path = source_path, .symbol = "sum", .line = 2, .column = 5 },
        });
        try partitioned.addPartition(.{
            .id = host_partition,
            .name = "hybrid/host",
            .pipeline = .choir,
            .inputs = &.{ add.lhs, add.rhs },
            .outputs = &.{add.output},
            .product = hostProductRef(),
            .effect = .none,
            .provenance = .{
                .path = source_path,
                .symbol = host_symbol,
                .line = 1,
                .column = 1,
            },
        });
        try partitioned.addPartition(.{
            .id = accy_partition,
            .name = "hybrid/add",
            .pipeline = .accy,
            .inputs = &.{ add.lhs, add.rhs },
            .outputs = &.{add.output},
            .product = accyProductRef(),
            .effect = .none,
            .provenance = .{
                .path = source_path,
                .symbol = add.symbol,
                .line = 2,
                .column = 5,
            },
        });
        try partitioned.addCallSite(.{
            .id = add.call_site,
            .name = "hybrid/add",
            .caller = host_partition,
            .callee = accy_partition,
            .inputs = &.{ add.lhs, add.rhs },
            .outputs = &.{add.output},
            .provenance = .{
                .path = source_path,
                .symbol = add.symbol,
                .line = 2,
                .column = 5,
            },
        });
        const program = Program{ .partitioned = partitioned, .add = add };
        try program.verify();
        return program;
    }

    pub fn deinit(self: *Program) void {
        self.partitioned.deinit();
        self.* = undefined;
    }

    pub fn verify(self: *const Program) !void {
        try self.partitioned.verify();
        const call_site = self.partitioned.callSite(self.add.call_site) orelse return error.MissingCallSite;
        if (call_site.caller.value != host_partition.value or call_site.callee.value != accy_partition.value) return error.InvalidSourceProgram;
        const expected_inputs = [_]composition.BoundaryId{ self.add.lhs, self.add.rhs };
        const expected_outputs = [_]composition.BoundaryId{self.add.output};
        if (!composition.source.boundaryIdsEqual(call_site.inputs, &expected_inputs)) return error.InvalidSourceProgram;
        if (!composition.source.boundaryIdsEqual(call_site.outputs, &expected_outputs)) return error.InvalidSourceProgram;
        for ([_]composition.BoundaryId{ self.add.lhs, self.add.rhs, self.add.output }) |id| {
            const boundary = self.partitioned.boundary(id) orelse return error.MissingBoundary;
            if (boundary.byte_size != self.add.tensor.byteSize()) return error.BoundaryContractMismatch;
            if (boundary.element_type != self.add.tensor.element) return error.BoundaryContractMismatch;
            const dimensions = [_]u64{self.add.tensor.length};
            if (!std.mem.eql(u64, boundary.dimensions, &dimensions)) return error.BoundaryContractMismatch;
        }
    }

    pub fn hostInput(self: *const Program, product: choir.product.ProductKey) !composition.PipelineInput {
        try self.verify();
        return try composition.PipelineInput.init(&self.partitioned, host_partition, .choir, product);
    }

    pub fn lowerAccy(self: *const Program, allocator: Allocator) !AccyInput {
        try self.verify();
        var builder = try accy.choir.SemanticBuilder.init(allocator, accy.choir.SemanticBuilder.ContextLimits.standard);
        errdefer builder.deinit();
        const dims = [_]i64{@intCast(self.add.tensor.length)};
        const tensor_type = try builder.tensor(accy.executable.composition.dtype(self.add.tensor.element), &dims);
        var function = try builder.beginFunction(
            self.add.symbol,
            &.{ tensor_type, tensor_type },
            &.{tensor_type},
        );
        const sum = try function.add(function.parameter(0), function.parameter(1));
        try function.return_(&.{sum});
        try function.finish();
        const module = try builder.finish();
        errdefer module.deinit();
        return .{
            .module = module,
        };
    }

    pub fn accyInput(self: *const Program, input: choir.product.ProductKey) !composition.PipelineInput {
        try self.verify();
        return try composition.PipelineInput.init(&self.partitioned, accy_partition, .accy, input);
    }

    pub fn cpuTargetChoice(self: *const Program) composition.TargetChoiceSpec {
        _ = self;
        return .{
            .target = choir.product.productRef("validation", source_path, "cpu-target", "x86_64"),
            .policy = choir.product.productRef("validation", source_path, "selection", "native"),
        };
    }
};

pub fn hostProductRef() choir.product.ProductRef {
    return choir.product.productRef("choir", source_path, "host.input", "");
}

pub fn accyProductRef() choir.product.ProductRef {
    return choir.product.productRef("accy", source_path, accy.choir.semantic_product_name, "");
}

test "one source program derives both partition contracts and Accy input" {
    var program = try Program.init(std.testing.allocator);
    defer program.deinit();
    const lowered = try program.lowerAccy(std.testing.allocator);
    defer lowered.module.deinit();
    try lowered.module.verify();
    try std.testing.expectEqual(program.add.tensor.byteSize(), program.partitioned.boundary(output_boundary).?.byte_size);
    program.add.tensor.length = 7;
    try std.testing.expectError(error.BoundaryContractMismatch, program.verify());
}

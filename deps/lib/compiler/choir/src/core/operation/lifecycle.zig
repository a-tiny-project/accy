const std = @import("std");
const core = @import("../root.zig");
const context_mod = @import("../context/root.zig");
const Context = context_mod.Context;
const Value = core.Value;
const OpOperand = core.OpOperand;
const Block = core.Block;
const Region = core.Region;
const Mapping = core.Mapping;
const cfg = core.cfg;
const operation_storage = @import("storage.zig");

pub fn Methods(comptime Operation: type) type {
    return struct {
        const State: type = Operation.State;
        const CloneOptions: type = Operation.CloneOptions;
        const StoragePlan = Operation.StoragePlan;
        const OperandStorage = operation_storage.Pair(*Value, OpOperand);

        pub fn create(context: *Context, state: State) !*Operation {
            // Direct construction keeps its existing low-level loading policy,
            // while resolving metadata against the destination registry.
            return createWithRegistration(
                context,
                state,
                context.lookupOperationName(state.name, state.static_name),
            );
        }

        /// Consume a registration resolved by the Context in this call. The
        /// nullable result is authoritative, including an admitted unknown name.
        pub fn createWithRegistration(
            context: *Context,
            state: State,
            registered_info: ?*const core.interfaces.OperationInfo,
        ) !*Operation {
            if (state.properties_attr != null and state.properties_ref != null) {
                return error.DuplicateOperationPropertiesPayload;
            }

            const allocator = context_mod.operationAllocator(context);
            const storage_allocator = context_mod.fixedOperationAllocator(context);

            const total_regions = std.math.add(
                usize,
                state.num_regions,
                state.region_bodies.len,
            ) catch return error.CapacityOverflow;
            const properties_model = if (registered_info) |info| info.getPropertiesModel() else null;
            const storage_limits = StoragePlan.Limits{
                .operands = state.operands.len,
                .results = state.result_types.len,
                .regions = total_regions,
                .successors = state.successors.len,
                .properties = if (properties_model) |model| model.size else 0,
                .properties_alignment = if (properties_model) |model| model.alignment else .@"1",
            };
            var allocation = try StoragePlan.init(storage_allocator, storage_limits);
            const regions = allocation.regions;
            const op = regions.header;
            var op_initialized = false;
            errdefer if (op_initialized) {
                destroy(op);
            } else {
                allocation.storage.deinit(storage_allocator);
            };

            @memcpy(regions.operand_values, state.operands);
            @memcpy(regions.result_types, state.result_types);

            op.* = Operation{
                .allocator = allocator,
                .storage = allocation.storage,
                .operand_storage = null,
                .lifecycle_state = .{
                    .creation_id = 0,
                    .successor_storage_owned = false,
                },
                .context = context,
                .name = nameWithRegistration(state.name, registered_info),
                .location = state.location,
                .operands = operation_storage.List(OpOperand).init(regions.operands),
                .operand_values = regions.operand_values,
                .results = operation_storage.List(Value).init(regions.results),
                .result_types = regions.result_types,
                .raw_dictionary_attrs = .{},
                .properties = .{},
                .regions = operation_storage.List(Region).init(regions.regions),
                .successors = operation_storage.List(*Block).init(regions.successors),
                .parent_block = null,
                .prev_op = null,
                .next_op = null,
                .order = 0,
                .tracking_prev = null,
                .tracking_next = null,
            };
            op_initialized = true;

            if (properties_model) |model| {
                try op.properties.init(allocator, model, regions.properties);
            }

            for (state.operands, 0..) |operand, i| {
                op.operands.appendAssumeCapacity(.{
                    .value = operand,
                    .owner = op,
                    .operand_number = @intCast(i),
                    .operand_value_slot = &op.operand_values[i],
                    .next_use = null,
                });
                op.operands.items[i].attach();
            }

            for (state.result_types, 0..) |result_type, i| {
                const result = Value{
                    .kind = .{ .op_result = .{
                        .owner = op,
                        .result_number = @intCast(i),
                    } },
                    .type = result_type,
                    .id = 0,
                };
                op.results.appendAssumeCapacity(result);
            }

            for (state.attributes) |attr| {
                try op.setAttr(attr.name, attr.value);
            }

            for (state.raw_attributes) |attr| {
                _ = try op.raw_dictionary_attrs.set(allocator, attr.name, attr.value);
            }

            for (0..state.num_regions) |_| {
                var region = Region.init(allocator);
                region.parent = @ptrCast(op);
                op.regions.appendAssumeCapacity(region);
            }

            for (state.region_bodies) |body| {
                var region = Region.init(allocator);
                region.parent = @ptrCast(op);
                op.regions.appendAssumeCapacity(region);
                try op.regions.items[op.regions.items.len - 1].takeBody(body);
            }

            op.successors.appendSliceAssumeCapacity(state.successors);

            if (state.properties_ref) |properties| {
                try op.copyProperties(properties);
            }

            if (state.properties_attr) |attr| {
                try op.setPropertiesFromAttr(attr);
            }

            op.storage.activate();
            return op;
        }

        /// The name an operation keeps. A registered operation points at the
        /// registry's bytes, which outlive whatever string the caller passed.
        fn nameWithRegistration(
            name: Operation.OperationName,
            info: ?*const core.interfaces.OperationInfo,
        ) Operation.OperationName {
            var resolved = name;
            resolved.registered_info = info;
            if (info) |registered| resolved.name = registered.name;
            return resolved;
        }

        pub fn cloneWithoutRegions(self: *const Operation) !*Operation {
            var mapping = Mapping.init(self.allocator);
            defer mapping.deinit();
            return try cloneWithoutRegionsMapped(self, &mapping, .{});
        }

        pub fn cloneWithoutRegionsMapped(
            self: *const Operation,
            mapping: *Mapping,
            options: CloneOptions,
        ) !*Operation {
            var state = try State.initFromOperationHeader(self);

            var remapped_operands: []*Value = &.{};
            defer if (remapped_operands.len > 0) self.allocator.free(remapped_operands);
            if (options.clone_operands) {
                if (self.operand_values.len > 0) {
                    remapped_operands = try self.allocator.alloc(*Value, self.operand_values.len);
                    for (self.operand_values, 0..) |operand, i| {
                        remapped_operands[i] = mapping.lookupOrDefaultValue(operand);
                    }
                    state.addOperands(remapped_operands);
                }
            } else {
                state.addOperands(&.{});
            }

            var remapped_successors: []*Block = &.{};
            defer if (remapped_successors.len > 0) self.allocator.free(remapped_successors);
            if (self.successors.items.len > 0) {
                remapped_successors = try self.allocator.alloc(*Block, self.successors.items.len);
                for (self.successors.items, 0..) |successor, i| {
                    remapped_successors[i] = mapping.lookupOrDefaultBlock(successor);
                }
                state.addSuccessors(remapped_successors);
            }

            const clone_op = try self.context.createOperation(state);
            errdefer erase(clone_op);

            try mapping.mapOperation(self, clone_op);

            for (self.results.items, 0..) |*result, i| {
                try mapping.mapValue(result, clone_op.getResult(i).?);
            }

            return clone_op;
        }

        pub fn clone(self: *const Operation) !*Operation {
            var mapping = Mapping.init(self.allocator);
            defer mapping.deinit();

            const clone_op = try cloneWithoutRegionsMapped(self, &mapping, .{});
            errdefer erase(clone_op);

            for (self.regions.items, 0..) |*region, i| {
                try region.cloneInto(&clone_op.regions.items[i], &mapping);
            }

            return clone_op;
        }

        pub fn dropAllReferences(self: *Operation) void {
            dropAllOperandReferences(self);
            dropAllSuccessorReferences(self);
            for (self.regions.items) |*region| {
                region.dropAllReferences();
            }
        }

        fn dropAllOperandReferences(self: *Operation) void {
            for (self.operands.items) |*operand| {
                operand.detach();
            }
        }

        fn dropAllSuccessorReferences(self: *Operation) void {
            if (self.parent_block) |pred| {
                cfg.detach(pred, self);
            }
            self.successors.clearRetainingCapacity();
        }

        pub fn hasNoDefinedValueUses(self: *Operation) bool {
            if (!self.hasNoUses()) return false;
            for (self.regions.items) |*region| {
                if (!region.hasNoDefinedValueUses()) return false;
            }
            return true;
        }

        pub fn dropAllDefinedValueUses(self: *Operation) void {
            for (self.results.items) |*result| {
                result.dropAllUses();
            }
            for (self.regions.items) |*region| {
                region.dropAllDefinedValueUses();
            }
        }

        pub fn removeFromBlock(self: *Operation) void {
            const block = self.parent_block orelse return;
            block.detachOperation(self);
        }

        pub fn moveBefore(self: *Operation, before: *Operation) !void {
            if (self == before) return;
            if (self.parent_block == null) return error.OperationMoveDetached;
            const block = before.parent_block orelse return error.OperationInsertBeforeDetached;
            try cfg.prepare(block, self.successors.items);
            removeFromBlock(self);
            try block.insertBefore(self, before);
        }

        pub fn moveToEnd(self: *Operation, block: *Block) !void {
            if (self.parent_block == block and self.next_op == null) return;
            if (self.parent_block == null) return error.OperationMoveDetached;
            try cfg.prepare(block, self.successors.items);
            removeFromBlock(self);
            try block.addOperation(self);
        }

        pub fn replaceOperands(self: *Operation, operands: []const *Value) !void {
            var replacement: ?OperandStorage.Allocation = null;
            if (operands.len > self.operands.capacity) {
                replacement = try OperandStorage.init(self.allocator, operands.len);
            }

            const previous_storage = self.operand_storage;
            dropAllOperandReferences(self);
            if (replacement) |next| {
                self.operand_storage = next.handle;
                self.operand_values = next.first;
                self.operands = operation_storage.List(OpOperand).init(next.second);
            } else {
                self.operand_values = self.operand_values.ptr[0..operands.len];
                self.operands.items = self.operands.items.ptr[0..0];
            }
            std.mem.copyForwards(*Value, self.operand_values, operands);
            for (operands, 0..) |operand, i| {
                self.operands.appendAssumeCapacity(.{
                    .value = operand,
                    .owner = self,
                    .operand_number = @intCast(i),
                    .operand_value_slot = &self.operand_values[i],
                    .next_use = null,
                });
                self.operands.items[i].attach();
            }
            if (replacement != null) {
                if (previous_storage) |handle| {
                    var previous = handle;
                    previous.deinit(self.allocator);
                }
            }
        }

        pub fn deinit(self: *Operation) void {
            std.debug.assert(self.hasNoUses());
            dropAllOperandReferences(self);
            dropAllSuccessorReferences(self);
            if (self.operand_storage) |handle| {
                var storage = handle;
                storage.deinit(self.allocator);
                self.operand_storage = null;
            }
            self.properties.deinit(self.allocator);
            self.raw_dictionary_attrs.deinit(self.allocator);
            for (self.regions.items) |*region| {
                region.deinit();
            }
            if (self.lifecycle_state.successor_storage_owned) {
                self.allocator.free(self.successors.items.ptr[0..self.successors.capacity]);
                self.lifecycle_state.successor_storage_owned = false;
            }
        }

        pub fn destroy(self: *Operation) void {
            const storage_allocator = context_mod.fixedOperationAllocator(self.context);
            var storage = self.storage;
            deinit(self);
            storage.deinit(storage_allocator);
        }

        pub fn setOperandValue(self: *Operation, index: usize, new_value: *Value) void {
            if (index >= self.operands.items.len) return;
            const operand = &self.operands.items[index];
            if (operand.value == new_value) return;
            operand.detach();
            operand.value = new_value;
            operand.attach();
            if (index < self.operand_values.len) {
                self.operand_values[index] = new_value;
            }
        }

        pub fn setSuccessors(self: *Operation, successors: []const *Block) !void {
            var owned_successors: ?[]*Block = null;
            defer if (owned_successors) |owned| self.allocator.free(owned);
            const aliases_predecessors = successorsAliasPredecessors(
                self,
                successors,
            );
            const stable_successors: []const *Block = if (aliases_predecessors) stable: {
                const owned = try self.allocator.dupe(*Block, successors);
                owned_successors = owned;
                break :stable owned;
            } else successors;

            try ensureSuccessorCapacity(self, stable_successors.len);
            if (self.parent_block) |pred| {
                try cfg.prepare(pred, stable_successors);
                cfg.detachReplaced(pred, self, stable_successors);
            }

            const next = self.successors.items.ptr[0..stable_successors.len];
            std.mem.copyForwards(*Block, next, stable_successors);
            self.successors.items = next;

            if (self.parent_block) |pred| {
                cfg.attachAssumeCapacity(pred, self.successors.items);
            }
        }

        fn successorsAliasPredecessors(
            self: *const Operation,
            successors: []const *Block,
        ) bool {
            for (self.successors.items) |target| {
                if (blockPointerSlicesOverlap(
                    successors,
                    target.predecessors.items,
                )) return true;
            }
            for (successors) |target| {
                if (blockPointerSlicesOverlap(
                    successors,
                    target.predecessors.items,
                )) return true;
            }
            return false;
        }

        fn blockPointerSlicesOverlap(
            left: []const *Block,
            right: []const *Block,
        ) bool {
            if (left.len == 0 or right.len == 0) return false;
            const element_size = @sizeOf(*Block);
            const left_size = std.math.mul(
                usize,
                left.len,
                element_size,
            ) catch return true;
            const right_size = std.math.mul(
                usize,
                right.len,
                element_size,
            ) catch return true;
            const left_start = @intFromPtr(left.ptr);
            const right_start = @intFromPtr(right.ptr);
            const left_end = std.math.add(
                usize,
                left_start,
                left_size,
            ) catch return true;
            const right_end = std.math.add(
                usize,
                right_start,
                right_size,
            ) catch return true;
            return left_start < right_end and right_start < left_end;
        }

        fn ensureSuccessorCapacity(self: *Operation, required: usize) !void {
            if (required <= self.successors.capacity) return;
            const storage = try self.allocator.alloc(*Block, required);
            const previous_items = self.successors.items;
            const previous_capacity = self.successors.capacity;
            const previous_owned = self.lifecycle_state.successor_storage_owned;
            @memcpy(storage[0..previous_items.len], previous_items);
            self.successors = .{
                .items = storage[0..previous_items.len],
                .capacity = storage.len,
            };
            self.lifecycle_state.successor_storage_owned = true;
            if (previous_owned) self.allocator.free(previous_items.ptr[0..previous_capacity]);
        }

        pub fn erase(self: *Operation) void {
            destroyNestedOperations(self);
            self.context.untrackOperation(self);
            removeFromBlock(self);
            destroy(self);
        }

        fn destroyNestedOperations(self: *Operation) void {
            for (self.regions.items) |*region| {
                var block = region.blocks.tail;
                while (block) |current_block| {
                    const prev_block = current_block.prev;
                    var current: ?*Operation = @ptrCast(@alignCast(current_block.operations.tail));
                    while (current) |nested_op| {
                        const prev = nested_op.prev_op;
                        destroyNestedOperations(nested_op);
                        nested_op.context.untrackOperation(nested_op);
                        removeFromBlock(nested_op);
                        destroy(nested_op);
                        current = prev;
                    }
                    block = prev_block;
                }
            }
        }
    };
}

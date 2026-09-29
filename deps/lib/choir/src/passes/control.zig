const std = @import("std");
const alloc_phase = @import("alloc_phase");
const ir = @import("../core/root.zig");
const pass = @import("pass/root.zig");

pub const cfg_analysis_name = "choir-control-flow-graph";
pub const dominance_analysis_name = "choir-dominance";
pub const post_dominance_analysis_name = "choir-post-dominance";

const control_storage_alignment = @max(@alignOf(usize), @alignOf(*ir.Block));

const RegionControlFlowFacts = struct {
    block_count: usize,
    edge_count: usize,
};

const RegionControlFlowLimits = struct {
    region: *ir.Region,
    facts: RegionControlFlowFacts,

    pub fn inspect(region: *ir.Region) !RegionControlFlowLimits {
        var block_count: usize = 0;
        var edge_count: usize = 0;
        var iter = region.getBlocks();
        while (iter.next()) |block| {
            block_count = std.math.add(usize, block_count, 1) catch
                return error.CapacityOverflow;
            edge_count = std.math.add(
                usize,
                edge_count,
                try countRegionSuccessors(block, region),
            ) catch return error.CapacityOverflow;
        }
        if (block_count != region.blocks.size) return error.RegionChanged;
        return .{
            .region = region,
            .facts = .{
                .block_count = block_count,
                .edge_count = edge_count,
            },
        };
    }
};

const RegionControlFlowCapacity = struct {
    working_bytes: usize,

    pub fn derive(limits: RegionControlFlowLimits) !RegionControlFlowCapacity {
        const layout = try RegionControlFlowLayout.derive(limits.facts);
        return .{ .working_bytes = layout.working_bytes };
    }
};

const RegionControlFlowLayout = struct {
    facts: RegionControlFlowFacts,
    block_offset: usize,
    successor_offset: usize,
    predecessor_offset: usize,
    cursor_offset: usize,
    working_bytes: usize,

    fn derive(facts: RegionControlFlowFacts) !RegionControlFlowLayout {
        if (facts.block_count <= 1) return .{
            .facts = facts,
            .block_offset = 0,
            .successor_offset = 0,
            .predecessor_offset = 0,
            .cursor_offset = 0,
            .working_bytes = 0,
        };
        var cursor: usize = 0;
        const block_offset = try placeControlStorage(
            try controlStorageBytes(RegionControlFlow.BlockInfo, facts.block_count),
            @alignOf(RegionControlFlow.BlockInfo),
            &cursor,
        );
        const successor_offset = try placeControlStorage(
            try controlStorageBytes(*ir.Block, facts.edge_count),
            @alignOf(*ir.Block),
            &cursor,
        );
        const predecessor_offset = try placeControlStorage(
            try controlStorageBytes(*ir.Block, facts.edge_count),
            @alignOf(*ir.Block),
            &cursor,
        );
        const cursor_offset = try placeControlStorage(
            try controlStorageBytes(usize, facts.block_count),
            @alignOf(usize),
            &cursor,
        );
        return .{
            .facts = facts,
            .block_offset = block_offset,
            .successor_offset = successor_offset,
            .predecessor_offset = predecessor_offset,
            .cursor_offset = cursor_offset,
            .working_bytes = cursor,
        };
    }
};

pub const RegionControlFlow = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.region_control_flow",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "sorted_block_records_and_retained_successor_and_pre_0939f1a2ec2f",
                        .lifetime = .steady,
                        .detail = "sorted block records and retained successor and predecessor edges",
                    },
                    .{
                        .id = "predecessor_construction_cursors_colocated_with_retained_records",
                        .lifetime = .initialization,
                        .detail = "predecessor construction cursors colocated with retained records",
                    },
                    .{
                        .id = "inline_empty_and_singleton_region_representation",
                        .lifetime = .steady,
                        .detail = "inline empty and singleton region representation",
                    },
                },
                .excluded = &.{
                    "enclosing analysis maps, order lists, and region owner objects",
                    "borrowed IR and control-flow interface callback state",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "facts_block_count", "facts.block_count"),
                    alloc_phase.capacity.bindInput(Limits, "facts_edge_count", "facts.edge_count"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(RegionControlFlow.BlockInfo, "blockrecord"),
                    alloc_phase.capacity.bindType(*ir.Block, "block"),
                    alloc_phase.capacity.bindType(usize, "usize"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .constant = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 3, .coefficient = .{ .literal = 2 } } },
                    .{ .scale = .{ .node = 4, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 2 } } },
                    .{ .add = .{ .left = 2, .right = 5 } },
                    .{ .add = .{ .left = 7, .right = 6 } },
                    .{ .constant = 1 },
                    .{ .alignment = .{ .node = 8, .alignment = .{ .literal = 16 } } },
                    .{ .conditional = .{ .predicate = .{ .comparison = .less_or_equal, .left = 0, .right = 9 }, .when_true = 1, .when_false = 10 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 11,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "incompatible graph cardinality, count arithmetic, capacity arithmetic, or OOM rejects before an active control-flow owner is published",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "activated lookup and edge queries use only sealed records and borrowed block pointers",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "control-flow interface callbacks are confined to initialization and steady queries cross no foreign boundary",
                },
            },
            .obligations = &.{
                .{ .key = "choir_region_cfg_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "choir_region_cfg_capacity_overload", .role = .overload },
                .{ .key = "choir_region_cfg_acquisition", .role = .custom },
                .{ .key = "choir_region_cfg_sealed_transitive_risk", .role = .transitive_risk },
                .{ .key = "choir_region_cfg_sealed_foreign_risk", .role = .foreign_risk },
                .{ .key = "choir_region_cfg_oom", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: alloc_phase.capacity.Phase,
    capacity: RegionControlFlowCapacity,
    region: *ir.Region,
    storage: Storage,

    pub const BlockInfo = struct {
        block: *ir.Block,
        successors: []const *ir.Block,
        predecessors: []const *ir.Block,
    };

    const Single = struct {
        info: BlockInfo,
    };

    const Multiple = struct {
        bytes: []align(control_storage_alignment) u8,
        blocks: []BlockInfo,
    };

    const Storage = union(enum) {
        empty,
        single: Single,
        multiple: Multiple,
    };

    pub const Limits = RegionControlFlowLimits;
    pub const Capacity = RegionControlFlowCapacity;

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !RegionControlFlow {
        const capacity = try Capacity.derive(limits);
        var owner: RegionControlFlow = .{
            .phase = .initialization,
            .capacity = capacity,
            .region = limits.region,
            .storage = .empty,
        };
        if (limits.facts.block_count == 0) {
            if (limits.region.blocks.size != 0) return error.RegionChanged;
            return owner;
        }
        if (limits.facts.block_count == 1) {
            try owner.initSingle(limits.facts.edge_count);
            return owner;
        }
        try initializeRegionControlFlowMultiple(&owner, allocator, limits);
        return owner;
    }

    pub fn initForRegion(
        allocator: std.mem.Allocator,
        region: *ir.Region,
    ) !RegionControlFlow {
        return init(allocator, try Limits.inspect(region));
    }

    pub fn activate(self: *RegionControlFlow) !void {
        if (self.phase != .initialization) return error.AlreadyActive;
        self.phase = .steady;
    }

    pub fn deinit(self: *RegionControlFlow, allocator: std.mem.Allocator) void {
        if (self.phase == .teardown) @panic("control-flow teardown is terminal");
        if (self.storage == .multiple) allocator.free(self.storage.multiple.bytes);
        self.phase = .teardown;
        self.storage = undefined;
    }

    pub fn blockCount(self: *const RegionControlFlow) usize {
        return self.blockInfos().len;
    }

    pub fn entryBlock(self: *const RegionControlFlow) ?*ir.Block {
        self.requireSteady();
        return self.region.getEntryBlock();
    }

    pub fn indexOf(self: *const RegionControlFlow, block: *ir.Block) ?usize {
        const blocks = self.blockInfos();
        std.debug.assert(blockInfosOrdered(blocks));
        return indexOfBlockInfo(blocks, block);
    }

    pub fn blockInfo(self: *const RegionControlFlow, block: *ir.Block) ?*const BlockInfo {
        const blocks = self.blockInfos();
        const index = indexOfBlockInfo(blocks, block) orelse return null;
        return &blocks[index];
    }

    pub fn successors(self: *const RegionControlFlow, block: *ir.Block) ?[]const *ir.Block {
        const info = self.blockInfo(block) orelse return null;
        return info.successors;
    }

    pub fn predecessors(self: *const RegionControlFlow, block: *ir.Block) ?[]const *ir.Block {
        const info = self.blockInfo(block) orelse return null;
        return info.predecessors;
    }

    pub fn hasEdge(self: *const RegionControlFlow, from: *ir.Block, to: *ir.Block) bool {
        const succs = self.successors(from) orelse return false;
        for (succs) |succ| {
            if (succ == to) return true;
        }
        return false;
    }

    fn initSingle(self: *RegionControlFlow, expected_edge_count: usize) !void {
        var iter = self.region.getBlocks();
        const block = iter.next() orelse return error.RegionChanged;
        if (iter.next() != null) return error.RegionChanged;
        self.storage = .{ .single = undefined };
        const single = &self.storage.single;
        single.info = .{
            .block = block,
            .successors = &.{},
            .predecessors = &.{},
        };
        const edge = @as(*[1]*ir.Block, @ptrCast(&single.info.block))[0..];
        const successor_count = try writeRegionSuccessors(
            block,
            self.region,
            edge,
        );
        if (successor_count != expected_edge_count) return error.RegionChanged;
        single.info.successors = edge[0..successor_count];
        single.info.predecessors = edge[0..successor_count];
    }

    fn blockInfos(self: *const RegionControlFlow) []const BlockInfo {
        self.requireSteady();
        return switch (self.storage) {
            .empty => &.{},
            .single => |*single| @as(
                *const [1]BlockInfo,
                @ptrCast(&single.info),
            )[0..],
            .multiple => |multiple| multiple.blocks,
        };
    }

    fn requireSteady(self: *const RegionControlFlow) void {
        if (self.phase != .steady) {
            @panic("control-flow region used outside its steady phase");
        }
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(RegionControlFlow);
}

const control_flow_graph_gather_capacity: usize = 16;

const ControlFlowGraphSurvey = struct {
    root: *ir.Operation,
    region_count: usize,
    gathered: [control_flow_graph_gather_capacity]*ir.Region,

    fn inspect(root: *ir.Operation) !ControlFlowGraphSurvey {
        var survey = ControlFlowGraphSurvey{
            .root = root,
            .region_count = 0,
            .gathered = undefined,
        };
        try inspectControlFlowGraphOperation(root, &survey);
        return survey;
    }

    fn limits(self: *const ControlFlowGraphSurvey) ControlFlowGraphLimits {
        return .{
            .root = self.root,
            .region_count = self.region_count,
        };
    }

    fn gatheredRegions(
        self: *const ControlFlowGraphSurvey,
    ) ?[]const *ir.Region {
        if (self.region_count > self.gathered.len) return null;
        return self.gathered[0..self.region_count];
    }
};

const ControlFlowGraphLimits = struct {
    root: *ir.Operation,
    region_count: usize,

    pub fn inspect(root: *ir.Operation) !ControlFlowGraphLimits {
        const survey = try ControlFlowGraphSurvey.inspect(root);
        return survey.limits();
    }
};

const ControlFlowGraphCapacity = struct {
    region_count: usize,
    storage_bytes: usize,

    pub fn derive(limits: ControlFlowGraphLimits) !ControlFlowGraphCapacity {
        return .{
            .region_count = limits.region_count,
            .storage_bytes = std.math.mul(
                usize,
                limits.region_count,
                @sizeOf(RegionControlFlow),
            ) catch return error.CapacityOverflow,
        };
    }
};

pub const ControlFlowGraphAnalysis = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.control_flow_graph_analysis",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "pointer_sorted_stable_in_place_region_control_flow_owners",
                        .lifetime = .steady,
                        .detail = "pointer-sorted stable in-place region control-flow owners",
                    },
                },
                .excluded = &.{
                    "per-region control-flow backing owned by RegionControlFlow",
                    "borrowed operation tree, IR storage, and control-flow callbacks",
                    "analysis cache records and the separately allocated analysis object",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "region_count", "region_count"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(RegionControlFlow, "regioncontrolflow"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 1,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "region count arithmetic, capacity arithmetic, operation-tree changes, duplicate region ownership, child construction, or OOM rejects before an active analysis is published",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "activated lookup and edge queries use only the sorted owner array and sealed RegionControlFlow children",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "control-flow callbacks are confined to child initialization and steady queries cross no foreign boundary",
                },
            },
            .obligations = &.{
                .{ .key = "choir_cfg_analysis_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "choir_cfg_analysis_capacity_overload", .role = .overload },
                .{ .key = "choir_cfg_analysis_acquisition", .role = .custom },
                .{ .key = "choir_cfg_analysis_sealed_transitive_risk", .role = .transitive_risk },
                .{ .key = "choir_cfg_analysis_sealed_foreign_risk", .role = .foreign_risk },
                .{ .key = "choir_cfg_analysis_oom", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: alloc_phase.capacity.Phase,
    capacity: ControlFlowGraphCapacity,
    regions: []RegionControlFlow,

    pub const Limits: type = ControlFlowGraphLimits;
    pub const Capacity: type = ControlFlowGraphCapacity;

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !ControlFlowGraphAnalysis {
        const capacity = try Capacity.derive(limits);
        const regions = try allocator.alloc(
            RegionControlFlow,
            capacity.region_count,
        );

        var filled: usize = 0;
        fillControlFlowGraphOperation(
            limits.root,
            regions,
            &filled,
        ) catch |err| {
            allocator.free(regions);
            return err;
        };
        if (filled != capacity.region_count) {
            allocator.free(regions);
            return error.OperationChanged;
        }
        return finishInitialization(allocator, capacity, regions);
    }

    pub fn initForOperation(
        allocator: std.mem.Allocator,
        root: *ir.Operation,
    ) !ControlFlowGraphAnalysis {
        const survey = try ControlFlowGraphSurvey.inspect(root);
        const gathered = survey.gatheredRegions() orelse {
            return init(allocator, survey.limits());
        };
        const capacity = try Capacity.derive(survey.limits());
        const regions = try allocator.alloc(
            RegionControlFlow,
            capacity.region_count,
        );
        for (regions, gathered) |*region_cfg, region| {
            region_cfg.* = undefined;
            region_cfg.region = region;
        }
        return finishInitialization(allocator, capacity, regions);
    }

    fn finishInitialization(
        allocator: std.mem.Allocator,
        capacity: Capacity,
        regions: []RegionControlFlow,
    ) !ControlFlowGraphAnalysis {
        sortControlFlowRegionPointers(regions);
        if (!regionControlFlowsOrdered(regions)) {
            allocator.free(regions);
            return error.OperationChanged;
        }

        var initialized: usize = 0;
        errdefer {
            for (regions[0..initialized]) |*region_cfg| {
                region_cfg.deinit(allocator);
            }
            allocator.free(regions);
        }
        while (initialized < regions.len) {
            const region = regions[initialized].region;
            regions[initialized] = try RegionControlFlow.initForRegion(
                allocator,
                region,
            );
            regions[initialized].activate() catch |err| {
                regions[initialized].deinit(allocator);
                return err;
            };
            initialized += 1;
        }

        return .{
            .phase = .initialization,
            .capacity = capacity,
            .regions = regions,
        };
    }

    pub fn activate(self: *ControlFlowGraphAnalysis) !void {
        if (self.phase != .initialization) return error.AlreadyActive;
        self.phase = .steady;
    }

    pub fn deinit(
        self: *ControlFlowGraphAnalysis,
        allocator: std.mem.Allocator,
    ) void {
        if (self.phase == .teardown) {
            @panic("control-flow graph analysis teardown is terminal");
        }
        for (self.regions) |*region_cfg| {
            region_cfg.deinit(allocator);
        }
        allocator.free(self.regions);
        self.phase = .teardown;
        self.regions = undefined;
    }

    pub fn regionCount(self: *const ControlFlowGraphAnalysis) usize {
        self.requireSteady();
        return self.regions.len;
    }

    pub fn getRegion(
        self: *const ControlFlowGraphAnalysis,
        region: *ir.Region,
    ) ?*const RegionControlFlow {
        const index = self.indexOfRegion(region) orelse return null;
        return &self.regions[index];
    }

    pub fn getBlockRegion(
        self: *const ControlFlowGraphAnalysis,
        block: *ir.Block,
    ) ?*const RegionControlFlow {
        const region = block.getParentRegion() orelse return null;
        return self.getRegion(region);
    }

    pub fn successors(self: *const ControlFlowGraphAnalysis, block: *ir.Block) ?[]const *ir.Block {
        const region_cfg = self.getBlockRegion(block) orelse return null;
        return region_cfg.successors(block);
    }

    pub fn predecessors(
        self: *const ControlFlowGraphAnalysis,
        block: *ir.Block,
    ) ?[]const *ir.Block {
        const region_cfg = self.getBlockRegion(block) orelse return null;
        return region_cfg.predecessors(block);
    }

    fn regionSlice(self: *const ControlFlowGraphAnalysis) []const RegionControlFlow {
        self.requireSteady();
        return self.regions;
    }

    fn indexOfRegion(
        self: *const ControlFlowGraphAnalysis,
        region: *ir.Region,
    ) ?usize {
        self.requireSteady();
        std.debug.assert(regionControlFlowsOrdered(self.regions));
        const key = @intFromPtr(region);
        var low: usize = 0;
        var high = self.regions.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (@intFromPtr(self.regions[middle].region) < key) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == self.regions.len) return null;
        if (self.regions[low].region != region) return null;
        return low;
    }

    fn requireSteady(self: *const ControlFlowGraphAnalysis) void {
        if (self.phase != .steady) {
            @panic("control-flow graph analysis used outside its steady phase");
        }
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(ControlFlowGraphAnalysis);
}

pub const DominanceKind = enum {
    forward,
    reverse,
};

const BlockDominanceLimits = struct {
    cfg: *const ControlFlowGraphAnalysis,
    kind: DominanceKind,
    region_count: usize,

    pub fn inspect(
        cfg: *const ControlFlowGraphAnalysis,
        kind: DominanceKind,
    ) BlockDominanceLimits {
        return .{
            .cfg = cfg,
            .kind = kind,
            .region_count = cfg.regionCount(),
        };
    }
};

const BlockDominanceCapacity = struct {
    region_count: usize,
    storage_bytes: usize,

    pub fn derive(limits: BlockDominanceLimits) !BlockDominanceCapacity {
        return .{
            .region_count = limits.region_count,
            .storage_bytes = std.math.mul(
                usize,
                limits.region_count,
                @sizeOf(RegionDominance),
            ) catch return error.CapacityOverflow,
        };
    }
};

pub const BlockDominanceAnalysis = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.block_dominance_analysis",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "in_place_region_dominance_owners_aligned_with_the_s_d1cee8fda637",
                        .lifetime = .steady,
                        .detail = "in-place region dominance owners aligned with the sorted control-flow region index",
                    },
                },
                .excluded = &.{
                    "per-region relation backing owned by RegionDominance",
                    "control-flow graph borrowed only during construction and IR storage",
                    "analysis cache records and the separately allocated analysis object",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "region_count", "region_count"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(RegionDominance, "regiondominance"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 1,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "capacity arithmetic, incompatible control-flow cardinality, child construction, or OOM rejects before an active analysis is published",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "activated queries use only the sorted owner array and sealed RegionDominance children",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "dominance construction and steady lookup cross no operating-system or foreign callback boundary",
                },
            },
            .obligations = &.{
                .{ .key = "choir_block_dominance_analysis_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "choir_block_dominance_analysis_capacity_overload", .role = .overload },
                .{ .key = "choir_block_dominance_analysis_acquisition", .role = .custom },
                .{ .key = "choir_block_dominance_analysis_sealed_transitive_risk", .role = .transitive_risk },
                .{ .key = "choir_block_dominance_analysis_sealed_foreign_risk", .role = .foreign_risk },
                .{ .key = "choir_block_dominance_analysis_oom", .role = .overload },
                .{ .key = "choir_block_dominance_analysis_independent", .role = .transitive_risk },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: alloc_phase.capacity.Phase,
    capacity: BlockDominanceCapacity,
    regions: []RegionDominance,

    pub const Limits: type = BlockDominanceLimits;
    pub const Capacity: type = BlockDominanceCapacity;

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !BlockDominanceAnalysis {
        const capacity = try Capacity.derive(limits);
        const cfg_regions = limits.cfg.regionSlice();
        if (cfg_regions.len != capacity.region_count) {
            return error.ControlFlowChanged;
        }
        const regions = try allocator.alloc(
            RegionDominance,
            capacity.region_count,
        );
        errdefer allocator.free(regions);

        var initialized: usize = 0;
        errdefer for (regions[0..initialized]) |*region_dom| {
            region_dom.deinit(allocator);
        };
        while (initialized < regions.len) {
            regions[initialized] = try RegionDominance.initForRegion(
                allocator,
                &cfg_regions[initialized],
                limits.kind,
            );
            regions[initialized].activate() catch |err| {
                regions[initialized].deinit(allocator);
                return err;
            };
            initialized += 1;
        }
        if (!regionDominancesOrdered(regions)) {
            return error.ControlFlowChanged;
        }

        return .{
            .phase = .initialization,
            .capacity = capacity,
            .regions = regions,
        };
    }

    pub fn activate(self: *BlockDominanceAnalysis) !void {
        if (self.phase != .initialization) return error.AlreadyActive;
        self.phase = .steady;
    }

    pub fn deinit(
        self: *BlockDominanceAnalysis,
        allocator: std.mem.Allocator,
    ) void {
        if (self.phase == .teardown) {
            @panic("block dominance analysis teardown is terminal");
        }
        for (self.regions) |*region_dom| {
            region_dom.deinit(allocator);
        }
        allocator.free(self.regions);
        self.phase = .teardown;
        self.regions = undefined;
    }

    pub fn getRegion(
        self: *const BlockDominanceAnalysis,
        region: *ir.Region,
    ) ?*const RegionDominance {
        self.requireSteady();
        std.debug.assert(regionDominancesOrdered(self.regions));
        const key = @intFromPtr(region);
        var low: usize = 0;
        var high = self.regions.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (@intFromPtr(self.regions[middle].regionPointer()) < key) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == self.regions.len) return null;
        if (self.regions[low].regionPointer() != region) return null;
        return &self.regions[low];
    }

    pub fn dominatesBlock(
        self: *const BlockDominanceAnalysis,
        dominator: *ir.Block,
        block: *ir.Block,
    ) bool {
        const region = block.getParentRegion() orelse return false;
        if (dominator.getParentRegion() != region) return false;
        const region_dom = self.getRegion(region) orelse return false;
        return region_dom.contains(dominator, block);
    }

    pub fn postDominatesBlock(
        self: *const BlockDominanceAnalysis,
        postdominator: *ir.Block,
        block: *ir.Block,
    ) bool {
        return self.dominatesBlock(postdominator, block);
    }

    pub fn strictlyDominatesBlock(
        self: *const BlockDominanceAnalysis,
        dominator: *ir.Block,
        block: *ir.Block,
    ) bool {
        return dominator != block and self.dominatesBlock(dominator, block);
    }

    pub fn strictlyPostDominatesBlock(
        self: *const BlockDominanceAnalysis,
        postdominator: *ir.Block,
        block: *ir.Block,
    ) bool {
        return postdominator != block and self.postDominatesBlock(postdominator, block);
    }

    pub fn dominatesOperation(
        self: *const BlockDominanceAnalysis,
        dominator: *ir.Operation,
        op: *ir.Operation,
    ) bool {
        if (dominator == op) return true;
        const dominator_block = dominator.getBlock() orelse return false;
        const op_block = op.getBlock() orelse return false;
        if (dominator_block == op_block) return operationPrecedesOrSame(dominator, op);
        return self.dominatesBlock(dominator_block, op_block);
    }

    pub fn postDominatesOperation(
        self: *const BlockDominanceAnalysis,
        postdominator: *ir.Operation,
        op: *ir.Operation,
    ) bool {
        if (postdominator == op) return true;
        const postdominator_block = postdominator.getBlock() orelse return false;
        const op_block = op.getBlock() orelse return false;
        if (postdominator_block == op_block) return operationPrecedesOrSame(op, postdominator);
        return self.postDominatesBlock(postdominator_block, op_block);
    }

    fn requireSteady(self: *const BlockDominanceAnalysis) void {
        if (self.phase != .steady) {
            @panic("block dominance analysis used outside its steady phase");
        }
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(BlockDominanceAnalysis);
}

pub const DominanceAnalysis = BlockDominanceAnalysis;
pub const PostDominanceAnalysis = BlockDominanceAnalysis;

fn inspectControlFlowGraphOperation(
    op: *ir.Operation,
    survey: *ControlFlowGraphSurvey,
) !void {
    for (op.regions.items) |*region| {
        if (survey.region_count < survey.gathered.len) {
            survey.gathered[survey.region_count] = region;
        }
        survey.region_count = std.math.add(
            usize,
            survey.region_count,
            1,
        ) catch return error.CapacityOverflow;
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_node = block.operations.head;
            while (op_node) |node| {
                const nested: *ir.Operation = @ptrCast(@alignCast(node));
                try inspectControlFlowGraphOperation(nested, survey);
                op_node = nested.next_op;
            }
        }
    }
}

fn fillControlFlowGraphOperation(
    op: *ir.Operation,
    regions: []RegionControlFlow,
    filled: *usize,
) !void {
    for (op.regions.items) |*region| {
        if (filled.* >= regions.len) return error.OperationChanged;
        regions[filled.*] = undefined;
        regions[filled.*].region = region;
        filled.* += 1;

        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_node = block.operations.head;
            while (op_node) |node| {
                const nested: *ir.Operation = @ptrCast(@alignCast(node));
                try fillControlFlowGraphOperation(nested, regions, filled);
                op_node = nested.next_op;
            }
        }
    }
}

noinline fn sortControlFlowRegionPointers(
    regions: []RegionControlFlow,
) void {
    if (regions.len < 2) return;

    var root = regions.len / 2;
    while (root > 0) {
        root -= 1;
        siftControlFlowRegionPointer(regions, root, regions.len);
    }

    var end = regions.len;
    while (end > 1) {
        end -= 1;
        swapControlFlowRegionPointers(&regions[0], &regions[end]);
        siftControlFlowRegionPointer(regions, 0, end);
    }
}

fn siftControlFlowRegionPointer(
    regions: []RegionControlFlow,
    start: usize,
    end: usize,
) void {
    std.debug.assert(end <= regions.len);
    std.debug.assert(start < end);
    var root = start;
    while (root < end / 2) {
        const doubled = std.math.mul(usize, root, 2) catch
            @panic("control-flow region heap index overflow");
        var child = std.math.add(usize, doubled, 1) catch
            @panic("control-flow region heap index overflow");
        const right = std.math.add(usize, child, 1) catch
            @panic("control-flow region heap index overflow");
        std.debug.assert(child < end);
        if (right < end and
            @intFromPtr(regions[child].region) <
                @intFromPtr(regions[right].region))
        {
            child = right;
        }
        if (@intFromPtr(regions[root].region) >=
            @intFromPtr(regions[child].region)) return;
        swapControlFlowRegionPointers(&regions[root], &regions[child]);
        root = child;
    }
}

fn swapControlFlowRegionPointers(
    lhs: *RegionControlFlow,
    rhs: *RegionControlFlow,
) void {
    const region = lhs.region;
    lhs.region = rhs.region;
    rhs.region = region;
}

fn regionControlFlowsOrdered(regions: []const RegionControlFlow) bool {
    if (regions.len < 2) return true;
    var previous = @intFromPtr(regions[0].region);
    for (regions[1..]) |region_cfg| {
        const current = @intFromPtr(region_cfg.region);
        if (previous >= current) return false;
        previous = current;
    }
    return true;
}

const RegionDominanceLimits = struct {
    cfg: *const RegionControlFlow,
    kind: DominanceKind,
    block_count: usize,

    pub fn inspect(
        cfg: *const RegionControlFlow,
        kind: DominanceKind,
    ) RegionDominanceLimits {
        return .{
            .cfg = cfg,
            .kind = kind,
            .block_count = cfg.blockCount(),
        };
    }
};

const RegionDominanceCapacity = struct {
    block_count: usize,
    working_bytes: usize,

    pub fn derive(limits: RegionDominanceLimits) !RegionDominanceCapacity {
        const layout = try RegionDominanceLayout.derive(limits.block_count);
        return .{
            .block_count = limits.block_count,
            .working_bytes = layout.working_bytes,
        };
    }
};

const RegionDominanceLayout = struct {
    block_count: usize,
    relation_count: usize,
    block_offset: usize,
    relation_offset: usize,
    root_offset: usize,
    scratch_offset: usize,
    working_bytes: usize,

    fn derive(block_count: usize) !RegionDominanceLayout {
        const relation_count = std.math.mul(
            usize,
            block_count,
            block_count,
        ) catch return error.CapacityOverflow;
        if (block_count <= 1) return .{
            .block_count = block_count,
            .relation_count = relation_count,
            .block_offset = 0,
            .relation_offset = 0,
            .root_offset = 0,
            .scratch_offset = 0,
            .working_bytes = 0,
        };
        var cursor: usize = 0;
        const block_offset = try placeControlStorage(
            try controlStorageBytes(*ir.Block, block_count),
            @alignOf(*ir.Block),
            &cursor,
        );
        const relation_offset = try placeControlStorage(
            try controlStorageBytes(bool, relation_count),
            @alignOf(bool),
            &cursor,
        );
        const root_offset = try placeControlStorage(
            try controlStorageBytes(bool, block_count),
            @alignOf(bool),
            &cursor,
        );
        const scratch_offset = try placeControlStorage(
            try controlStorageBytes(bool, block_count),
            @alignOf(bool),
            &cursor,
        );
        return .{
            .block_count = block_count,
            .relation_count = relation_count,
            .block_offset = block_offset,
            .relation_offset = relation_offset,
            .root_offset = root_offset,
            .scratch_offset = scratch_offset,
            .working_bytes = cursor,
        };
    }
};

pub const RegionDominance = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.region_dominance",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "sorted_block_pointers_and_exact_dominance_relation_matrix",
                        .lifetime = .steady,
                        .detail = "sorted block pointers and exact dominance relation matrix",
                    },
                    .{
                        .id = "root_and_fixed_point_scratch_vectors_colocated_with_76bd11122433",
                        .lifetime = .initialization,
                        .detail = "root and fixed-point scratch vectors colocated with retained relations",
                    },
                    .{
                        .id = "inline_empty_and_singleton_dominance_representation",
                        .lifetime = .steady,
                        .detail = "inline empty and singleton dominance representation",
                    },
                },
                .excluded = &.{
                    "borrowed region control-flow and IR storage",
                    "enclosing analysis maps, order lists, and region owner objects",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "block_count", "block_count"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(*ir.Block, "block"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .product = .{ .left = 0, .right = 0 } },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .literal = 2 } } },
                    .{ .add = .{ .left = 1, .right = 2 } },
                    .{ .add = .{ .left = 4, .right = 3 } },
                    .{ .constant = 1 },
                    .{ .constant = 0 },
                    .{ .alignment = .{ .node = 5, .alignment = .{ .literal = 16 } } },
                    .{ .conditional = .{ .predicate = .{ .comparison = .less_or_equal, .left = 0, .right = 6 }, .when_true = 7, .when_false = 8 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 9,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "incompatible control-flow cardinality, relation arithmetic, layout arithmetic, or OOM rejects before an active dominance owner is published",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "activated dominance queries use only the sealed relation matrix and retained block pointers",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "dominance initialization and queries cross no operating-system or foreign callback boundary",
                },
            },
            .obligations = &.{
                .{ .key = "choir_region_dominance_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "choir_region_dominance_capacity_overload", .role = .overload },
                .{ .key = "choir_region_dominance_acquisition", .role = .custom },
                .{ .key = "choir_region_dominance_sealed_transitive_risk", .role = .transitive_risk },
                .{ .key = "choir_region_dominance_sealed_foreign_risk", .role = .foreign_risk },
                .{ .key = "choir_region_dominance_oom", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: alloc_phase.capacity.Phase,
    capacity: RegionDominanceCapacity,
    storage: Storage,

    const Multiple = struct {
        bytes: []align(control_storage_alignment) u8,
        blocks: [*]*ir.Block,
        relations: [*]bool,
    };

    const Storage = union(enum) {
        empty: *ir.Region,
        single: *ir.Block,
        multiple: Multiple,
    };

    pub const Limits = RegionDominanceLimits;
    pub const Capacity = RegionDominanceCapacity;

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !RegionDominance {
        const blocks = limits.cfg.blockInfos();
        const capacity = try Capacity.derive(limits);
        if (blocks.len != capacity.block_count) return error.RegionChanged;
        var owner: RegionDominance = .{
            .phase = .initialization,
            .capacity = capacity,
            .storage = .{ .empty = limits.cfg.region },
        };
        if (blocks.len == 0) return owner;
        if (blocks.len == 1) {
            owner.storage = .{ .single = blocks[0].block };
            return owner;
        }
        try initializeRegionDominanceMultiple(&owner, allocator, limits);
        return owner;
    }

    pub fn initForRegion(
        allocator: std.mem.Allocator,
        cfg: *const RegionControlFlow,
        kind: DominanceKind,
    ) !RegionDominance {
        return init(allocator, Limits.inspect(cfg, kind));
    }

    pub fn activate(self: *RegionDominance) !void {
        if (self.phase != .initialization) return error.AlreadyActive;
        self.phase = .steady;
    }

    pub fn deinit(self: *RegionDominance, allocator: std.mem.Allocator) void {
        if (self.phase == .teardown) @panic("dominance teardown is terminal");
        if (self.storage == .multiple) allocator.free(self.storage.multiple.bytes);
        self.phase = .teardown;
        self.storage = undefined;
    }

    pub fn contains(self: *const RegionDominance, dominator: *ir.Block, block: *ir.Block) bool {
        self.requireSteady();
        return switch (self.storage) {
            .empty => false,
            .single => |single| dominator == single and block == single,
            .multiple => |multiple| containsMultiple(
                multiple,
                self.capacity.block_count,
                dominator,
                block,
            ),
        };
    }

    fn blockSlice(self: *const RegionDominance) []const *ir.Block {
        self.requireSteady();
        return switch (self.storage) {
            .empty => &.{},
            .single => |*single| @as(
                *const [1]*ir.Block,
                @ptrCast(single),
            )[0..],
            .multiple => |multiple| multiple.blocks[0..self.capacity.block_count],
        };
    }

    fn regionPointer(self: *const RegionDominance) *ir.Region {
        self.requireSteady();
        return switch (self.storage) {
            .empty => |region| region,
            .single => |block| block.getParentRegion() orelse
                @panic("dominance block lost its parent region"),
            .multiple => |multiple| multiple.blocks[0].getParentRegion() orelse
                @panic("dominance block lost its parent region"),
        };
    }

    fn requireSteady(self: *const RegionDominance) void {
        if (self.phase != .steady) {
            @panic("dominance region used outside its steady phase");
        }
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(RegionDominance);
}

fn regionDominancesOrdered(regions: []const RegionDominance) bool {
    if (regions.len < 2) return true;
    var previous = @intFromPtr(regions[0].regionPointer());
    for (regions[1..]) |region_dom| {
        const current = @intFromPtr(region_dom.regionPointer());
        if (previous >= current) return false;
        previous = current;
    }
    return true;
}

fn initializeRegionDominanceMultiple(
    owner: *RegionDominance,
    allocator: std.mem.Allocator,
    limits: RegionDominance.Limits,
) !void {
    const capacity = owner.capacity;
    const layout = try RegionDominanceLayout.derive(limits.block_count);
    if (layout.working_bytes != capacity.working_bytes) {
        return error.RegionChanged;
    }
    const bytes = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(control_storage_alignment),
        capacity.working_bytes,
    );
    errdefer allocator.free(bytes);
    const blocks = controlTypedSlice(
        *ir.Block,
        bytes,
        layout.block_offset,
        layout.block_count,
    );
    for (limits.cfg.blockInfos(), blocks) |info, *block| block.* = info.block;
    std.debug.assert(blocksOrdered(blocks));
    const relations = controlTypedSlice(
        bool,
        bytes,
        layout.relation_offset,
        layout.relation_count,
    );
    const roots = controlTypedSlice(
        bool,
        bytes,
        layout.root_offset,
        layout.block_count,
    );
    const scratch = controlTypedSlice(
        bool,
        bytes,
        layout.scratch_offset,
        layout.block_count,
    );
    computeRelations(limits.cfg, limits.kind, relations, roots, scratch);
    owner.storage = .{ .multiple = .{
        .bytes = bytes,
        .blocks = blocks.ptr,
        .relations = relations.ptr,
    } };
}

fn containsMultiple(
    multiple: RegionDominance.Multiple,
    block_count: usize,
    dominator: *ir.Block,
    block: *ir.Block,
) bool {
    const blocks = multiple.blocks[0..block_count];
    const relation_count = std.math.mul(
        usize,
        block_count,
        block_count,
    ) catch unreachable;
    const relations = multiple.relations[0..relation_count];
    std.debug.assert(blocksOrdered(blocks));
    const dominator_index = indexOfBlock(blocks, dominator) orelse
        return false;
    const block_index = indexOfBlock(blocks, block) orelse return false;
    return relations[
        relationIndex(
            block_count,
            block_index,
            dominator_index,
        )
    ];
}

const ControlWork = struct {
    regions: u64 = 0,
    cfg_visits: u64 = 0,
    dominance_visits: u64 = 0,
    cfg_bytes: u64 = @sizeOf(ControlFlowGraphAnalysis) + 2 * @alignOf(ControlFlowGraphAnalysis),
    dominance_bytes: u64 = @sizeOf(BlockDominanceAnalysis) + 2 * @alignOf(BlockDominanceAnalysis),

    fn inspect(op: *ir.Operation) !ControlWork {
        var counts: ControlWork = .{};
        _ = try op.walk(.{ .order = .pre_order }, &counts, inspectOperation);
        const ordering = try pass.work.multiply(
            16,
            try pass.work.multiply(counts.regions, counts.regions),
        );
        counts.cfg_visits = try pass.work.add(counts.cfg_visits, ordering);
        counts.dominance_visits = try pass.work.add(counts.dominance_visits, ordering);
        return counts;
    }

    fn inspectOperation(self: *ControlWork, op: *ir.Operation) !ir.Operation.WalkResult {
        self.cfg_visits = try pass.work.add(self.cfg_visits, 1);
        self.dominance_visits = try pass.work.add(self.dominance_visits, 1);
        for (op.regions.items) |*region| try self.inspectRegion(region);
        return .advance;
    }

    fn inspectRegion(self: *ControlWork, region: *ir.Region) !void {
        self.regions = try pass.work.add(self.regions, 1);
        const limits = try RegionControlFlow.Limits.inspect(region);
        const cfg = try RegionControlFlow.Capacity.derive(limits);
        const dom = try RegionDominanceLayout.derive(limits.facts.block_count);
        self.cfg_bytes = try pass.work.add(self.cfg_bytes, try pass.work.add(
            @sizeOf(RegionControlFlow) + 2 * control_storage_alignment,
            cfg.working_bytes,
        ));
        self.dominance_bytes = try pass.work.add(self.dominance_bytes, try pass.work.add(
            @sizeOf(RegionDominance) + 2 * control_storage_alignment,
            dom.working_bytes,
        ));
        var edges: u64 = 0;
        var iter = region.getBlocks();
        while (iter.next()) |block| edges = try pass.work.add(edges, controlSuccessorCount(block));
        try self.includeVisits(limits.facts.block_count, edges);
    }

    fn includeVisits(self: *ControlWork, blocks: u64, raw_edges: u64) !void {
        const scale = try pass.work.add(try pass.work.add(blocks, raw_edges), 1);
        self.cfg_visits = try pass.work.add(self.cfg_visits, try pass.work.multiply(
            16,
            try pass.work.multiply(scale, scale),
        ));
        const relations = try pass.work.multiply(blocks, blocks);
        const rounds = try pass.work.add(relations, 1);
        const rows = try pass.work.add(blocks, 1);
        const per_round = try pass.work.multiply(rows, scale);
        self.dominance_visits = try pass.work.add(self.dominance_visits, try pass.work.multiply(
            16,
            try pass.work.multiply(rounds, per_round),
        ));
    }
};

/// CFG surveys, duplicate-edge checks, ordered records and edge construction fit
/// sixteen quadratic visits over blocks plus raw successor occurrences per region.
/// Storage uses the existing owner layouts, including alignment between allocations.
fn cfgWorkBounds(input: pass.work.Input) !pass.work.Bounds {
    const counts = ControlWork.inspect(input.operation) catch |err| return switch (err) {
        error.CapacityOverflow => error.WorkOverflow,
        else => err,
    };
    return .{
        .work = .{
            .analysis_computations = 1,
            .structural_visits = counts.cfg_visits,
            .allocation_capacity = counts.cfg_bytes,
        },
        .workspace = counts.cfg_bytes,
        .retained_storage = counts.cfg_bytes,
    };
}

/// The monotone relation matrix can lose at most B*B bits before the final round.
/// Each round covers row scans, predecessor/successor intersections and lookups.
/// CFG computation is its own nested obligation and is not included in this bound.
fn dominanceWorkBounds(input: pass.work.Input) !pass.work.Bounds {
    const counts = ControlWork.inspect(input.operation) catch |err| return switch (err) {
        error.CapacityOverflow => error.WorkOverflow,
        else => err,
    };
    return .{
        .work = .{
            .analysis_computations = 1,
            .structural_visits = counts.dominance_visits,
            .allocation_capacity = counts.dominance_bytes,
        },
        .workspace = counts.dominance_bytes,
        .retained_storage = counts.dominance_bytes,
    };
}

const ControlFlowGraphRegistration = pass.Analysis(
    ControlFlowGraphAnalysis,
    cfg_analysis_name,
    &.{ir.interfaces.ControlFlowInterface.id},
    computeControlFlowGraphAnalysis,
    cleanupControlFlowGraphAnalysis,
    .{ .identity = .{ .name = cfg_analysis_name, .version = 1 }, .estimate = cfgWorkBounds },
);

const DominanceRegistration = pass.Analysis(
    DominanceAnalysis,
    dominance_analysis_name,
    &.{ir.interfaces.ControlFlowInterface.id},
    computeDominanceAnalysis,
    cleanupDominanceAnalysis,
    .{
        .identity = .{ .name = dominance_analysis_name, .version = 1 },
        .estimate = dominanceWorkBounds,
    },
);

const PostDominanceRegistration = pass.Analysis(
    PostDominanceAnalysis,
    post_dominance_analysis_name,
    &.{ir.interfaces.ControlFlowInterface.id},
    computePostDominanceAnalysis,
    cleanupPostDominanceAnalysis,
    .{
        .identity = .{ .name = post_dominance_analysis_name, .version = 1 },
        .estimate = dominanceWorkBounds,
    },
);

pub const cfg_analysis_descriptor = ControlFlowGraphRegistration.descriptor;
pub const dominance_analysis_descriptor = DominanceRegistration.descriptor;
pub const post_dominance_analysis_descriptor = PostDominanceRegistration.descriptor;
pub const analysis_ids: []const pass.AnalysisId = &.{
    cfg_analysis_descriptor.id,
    dominance_analysis_descriptor.id,
    post_dominance_analysis_descriptor.id,
};

pub fn getControlFlowGraphAnalysis(ctx: *pass.PassContext, op: *ir.Operation) !*ControlFlowGraphAnalysis {
    return ControlFlowGraphRegistration.get(ctx, op);
}

pub fn getDominanceAnalysis(ctx: *pass.PassContext, op: *ir.Operation) !*DominanceAnalysis {
    return DominanceRegistration.get(ctx, op);
}

pub fn getPostDominanceAnalysis(ctx: *pass.PassContext, op: *ir.Operation) !*PostDominanceAnalysis {
    return PostDominanceRegistration.get(ctx, op);
}

fn computeControlFlowGraphAnalysis(ctx: *pass.PassContext, op: *ir.Operation) anyerror!*ControlFlowGraphAnalysis {
    const analysis = try ctx.allocator.create(ControlFlowGraphAnalysis);
    errdefer ctx.allocator.destroy(analysis);
    analysis.* = try ControlFlowGraphAnalysis.initForOperation(
        ctx.allocator,
        op,
    );
    errdefer analysis.deinit(ctx.allocator);
    try analysis.activate();
    return analysis;
}

fn cleanupControlFlowGraphAnalysis(analysis: *ControlFlowGraphAnalysis, allocator: std.mem.Allocator) void {
    analysis.deinit(allocator);
    allocator.destroy(analysis);
}

fn computeDominanceAnalysis(ctx: *pass.PassContext, op: *ir.Operation) anyerror!*DominanceAnalysis {
    const cfg = try getControlFlowGraphAnalysis(ctx, op);
    const analysis = try ctx.allocator.create(DominanceAnalysis);
    errdefer ctx.allocator.destroy(analysis);
    analysis.* = try DominanceAnalysis.init(
        ctx.allocator,
        DominanceAnalysis.Limits.inspect(cfg, .forward),
    );
    errdefer analysis.deinit(ctx.allocator);
    try analysis.activate();
    return analysis;
}

fn cleanupDominanceAnalysis(analysis: *DominanceAnalysis, allocator: std.mem.Allocator) void {
    analysis.deinit(allocator);
    allocator.destroy(analysis);
}

fn computePostDominanceAnalysis(ctx: *pass.PassContext, op: *ir.Operation) anyerror!*PostDominanceAnalysis {
    const cfg = try getControlFlowGraphAnalysis(ctx, op);
    const analysis = try ctx.allocator.create(PostDominanceAnalysis);
    errdefer ctx.allocator.destroy(analysis);
    analysis.* = try PostDominanceAnalysis.init(
        ctx.allocator,
        PostDominanceAnalysis.Limits.inspect(cfg, .reverse),
    );
    errdefer analysis.deinit(ctx.allocator);
    try analysis.activate();
    return analysis;
}

fn cleanupPostDominanceAnalysis(analysis: *PostDominanceAnalysis, allocator: std.mem.Allocator) void {
    analysis.deinit(allocator);
    allocator.destroy(analysis);
}

fn controlSuccessorCount(block: *ir.Block) usize {
    const term_any = block.getTerminator() orelse return 0;
    const term: *ir.Operation = @ptrCast(@alignCast(term_any));
    if (term.interface(ir.interfaces.ControlFlowInterface)) |iface| {
        return iface.call(.getSuccessorCount, .{});
    }
    return term.successors.items.len;
}

fn controlSuccessorAt(block: *ir.Block, index: usize) ?*ir.Block {
    const term_any = block.getTerminator() orelse return null;
    const term: *ir.Operation = @ptrCast(@alignCast(term_any));
    if (term.interface(ir.interfaces.ControlFlowInterface)) |iface| {
        return iface.call(.getSuccessor, .{index});
    }
    if (index >= term.successors.items.len) return null;
    return term.successors.items[index];
}

fn controlSuccessorAppeared(block: *ir.Block, index: usize, successor: *ir.Block) bool {
    for (0..index) |prior_index| {
        if (controlSuccessorAt(block, prior_index) == successor) return true;
    }
    return false;
}

fn initializeRegionControlFlowMultiple(
    owner: *RegionControlFlow,
    allocator: std.mem.Allocator,
    limits: RegionControlFlow.Limits,
) !void {
    const capacity = owner.capacity;
    const layout = try RegionControlFlowLayout.derive(limits.facts);
    if (layout.working_bytes != capacity.working_bytes) {
        return error.RegionChanged;
    }
    const bytes = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(control_storage_alignment),
        capacity.working_bytes,
    );
    errdefer allocator.free(bytes);
    const blocks = controlTypedSlice(
        RegionControlFlow.BlockInfo,
        bytes,
        layout.block_offset,
        layout.facts.block_count,
    );
    try initializeControlBlocks(owner.region, blocks);
    try initializeControlEdges(owner.region, layout, bytes, blocks);
    owner.storage = .{ .multiple = .{
        .bytes = bytes,
        .blocks = blocks,
    } };
}

fn countRegionSuccessors(block: *ir.Block, region: *ir.Region) !usize {
    var count: usize = 0;
    for (0..controlSuccessorCount(block)) |index| {
        const successor = controlSuccessorAt(block, index) orelse continue;
        if (successor.getParentRegion() != region) continue;
        if (controlSuccessorAppeared(block, index, successor)) continue;
        count = std.math.add(usize, count, 1) catch return error.CapacityOverflow;
    }
    return count;
}

fn writeRegionSuccessors(
    block: *ir.Block,
    region: *ir.Region,
    output: []*ir.Block,
) !usize {
    var count: usize = 0;
    for (0..controlSuccessorCount(block)) |index| {
        const successor = controlSuccessorAt(block, index) orelse continue;
        if (successor.getParentRegion() != region) continue;
        if (controlSuccessorAppeared(block, index, successor)) continue;
        if (count == output.len) return error.RegionChanged;
        output[count] = successor;
        count += 1;
    }
    return count;
}

fn initializeControlBlocks(
    region: *ir.Region,
    blocks: []RegionControlFlow.BlockInfo,
) !void {
    var iter = region.getBlocks();
    var index: usize = 0;
    while (iter.next()) |block| {
        if (index == blocks.len) return error.RegionChanged;
        blocks[index] = .{
            .block = block,
            .successors = &.{},
            .predecessors = &.{},
        };
        index += 1;
    }
    if (index != blocks.len) return error.RegionChanged;
    std.sort.heap(RegionControlFlow.BlockInfo, blocks, {}, blockInfoAddressLessThan);
    std.debug.assert(blockInfosOrdered(blocks));
}

fn initializeControlEdges(
    region: *ir.Region,
    layout: RegionControlFlowLayout,
    bytes: []align(control_storage_alignment) u8,
    blocks: []RegionControlFlow.BlockInfo,
) !void {
    const successors = controlTypedSlice(
        *ir.Block,
        bytes,
        layout.successor_offset,
        layout.facts.edge_count,
    );
    const predecessors = controlTypedSlice(
        *ir.Block,
        bytes,
        layout.predecessor_offset,
        layout.facts.edge_count,
    );
    const cursors = controlTypedSlice(
        usize,
        bytes,
        layout.cursor_offset,
        layout.facts.block_count,
    );
    try initializeControlSuccessors(region, blocks, successors);
    try initializeControlPredecessors(region, blocks, predecessors, cursors);
}

fn initializeControlSuccessors(
    region: *ir.Region,
    blocks: []RegionControlFlow.BlockInfo,
    storage: []*ir.Block,
) !void {
    var edge_count: usize = 0;
    var iter = region.getBlocks();
    while (iter.next()) |block| {
        const info_index = indexOfBlockInfo(blocks, block) orelse
            return error.RegionChanged;
        const count = try writeRegionSuccessors(block, region, storage[edge_count..]);
        blocks[info_index].successors = storage[edge_count..][0..count];
        edge_count += count;
    }
    if (edge_count != storage.len) return error.RegionChanged;
}

fn initializeControlPredecessors(
    region: *ir.Region,
    blocks: []RegionControlFlow.BlockInfo,
    storage: []*ir.Block,
    cursors: []usize,
) !void {
    @memset(cursors, 0);
    for (blocks) |info| {
        for (info.successors) |successor| {
            const index = indexOfBlockInfo(blocks, successor) orelse
                return error.RegionChanged;
            cursors[index] = std.math.add(usize, cursors[index], 1) catch
                return error.CapacityOverflow;
        }
    }
    try assignPredecessorSlices(blocks, storage, cursors);
    @memset(cursors, 0);
    try fillControlPredecessors(region, blocks, cursors);
}

fn assignPredecessorSlices(
    blocks: []RegionControlFlow.BlockInfo,
    storage: []*ir.Block,
    counts: []const usize,
) !void {
    var offset: usize = 0;
    for (blocks, counts) |*info, count| {
        const end = std.math.add(usize, offset, count) catch
            return error.CapacityOverflow;
        if (end > storage.len) return error.RegionChanged;
        info.predecessors = storage[offset..end];
        offset = end;
    }
    if (offset != storage.len) return error.RegionChanged;
}

fn fillControlPredecessors(
    region: *ir.Region,
    blocks: []RegionControlFlow.BlockInfo,
    cursors: []usize,
) !void {
    var iter = region.getBlocks();
    while (iter.next()) |block| {
        const source_index = indexOfBlockInfo(blocks, block) orelse
            return error.RegionChanged;
        for (blocks[source_index].successors) |successor| {
            const target_index = indexOfBlockInfo(blocks, successor) orelse
                return error.RegionChanged;
            const cursor = cursors[target_index];
            if (cursor == blocks[target_index].predecessors.len) {
                return error.RegionChanged;
            }
            @constCast(blocks[target_index].predecessors)[cursor] = block;
            cursors[target_index] += 1;
        }
    }
    for (blocks, cursors) |info, cursor| {
        if (cursor != info.predecessors.len) return error.RegionChanged;
    }
}

fn controlStorageBytes(comptime T: type, count: usize) !usize {
    return std.math.mul(usize, count, @sizeOf(T)) catch
        error.CapacityOverflow;
}

fn placeControlStorage(byte_count: usize, alignment: usize, cursor: *usize) !usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const padded = std.math.add(usize, cursor.*, alignment - 1) catch
        return error.CapacityOverflow;
    const offset = padded & ~(alignment - 1);
    cursor.* = std.math.add(usize, offset, byte_count) catch
        return error.CapacityOverflow;
    return offset;
}

fn controlTypedSlice(
    comptime T: type,
    bytes: []align(control_storage_alignment) u8,
    offset: usize,
    count: usize,
) []T {
    if (count == 0) return &.{};
    const byte_count = std.math.mul(usize, count, @sizeOf(T)) catch unreachable;
    const region: []align(@alignOf(T)) u8 = @alignCast(
        bytes[offset..][0..byte_count],
    );
    return std.mem.bytesAsSlice(T, region);
}

fn blockInfoAddressLessThan(_: void, lhs: RegionControlFlow.BlockInfo, rhs: RegionControlFlow.BlockInfo) bool {
    return @intFromPtr(lhs.block) < @intFromPtr(rhs.block);
}

fn blockInfosOrdered(blocks: []const RegionControlFlow.BlockInfo) bool {
    if (blocks.len < 2) return true;
    for (blocks[1..], blocks[0 .. blocks.len - 1]) |current, previous| {
        if (@intFromPtr(previous.block) >= @intFromPtr(current.block)) return false;
    }
    return true;
}

fn blocksOrdered(blocks: []const *ir.Block) bool {
    if (blocks.len < 2) return true;
    for (blocks[1..], blocks[0 .. blocks.len - 1]) |current, previous| {
        if (@intFromPtr(previous) >= @intFromPtr(current)) return false;
    }
    return true;
}

fn indexOfBlockInfo(blocks: []const RegionControlFlow.BlockInfo, block: *ir.Block) ?usize {
    var low: usize = 0;
    var high = blocks.len;
    const address = @intFromPtr(block);
    while (low < high) {
        std.debug.assert(high <= blocks.len);
        const middle = low + (high - low) / 2;
        std.debug.assert(middle < blocks.len);
        const middle_address = @intFromPtr(blocks[middle].block);
        if (middle_address == address) return middle;
        if (middle_address < address) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return null;
}

fn indexOfBlock(blocks: []const *ir.Block, block: *ir.Block) ?usize {
    var low: usize = 0;
    var high = blocks.len;
    const address = @intFromPtr(block);
    while (low < high) {
        std.debug.assert(high <= blocks.len);
        const middle = low + (high - low) / 2;
        std.debug.assert(middle < blocks.len);
        const middle_address = @intFromPtr(blocks[middle]);
        if (middle_address == address) return middle;
        if (middle_address < address) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return null;
}

fn relationIndex(block_count: usize, block_index: usize, dominator_index: usize) usize {
    return block_index * block_count + dominator_index;
}

fn computeRelations(
    cfg: *const RegionControlFlow,
    kind: DominanceKind,
    relations: []bool,
    roots: []bool,
    scratch: []bool,
) void {
    const blocks = cfg.blockInfos();
    const block_count = blocks.len;
    if (block_count == 0) return;
    const relation_count = std.math.mul(
        usize,
        block_count,
        block_count,
    ) catch unreachable;
    std.debug.assert(relations.len == relation_count);
    std.debug.assert(roots.len == block_count);
    std.debug.assert(scratch.len == block_count);

    computeRoots(cfg, kind, roots);

    for (0..block_count) |block_index| {
        const row = relations[block_index * block_count ..][0..block_count];
        if (roots[block_index]) {
            @memset(row, false);
            row[block_index] = true;
        } else {
            @memset(row, true);
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (0..block_count) |block_index| {
            if (roots[block_index]) continue;

            const inputs = switch (kind) {
                .forward => blocks[block_index].predecessors,
                .reverse => blocks[block_index].successors,
            };

            @memset(scratch, true);
            for (inputs) |input| {
                const input_index = cfg.indexOf(input) orelse continue;
                const input_row = relations[input_index * block_count ..][0..block_count];
                for (scratch, input_row) |*slot, input_bit| {
                    slot.* = slot.* and input_bit;
                }
            }
            scratch[block_index] = true;

            const row = relations[block_index * block_count ..][0..block_count];
            if (!std.mem.eql(bool, row, scratch)) {
                @memcpy(row, scratch);
                changed = true;
            }
        }
    }
}

fn computeRoots(cfg: *const RegionControlFlow, kind: DominanceKind, roots: []bool) void {
    const blocks = cfg.blockInfos();
    std.debug.assert(roots.len == blocks.len);
    @memset(roots, false);

    switch (kind) {
        .forward => {
            if (cfg.entryBlock()) |entry| {
                if (cfg.indexOf(entry)) |entry_index| roots[entry_index] = true;
            }
            for (blocks, 0..) |info, index| {
                if (info.predecessors.len == 0) roots[index] = true;
            }
        },
        .reverse => {
            var has_exit = false;
            for (blocks, 0..) |info, index| {
                if (info.successors.len == 0) {
                    roots[index] = true;
                    has_exit = true;
                }
            }
            if (!has_exit) {
                @memset(roots, true);
            }
        },
    }
}

fn operationPrecedesOrSame(first: *ir.Operation, second: *ir.Operation) bool {
    return first == second or first.isBeforeInBlock(second);
}

fn buildDiamond(ctx: *ir.Context) !struct {
    module: @import("../dialects/fixture/root.zig").TestDialect.ModuleOp,
    entry: *ir.Block,
    then_block: *ir.Block,
    else_block: *ir.Block,
    merge: *ir.Block,
    unreachable_block: *ir.Block,
    entry_term: *ir.Operation,
    then_value: *ir.Operation,
    then_term: *ir.Operation,
    else_term: *ir.Operation,
} {
    const test_dialect = @import("../dialects/fixture/root.zig");

    try test_dialect.registerTestDialect(ctx);
    _ = try ctx.registerOperation("test.cond_br", .{});
    _ = try ctx.registerOperation("test.value", .{});
    _ = try ctx.registerOperation("test.return", .{});

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(ctx, loc);
    const region = module.getBody();
    const entry = module.getBodyBlock();
    const then_block = try region.addBlock();
    const else_block = try region.addBlock();
    const merge = try region.addBlock();
    const unreachable_block = try region.addBlock();

    var builder = ir.OperationBuilder.init(ctx);

    var entry_state = ir.Operation.State.init("test.cond_br", loc);
    entry_state.addSuccessors(&.{ then_block, else_block });
    const entry_term = try builder.create(entry_state);
    try entry.addOperation(entry_term);

    const i64_type = try test_dialect.TestDialect.getI64Type(ctx);
    var then_value_state = ir.Operation.State.init("test.value", loc);
    then_value_state.addTypes(&.{i64_type});
    const then_value = try builder.create(then_value_state);
    try then_block.addOperation(then_value);

    var then_state = ir.Operation.State.init(test_dialect.TestDialect.BranchOp.operation_name, loc);
    then_state.addSuccessors(&.{merge});
    const then_term = try builder.create(then_state);
    try then_block.addOperation(then_term);

    var else_state = ir.Operation.State.init(test_dialect.TestDialect.BranchOp.operation_name, loc);
    else_state.addSuccessors(&.{merge});
    const else_term = try builder.create(else_state);
    try else_block.addOperation(else_term);

    const merge_term = try builder.create(ir.Operation.State.init("test.return", loc));
    try merge.addOperation(merge_term);

    const unreachable_term = try builder.create(ir.Operation.State.init("test.return", loc));
    try unreachable_block.addOperation(unreachable_term);

    return .{
        .module = module,
        .entry = entry,
        .then_block = then_block,
        .else_block = else_block,
        .merge = merge,
        .unreachable_block = unreachable_block,
        .entry_term = entry_term,
        .then_value = then_value,
        .then_term = then_term,
        .else_term = else_term,
    };
}

const NestedControlFixture = struct {
    root: @import("../dialects/fixture/root.zig").TestDialect.ModuleOp,
    first: @import("../dialects/fixture/root.zig").TestDialect.ModuleOp,
    second: @import("../dialects/fixture/root.zig").TestDialect.ModuleOp,
    first_branch: *ir.Operation,
};

fn buildNestedControlFixture(ctx: *ir.Context) !NestedControlFixture {
    const test_dialect = @import("../dialects/fixture/root.zig");
    const loc = ir.Location.getUnknown();
    const root = try test_dialect.TestDialect.ModuleOp.create(ctx, loc);
    const lhs = try test_dialect.TestDialect.ModuleOp.create(ctx, loc);
    const rhs = try test_dialect.TestDialect.ModuleOp.create(ctx, loc);
    const first = if (@intFromPtr(lhs.getBody()) > @intFromPtr(rhs.getBody()))
        lhs
    else
        rhs;
    const second = if (first.op == lhs.op) rhs else lhs;
    try root.getBodyBlock().addOperation(first.op);
    try root.getBodyBlock().addOperation(second.op);

    var builder = ir.OperationBuilder.init(ctx);
    var first_state = ir.Operation.State.init(
        test_dialect.TestDialect.BranchOp.operation_name,
        loc,
    );
    first_state.addSuccessors(&.{first.getBodyBlock()});
    const first_branch = try builder.create(first_state);
    try first.getBodyBlock().addOperation(first_branch);

    var second_state = ir.Operation.State.init(
        test_dialect.TestDialect.BranchOp.operation_name,
        loc,
    );
    second_state.addSuccessors(&.{second.getBodyBlock()});
    const second_branch = try builder.create(second_state);
    try second.getBodyBlock().addOperation(second_branch);

    return .{
        .root = root,
        .first = first,
        .second = second,
        .first_branch = first_branch,
    };
}

test "ControlFlowGraphAnalysis records region edges" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);

    var cache = pass.AnalysisCache.init(allocator, null);
    defer cache.deinit();

    var pass_ctx = pass.PassContext.init(fixture.module.op, &ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const cfg = try getControlFlowGraphAnalysis(&pass_ctx, fixture.module.op);
    const region_cfg = cfg.getRegion(fixture.module.getBody()) orelse return error.TestExpectedRegionCfg;

    try testing.expectEqual(@as(usize, 5), region_cfg.blockCount());
    try testing.expect(region_cfg.hasEdge(fixture.entry, fixture.then_block));
    try testing.expect(region_cfg.hasEdge(fixture.entry, fixture.else_block));
    try testing.expect(region_cfg.hasEdge(fixture.then_block, fixture.merge));
    try testing.expect(region_cfg.hasEdge(fixture.else_block, fixture.merge));
    try testing.expect(!region_cfg.hasEdge(fixture.merge, fixture.unreachable_block));

    const entry_succs = region_cfg.successors(fixture.entry) orelse return error.TestExpectedSuccessors;
    try testing.expectEqual(@as(usize, 2), entry_succs.len);
    try testing.expect(entry_succs[0] == fixture.then_block);
    try testing.expect(entry_succs[1] == fixture.else_block);

    const merge_preds = region_cfg.predecessors(fixture.merge) orelse return error.TestExpectedPredecessors;
    try testing.expectEqual(@as(usize, 2), merge_preds.len);
    try testing.expect(merge_preds[0] == fixture.then_block);
    try testing.expect(merge_preds[1] == fixture.else_block);
}

test "control-flow graph analysis derives exact region owner capacity" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlFlowGraphAnalysis, "choir_cfg_analysis_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlFlowGraphAnalysis, "choir_cfg_analysis_capacity_overload"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    const limits = try ControlFlowGraphAnalysis.Limits.inspect(fixture.root.op);
    try testing.expectEqual(@as(usize, 3), limits.region_count);
    const capacity = try ControlFlowGraphAnalysis.Capacity.derive(limits);
    try testing.expectEqual(@as(usize, 3), capacity.region_count);
    try testing.expectEqual(
        3 * @sizeOf(RegionControlFlow),
        capacity.storage_bytes,
    );

    var overflowing = limits;
    overflowing.region_count = std.math.maxInt(usize);
    try testing.expectError(
        error.CapacityOverflow,
        ControlFlowGraphAnalysis.Capacity.derive(overflowing),
    );

    const stale_root = try @import("../dialects/fixture/root.zig").TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );
    const stale_limits = try ControlFlowGraphAnalysis.Limits.inspect(
        stale_root.op,
    );
    const nested = try @import("../dialects/fixture/root.zig").TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );
    try stale_root.getBodyBlock().addOperation(nested.op);
    try testing.expectError(
        error.OperationChanged,
        ControlFlowGraphAnalysis.init(allocator, stale_limits),
    );
}

test "control-flow graph analysis acquires one exact region owner array" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlFlowGraphAnalysis, "choir_cfg_analysis_acquisition"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    const limits = try ControlFlowGraphAnalysis.Limits.inspect(fixture.root.op);
    const capacity = try ControlFlowGraphAnalysis.Capacity.derive(limits);
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var cfg = try ControlFlowGraphAnalysis.initForOperation(
        counting.allocator(),
        fixture.root.op,
    );
    defer cfg.deinit(counting.allocator());
    try testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try testing.expectEqual(capacity.storage_bytes, counting.allocated_bytes);
    try cfg.activate();
    try testing.expectEqual(@as(usize, 3), cfg.regionCount());
    try testing.expect(regionControlFlowsOrdered(cfg.regionSlice()));
    try testing.expect(cfg.getRegion(fixture.root.getBody()) != null);
    try testing.expect(cfg.getRegion(fixture.first.getBody()) != null);
    try testing.expect(cfg.getRegion(fixture.second.getBody()) != null);
    try testing.expectEqual(
        @as(usize, 1),
        cfg.successors(fixture.first.getBodyBlock()).?.len,
    );
    try testing.expect(
        cfg.successors(fixture.first.getBodyBlock()).?[0] ==
            fixture.first.getBodyBlock(),
    );

    var empty_counting = std.testing.FailingAllocator.init(allocator, .{});
    var empty_cfg = try ControlFlowGraphAnalysis.initForOperation(
        empty_counting.allocator(),
        fixture.first_branch,
    );
    defer empty_cfg.deinit(empty_counting.allocator());
    try testing.expectEqual(@as(usize, 0), empty_counting.alloc_index);
    try empty_cfg.activate();
    try testing.expectEqual(@as(usize, 0), empty_cfg.regionCount());

    const test_dialect = @import("../dialects/fixture/root.zig");
    const large_root = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );
    var large_children: [control_flow_graph_gather_capacity]*ir.Operation =
        undefined;
    var child_count: usize = 0;
    for (0..control_flow_graph_gather_capacity) |_| {
        const child = try test_dialect.TestDialect.ModuleOp.create(
            &ctx,
            ir.Location.getUnknown(),
        );
        var insert = child_count;
        while (insert > 0) {
            const previous = &large_children[insert - 1].regions.items[0];
            if (@intFromPtr(previous) > @intFromPtr(child.getBody())) break;
            large_children[insert] = large_children[insert - 1];
            insert -= 1;
        }
        large_children[insert] = child.op;
        child_count += 1;
    }
    for (large_children) |child| {
        try large_root.getBodyBlock().addOperation(child);
    }
    var large_counting = std.testing.FailingAllocator.init(allocator, .{});
    var large_cfg = try ControlFlowGraphAnalysis.initForOperation(
        large_counting.allocator(),
        large_root.op,
    );
    defer large_cfg.deinit(large_counting.allocator());
    try testing.expectEqual(@as(usize, 1), large_counting.alloc_index);
    try large_cfg.activate();
    try testing.expectEqual(
        control_flow_graph_gather_capacity + 1,
        large_cfg.regionCount(),
    );
}

test "control-flow graph analysis queries remain allocation free after sealing" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlFlowGraphAnalysis, "choir_cfg_analysis_sealed_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlFlowGraphAnalysis, "choir_cfg_analysis_sealed_foreign_risk"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(allocator);
    var maybe_cfg: ?ControlFlowGraphAnalysis = null;
    defer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_cfg) |*cfg| {
            if (cfg.phase != .teardown) {
                cfg.deinit(phase_allocator.teardownAllocator());
            }
        }
        phase_allocator.deinit();
    }
    maybe_cfg = try ControlFlowGraphAnalysis.initForOperation(
        phase_allocator.initializationAllocator(),
        fixture.root.op,
    );
    const cfg = &maybe_cfg.?;
    phase_allocator.seal();
    try cfg.activate();

    try testing.expectEqual(@as(usize, 3), cfg.regionCount());
    try testing.expect(cfg.getRegion(fixture.first.getBody()) != null);
    try testing.expectEqual(
        @as(usize, 1),
        cfg.predecessors(fixture.first.getBodyBlock()).?.len,
    );
    try testing.expectEqual(@as(u64, 0), phase_allocator.violations().total());
}

const ControlFlowGraphAnalysisFailureHarness = struct {
    fn run(allocator: std.mem.Allocator, root: *ir.Operation) !void {
        var cfg = try ControlFlowGraphAnalysis.initForOperation(
            allocator,
            root,
        );
        defer cfg.deinit(allocator);
        try cfg.activate();
        try std.testing.expectEqual(@as(usize, 3), cfg.regionCount());
    }
};

test "ControlFlowGraphAnalysis build retries every allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ControlFlowGraphAnalysis, "choir_cfg_analysis_oom"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    try testing.checkAllAllocationFailures(
        allocator,
        ControlFlowGraphAnalysisFailureHarness.run,
        .{fixture.root.op},
    );
    try ControlFlowGraphAnalysisFailureHarness.run(
        allocator,
        fixture.root.op,
    );
}

test "RegionControlFlow orders exact block lookup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);

    var region_cfg = try RegionControlFlow.initForRegion(
        allocator,
        fixture.module.getBody(),
    );
    defer region_cfg.deinit(allocator);
    try region_cfg.activate();

    const blocks = region_cfg.blockInfos();
    try testing.expectEqual(@as(usize, 5), blocks.len);
    for (blocks, 0..) |info, index| {
        try testing.expectEqual(index, region_cfg.indexOf(info.block).?);
        if (index > 0) {
            try testing.expect(@intFromPtr(blocks[index - 1].block) < @intFromPtr(info.block));
        }
    }

    const test_dialect = @import("../dialects/fixture/root.zig");
    const foreign = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    try testing.expect(region_cfg.indexOf(foreign.getBodyBlock()) == null);
}

test "region control-flow capacity matches an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionControlFlow, "choir_region_cfg_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionControlFlow, "choir_region_cfg_capacity_overload"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);
    const limits = try RegionControlFlow.Limits.inspect(fixture.module.getBody());
    try testing.expectEqual(@as(usize, 5), limits.facts.block_count);
    try testing.expectEqual(@as(usize, 4), limits.facts.edge_count);

    const capacity = try RegionControlFlow.Capacity.derive(limits);
    var expected: usize = 0;
    expected = std.mem.alignForward(
        usize,
        expected,
        @alignOf(RegionControlFlow.BlockInfo),
    );
    expected = try std.math.add(
        usize,
        expected,
        try std.math.mul(usize, 5, @sizeOf(RegionControlFlow.BlockInfo)),
    );
    inline for (.{ *ir.Block, *ir.Block, usize }, .{ 4, 4, 5 }) |T, count| {
        expected = std.mem.alignForward(usize, expected, @alignOf(T));
        expected = try std.math.add(
            usize,
            expected,
            try std.math.mul(usize, count, @sizeOf(T)),
        );
    }
    try testing.expectEqual(expected, capacity.working_bytes);

    var singleton = limits;
    singleton.facts = .{ .block_count = 1, .edge_count = 1 };
    try testing.expectEqual(
        @as(usize, 0),
        (try RegionControlFlow.Capacity.derive(singleton)).working_bytes,
    );
    var overflowing = limits;
    overflowing.facts.edge_count = std.math.maxInt(usize);
    try testing.expectError(
        error.CapacityOverflow,
        RegionControlFlow.Capacity.derive(overflowing),
    );
}

test "region control-flow acquires at most one exact backing region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionControlFlow, "choir_region_cfg_acquisition"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);
    const limits = try RegionControlFlow.Limits.inspect(fixture.module.getBody());
    const capacity = try RegionControlFlow.Capacity.derive(limits);
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var region_cfg = try RegionControlFlow.init(counting.allocator(), limits);
    defer region_cfg.deinit(counting.allocator());
    try testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try testing.expectEqual(capacity.working_bytes, counting.allocated_bytes);
    try region_cfg.activate();
    try testing.expectEqual(@as(usize, 5), region_cfg.blockCount());

    var empty_region = ir.Region.init(allocator);
    defer empty_region.deinit();
    const empty_limits = try RegionControlFlow.Limits.inspect(&empty_region);
    var empty_counting = std.testing.FailingAllocator.init(allocator, .{});
    var empty_cfg = try RegionControlFlow.init(
        empty_counting.allocator(),
        empty_limits,
    );
    defer empty_cfg.deinit(empty_counting.allocator());
    try testing.expectEqual(@as(usize, 0), empty_counting.alloc_index);
    try empty_cfg.activate();
    try testing.expectEqual(@as(usize, 0), empty_cfg.blockCount());

    var changed_region = ir.Region.init(allocator);
    defer changed_region.deinit();
    const stale_limits = try RegionControlFlow.Limits.inspect(&changed_region);
    _ = try changed_region.addBlock();
    try testing.expectError(
        error.RegionChanged,
        RegionControlFlow.init(allocator, stale_limits),
    );

    const test_dialect = @import("../dialects/fixture/root.zig");
    const single_module = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );
    const single_block = single_module.getBodyBlock();
    var builder = ir.OperationBuilder.init(&ctx);
    var branch_state = ir.Operation.State.init(
        test_dialect.TestDialect.BranchOp.operation_name,
        ir.Location.getUnknown(),
    );
    branch_state.addSuccessors(&.{single_block});
    const branch = try builder.create(branch_state);
    try single_block.addOperation(branch);
    const single_limits = try RegionControlFlow.Limits.inspect(
        single_module.getBody(),
    );
    var single_counting = std.testing.FailingAllocator.init(allocator, .{});
    var single_cfg = try RegionControlFlow.init(
        single_counting.allocator(),
        single_limits,
    );
    defer single_cfg.deinit(single_counting.allocator());
    try testing.expectEqual(@as(usize, 0), single_counting.alloc_index);
    try single_cfg.activate();
    try testing.expectEqual(@as(usize, 1), single_cfg.blockCount());
    try testing.expect(single_cfg.successors(single_block).?[0] == single_block);
    try testing.expect(single_cfg.predecessors(single_block).?[0] == single_block);
}

test "region control-flow queries remain allocation free after sealing" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionControlFlow, "choir_region_cfg_sealed_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionControlFlow, "choir_region_cfg_sealed_foreign_risk"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(allocator);
    var maybe_cfg: ?RegionControlFlow = null;
    defer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_cfg) |*region_cfg| {
            if (region_cfg.phase != .teardown) {
                region_cfg.deinit(phase_allocator.teardownAllocator());
            }
        }
        phase_allocator.deinit();
    }
    maybe_cfg = try RegionControlFlow.initForRegion(
        phase_allocator.initializationAllocator(),
        fixture.module.getBody(),
    );
    const region_cfg = &maybe_cfg.?;
    phase_allocator.seal();
    try region_cfg.activate();

    try testing.expectEqual(@as(usize, 5), region_cfg.blockCount());
    try testing.expect(region_cfg.entryBlock() == fixture.entry);
    try testing.expect(region_cfg.hasEdge(fixture.entry, fixture.then_block));
    try testing.expect(region_cfg.hasEdge(fixture.else_block, fixture.merge));
    try testing.expectEqual(@as(usize, 2), region_cfg.predecessors(fixture.merge).?.len);
    try testing.expectEqual(@as(u64, 0), phase_allocator.violations().total());
}

const RegionControlFlowFailureHarness = struct {
    fn run(allocator: std.mem.Allocator, region: *ir.Region) !void {
        var region_cfg = try RegionControlFlow.initForRegion(allocator, region);
        defer region_cfg.deinit(allocator);
        try region_cfg.activate();
        try std.testing.expectEqual(@as(usize, 5), region_cfg.blockCount());
    }
};

test "RegionControlFlow build retries every allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionControlFlow, "choir_region_cfg_oom"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);
    const region = fixture.module.getBody();

    try testing.checkAllAllocationFailures(allocator, RegionControlFlowFailureHarness.run, .{region});
    try RegionControlFlowFailureHarness.run(allocator, region);
}

test "DominanceAnalysis handles diamond and isolated roots" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);

    var cache = pass.AnalysisCache.init(allocator, null);
    defer cache.deinit();

    var pass_ctx = pass.PassContext.init(fixture.module.op, &ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const dominance = try getDominanceAnalysis(&pass_ctx, fixture.module.op);

    try testing.expect(dominance.dominatesBlock(fixture.entry, fixture.entry));
    try testing.expect(dominance.dominatesBlock(fixture.entry, fixture.then_block));
    try testing.expect(dominance.dominatesBlock(fixture.entry, fixture.else_block));
    try testing.expect(dominance.dominatesBlock(fixture.entry, fixture.merge));
    try testing.expect(!dominance.dominatesBlock(fixture.then_block, fixture.merge));
    try testing.expect(!dominance.dominatesBlock(fixture.else_block, fixture.merge));
    try testing.expect(!dominance.dominatesBlock(fixture.entry, fixture.unreachable_block));

    try testing.expect(dominance.dominatesOperation(fixture.then_value, fixture.then_term));
    try testing.expect(!dominance.dominatesOperation(fixture.then_term, fixture.then_value));
}

test "block dominance analysis derives exact aligned region capacity" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(BlockDominanceAnalysis, "choir_block_dominance_analysis_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(BlockDominanceAnalysis, "choir_block_dominance_analysis_capacity_overload"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    var cfg = try ControlFlowGraphAnalysis.initForOperation(
        allocator,
        fixture.root.op,
    );
    defer cfg.deinit(allocator);
    try cfg.activate();

    const limits = BlockDominanceAnalysis.Limits.inspect(&cfg, .forward);
    try testing.expectEqual(@as(usize, 3), limits.region_count);
    const capacity = try BlockDominanceAnalysis.Capacity.derive(limits);
    try testing.expectEqual(@as(usize, 3), capacity.region_count);
    try testing.expectEqual(
        3 * @sizeOf(RegionDominance),
        capacity.storage_bytes,
    );
    var overflowing = limits;
    overflowing.region_count = std.math.maxInt(usize);
    try testing.expectError(
        error.CapacityOverflow,
        BlockDominanceAnalysis.Capacity.derive(overflowing),
    );
}

test "block dominance analysis acquires one exact region owner array" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(BlockDominanceAnalysis, "choir_block_dominance_analysis_acquisition"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    var cfg = try ControlFlowGraphAnalysis.initForOperation(
        allocator,
        fixture.root.op,
    );
    defer cfg.deinit(allocator);
    try cfg.activate();

    const limits = BlockDominanceAnalysis.Limits.inspect(&cfg, .forward);
    const capacity = try BlockDominanceAnalysis.Capacity.derive(limits);
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var dominance = try BlockDominanceAnalysis.init(
        counting.allocator(),
        limits,
    );
    defer dominance.deinit(counting.allocator());
    try testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try testing.expectEqual(capacity.storage_bytes, counting.allocated_bytes);
    try dominance.activate();
    try testing.expect(regionDominancesOrdered(dominance.regions));
    for (cfg.regionSlice(), dominance.regions) |region_cfg, *region_dom| {
        try testing.expect(region_dom.regionPointer() == region_cfg.region);
        try testing.expect(
            dominance.getRegion(region_cfg.region) == region_dom,
        );
        const block = region_cfg.entryBlock().?;
        try testing.expect(region_dom.contains(block, block));
    }
    try testing.expect(!dominance.dominatesBlock(
        fixture.first.getBodyBlock(),
        fixture.second.getBodyBlock(),
    ));

    var empty_cfg = try ControlFlowGraphAnalysis.initForOperation(
        allocator,
        fixture.first_branch,
    );
    defer empty_cfg.deinit(allocator);
    try empty_cfg.activate();
    const empty_limits = BlockDominanceAnalysis.Limits.inspect(
        &empty_cfg,
        .forward,
    );
    var empty_counting = std.testing.FailingAllocator.init(allocator, .{});
    var empty_dominance = try BlockDominanceAnalysis.init(
        empty_counting.allocator(),
        empty_limits,
    );
    defer empty_dominance.deinit(empty_counting.allocator());
    try testing.expectEqual(@as(usize, 0), empty_counting.alloc_index);
    try empty_dominance.activate();
    try testing.expect(
        empty_dominance.getRegion(fixture.first.getBody()) == null,
    );
}

test "block dominance analysis queries remain allocation free after sealing" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(BlockDominanceAnalysis, "choir_block_dominance_analysis_sealed_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(BlockDominanceAnalysis, "choir_block_dominance_analysis_sealed_foreign_risk"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    var cfg = try ControlFlowGraphAnalysis.initForOperation(
        allocator,
        fixture.root.op,
    );
    defer cfg.deinit(allocator);
    try cfg.activate();
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(allocator);
    var maybe_dominance: ?BlockDominanceAnalysis = null;
    defer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_dominance) |*dominance| {
            if (dominance.phase != .teardown) {
                dominance.deinit(phase_allocator.teardownAllocator());
            }
        }
        phase_allocator.deinit();
    }
    maybe_dominance = try BlockDominanceAnalysis.init(
        phase_allocator.initializationAllocator(),
        BlockDominanceAnalysis.Limits.inspect(&cfg, .forward),
    );
    const dominance = &maybe_dominance.?;
    phase_allocator.seal();
    try dominance.activate();

    try testing.expect(dominance.dominatesBlock(
        fixture.first.getBodyBlock(),
        fixture.first.getBodyBlock(),
    ));
    try testing.expect(
        dominance.getRegion(fixture.second.getBody()) != null,
    );
    try testing.expectEqual(@as(u64, 0), phase_allocator.violations().total());
}

test "block dominance analysis survives independent CFG invalidation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(BlockDominanceAnalysis, "choir_block_dominance_analysis_independent"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    var cache = pass.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = pass.PassContext.init(
        fixture.root.op,
        &ctx,
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    const dominance = try getDominanceAnalysis(
        &pass_ctx,
        fixture.root.op,
    );
    try pass_ctx.preserveAnalysis(dominance_analysis_descriptor.id);
    cache.invalidate(&pass_ctx.preserved);

    try testing.expect(dominance.dominatesBlock(
        fixture.first.getBodyBlock(),
        fixture.first.getBodyBlock(),
    ));
    const cfg = try getControlFlowGraphAnalysis(
        &pass_ctx,
        fixture.root.op,
    );
    try testing.expect(cfg.getRegion(fixture.first.getBody()) != null);
    try testing.expect(
        dominance.getRegion(fixture.first.getBody()) != null,
    );
}

const BlockDominanceAnalysisFailureHarness = struct {
    fn run(
        allocator: std.mem.Allocator,
        cfg: *const ControlFlowGraphAnalysis,
    ) !void {
        var dominance = try BlockDominanceAnalysis.init(
            allocator,
            BlockDominanceAnalysis.Limits.inspect(cfg, .forward),
        );
        defer dominance.deinit(allocator);
        try dominance.activate();
        try std.testing.expectEqual(cfg.regionCount(), dominance.regions.len);
    }
};

test "BlockDominanceAnalysis build retries every allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(BlockDominanceAnalysis, "choir_block_dominance_analysis_oom"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildNestedControlFixture(&ctx);
    var cfg = try ControlFlowGraphAnalysis.initForOperation(
        allocator,
        fixture.root.op,
    );
    defer cfg.deinit(allocator);
    try cfg.activate();
    try testing.checkAllAllocationFailures(
        allocator,
        BlockDominanceAnalysisFailureHarness.run,
        .{&cfg},
    );
    try BlockDominanceAnalysisFailureHarness.run(allocator, &cfg);
}

test "region dominance capacity matches an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionDominance, "choir_region_dominance_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionDominance, "choir_region_dominance_capacity_overload"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);
    var region_cfg = try RegionControlFlow.initForRegion(
        allocator,
        fixture.module.getBody(),
    );
    defer region_cfg.deinit(allocator);
    try region_cfg.activate();
    const limits = RegionDominance.Limits.inspect(&region_cfg, .forward);
    try testing.expectEqual(@as(usize, 5), limits.block_count);

    const capacity = try RegionDominance.Capacity.derive(limits);
    var expected: usize = 0;
    inline for (.{ *ir.Block, bool, bool, bool }, .{ 5, 25, 5, 5 }) |T, count| {
        expected = std.mem.alignForward(usize, expected, @alignOf(T));
        expected = try std.math.add(
            usize,
            expected,
            try std.math.mul(usize, count, @sizeOf(T)),
        );
    }
    try testing.expectEqual(expected, capacity.working_bytes);
    try testing.expectEqual(@as(usize, 5), capacity.block_count);

    var singleton = limits;
    singleton.block_count = 1;
    try testing.expectEqual(
        @as(usize, 0),
        (try RegionDominance.Capacity.derive(singleton)).working_bytes,
    );
    var overflowing = limits;
    overflowing.block_count = std.math.maxInt(usize);
    try testing.expectError(
        error.CapacityOverflow,
        RegionDominance.Capacity.derive(overflowing),
    );
}

test "region dominance acquires at most one exact backing region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionDominance, "choir_region_dominance_acquisition"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);
    var region_cfg = try RegionControlFlow.initForRegion(
        allocator,
        fixture.module.getBody(),
    );
    defer region_cfg.deinit(allocator);
    try region_cfg.activate();
    const limits = RegionDominance.Limits.inspect(&region_cfg, .forward);
    const capacity = try RegionDominance.Capacity.derive(limits);
    var incompatible_limits = limits;
    incompatible_limits.block_count = 4;
    try testing.expectError(
        error.RegionChanged,
        RegionDominance.init(allocator, incompatible_limits),
    );
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var dominance = try RegionDominance.init(counting.allocator(), limits);
    defer dominance.deinit(counting.allocator());
    try testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try testing.expectEqual(capacity.working_bytes, counting.allocated_bytes);
    try dominance.activate();
    try testing.expect(dominance.contains(fixture.entry, fixture.merge));

    var empty_region = ir.Region.init(allocator);
    defer empty_region.deinit();
    var empty_cfg = try RegionControlFlow.initForRegion(allocator, &empty_region);
    defer empty_cfg.deinit(allocator);
    try empty_cfg.activate();
    const empty_limits = RegionDominance.Limits.inspect(&empty_cfg, .forward);
    var empty_counting = std.testing.FailingAllocator.init(allocator, .{});
    var empty_dominance = try RegionDominance.init(
        empty_counting.allocator(),
        empty_limits,
    );
    defer empty_dominance.deinit(empty_counting.allocator());
    try testing.expectEqual(@as(usize, 0), empty_counting.alloc_index);
    try empty_dominance.activate();
    try testing.expect(!empty_dominance.contains(fixture.entry, fixture.entry));

    const test_dialect = @import("../dialects/fixture/root.zig");
    const single_module = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );
    var single_cfg = try RegionControlFlow.initForRegion(
        allocator,
        single_module.getBody(),
    );
    defer single_cfg.deinit(allocator);
    try single_cfg.activate();
    const single_limits = RegionDominance.Limits.inspect(&single_cfg, .forward);
    var single_counting = std.testing.FailingAllocator.init(allocator, .{});
    var single_dominance = try RegionDominance.init(
        single_counting.allocator(),
        single_limits,
    );
    defer single_dominance.deinit(single_counting.allocator());
    try testing.expectEqual(@as(usize, 0), single_counting.alloc_index);
    try single_dominance.activate();
    const block = single_module.getBodyBlock();
    try testing.expect(single_dominance.contains(block, block));
}

test "region dominance queries remain allocation free after sealing" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionDominance, "choir_region_dominance_sealed_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionDominance, "choir_region_dominance_sealed_foreign_risk"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);
    var region_cfg = try RegionControlFlow.initForRegion(
        allocator,
        fixture.module.getBody(),
    );
    defer region_cfg.deinit(allocator);
    try region_cfg.activate();
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(allocator);
    var maybe_dominance: ?RegionDominance = null;
    defer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_dominance) |*dominance| {
            if (dominance.phase != .teardown) {
                dominance.deinit(phase_allocator.teardownAllocator());
            }
        }
        phase_allocator.deinit();
    }
    maybe_dominance = try RegionDominance.initForRegion(
        phase_allocator.initializationAllocator(),
        &region_cfg,
        .forward,
    );
    const dominance = &maybe_dominance.?;
    phase_allocator.seal();
    try dominance.activate();

    try testing.expect(dominance.contains(fixture.entry, fixture.merge));
    try testing.expect(!dominance.contains(fixture.then_block, fixture.merge));
    for (dominance.blockSlice()) |block| {
        try testing.expect(dominance.contains(block, block));
    }
    try testing.expectEqual(@as(u64, 0), phase_allocator.violations().total());
}

const RegionDominanceFailureHarness = struct {
    fn run(allocator: std.mem.Allocator, cfg: *const RegionControlFlow) !void {
        var dominance = try RegionDominance.initForRegion(
            allocator,
            cfg,
            .forward,
        );
        defer dominance.deinit(allocator);
        try dominance.activate();
        for (dominance.blockSlice()) |block| {
            try std.testing.expect(dominance.contains(block, block));
        }
    }
};

test "RegionDominance build retries every allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(RegionDominance, "choir_region_dominance_oom"),
        );
    }

    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);

    var region_cfg = try RegionControlFlow.initForRegion(
        allocator,
        fixture.module.getBody(),
    );
    defer region_cfg.deinit(allocator);
    try region_cfg.activate();

    try testing.checkAllAllocationFailures(allocator, RegionDominanceFailureHarness.run, .{&region_cfg});
    try RegionDominanceFailureHarness.run(allocator, &region_cfg);
}

test "PostDominanceAnalysis handles diamond exits" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const fixture = try buildDiamond(&ctx);

    var cache = pass.AnalysisCache.init(allocator, null);
    defer cache.deinit();

    var pass_ctx = pass.PassContext.init(fixture.module.op, &ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const post_dominance = try getPostDominanceAnalysis(&pass_ctx, fixture.module.op);

    try testing.expect(post_dominance.postDominatesBlock(fixture.merge, fixture.then_block));
    try testing.expect(post_dominance.postDominatesBlock(fixture.merge, fixture.else_block));
    try testing.expect(post_dominance.postDominatesBlock(fixture.merge, fixture.entry));
    try testing.expect(!post_dominance.postDominatesBlock(fixture.then_block, fixture.entry));
    try testing.expect(!post_dominance.postDominatesBlock(fixture.unreachable_block, fixture.entry));

    try testing.expect(post_dominance.postDominatesOperation(fixture.then_term, fixture.then_value));
    try testing.expect(!post_dominance.postDominatesOperation(fixture.then_value, fixture.then_term));
}

test "U0 control analysis refuses its declared work before building the graph" {
    const revision = @import("../product/revision/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const fixture = try buildDiamond(&context);
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .allocation_capacity = 1 << 20 },
        .workspace = 1 << 20,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var observed = std.testing.FailingAllocator.init(allocator, .{});
    var stats: pass.PassManagerStats = .{};
    var cache = try pass.AnalysisCache.initAccounted(
        observed.allocator(),
        &stats,
        ledger,
        .{},
        4,
    );
    defer cache.deinit();
    const before = observed.allocated_bytes;
    var ctx = pass.PassContext.init(fixture.module.op, &context, observed.allocator(), &cache);
    defer ctx.deinit();
    try std.testing.expectError(
        error.WorkExhausted,
        getControlFlowGraphAnalysis(&ctx, fixture.module.op),
    );
    try std.testing.expectEqual(before, observed.allocated_bytes);
    try std.testing.expectEqual(0, stats.analysis_misses);
    try std.testing.expectEqual(.exhausted, ledger.view().outcome);
    try std.testing.expectEqual(1, ledger.view().charged.analysis_computations);
}

const ControlComputation = enum {
    cfg,
    dominance,
    postdominance,

    fn get(self: ControlComputation, ctx: *pass.PassContext, op: *ir.Operation) !*anyopaque {
        return switch (self) {
            .cfg => @ptrCast(try getControlFlowGraphAnalysis(ctx, op)),
            .dominance => @ptrCast(try getDominanceAnalysis(ctx, op)),
            .postdominance => @ptrCast(try getPostDominanceAnalysis(ctx, op)),
        };
    }
};

test "U0 control accounting records nested CFG work and bounds observed allocations" {
    const revision = @import("../product/revision/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const fixture = try buildDiamond(&context);
    for (std.enums.values(ControlComputation)) |which| {
        const ledger = try revision.AccountingV1.create(allocator, .{
            .allowance = revision.WorkVector.uniform(1 << 20),
            .workspace = 1 << 20,
            .events = 8,
        }, &.{});
        defer ledger.destroy();
        var observed = std.testing.FailingAllocator.init(allocator, .{});
        var stats: pass.PassManagerStats = .{};
        var cache = try pass.AnalysisCache.initAccounted(
            observed.allocator(),
            &stats,
            ledger,
            .{},
            4,
        );
        defer cache.deinit();
        const before_bytes = observed.allocated_bytes;
        const before_charge = ledger.view().charged.allocation_capacity;
        var ctx = pass.PassContext.init(fixture.module.op, &context, observed.allocator(), &cache);
        defer ctx.deinit();
        const first = try which.get(&ctx, fixture.module.op);
        const receipt = ledger.view();
        try std.testing.expect(!receipt.missing_work_contract);
        const computations: u64 = if (which == .cfg) 1 else 2;
        try std.testing.expectEqual(computations, receipt.charged.analysis_computations);
        try std.testing.expectEqual(computations, stats.analysis_misses);
        try std.testing.expectEqual(computations, receipt.executed.work.analysis_computations);
        try std.testing.expectEqual(.analysis, receipt.events[1].phase);
        if (which != .cfg) try std.testing.expectEqual(1, receipt.events[2].parent.?);
        const allocated = observed.allocated_bytes - before_bytes;
        try std.testing.expect(allocated <= receipt.charged.allocation_capacity - before_charge);
        try std.testing.expect(receipt.maximum_live_storage >= observed.allocated_bytes);
        const allocations = observed.allocations;
        try std.testing.expectEqual(first, try which.get(&ctx, fixture.module.op));
        try std.testing.expectEqual(allocations, observed.allocations);
        try std.testing.expectEqualDeep(receipt.charged, ledger.view().charged);
        try std.testing.expectEqual(1, stats.analysis_hits);
        try ledger.producersComplete();
    }
}

const records = @import("../../../choir/root.zig").record;
const std = @import("std");
const choir = @import("choir");

const ir = choir.ir;

pub const kernel_outline_plan_analysis_name = "accy-choir-kernel-outline-plan";

pub const KernelOutlineKind = records.kernel.KernelOutlineKind;

pub const KernelOutline = struct {
    id: usize,
    name: []u8,
    kind: KernelOutlineKind,
    work_item_id: usize,
    root: *ir.Operation,
    input_slot_ids: []usize,
    output_slot_id: usize,
    element_count: u64,
    op_count: usize,

    pub fn inputCount(self: KernelOutline) usize {
        return self.input_slot_ids.len;
    }

    fn deinit(self: *KernelOutline, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.input_slot_ids);
        self.* = undefined;
    }
};

pub const KernelOutlinePlanAnalysis = struct {
    allocator: std.mem.Allocator,
    kernels: std.ArrayListUnmanaged(KernelOutline),
    work_to_kernel: std.AutoHashMap(usize, usize),
    total_input_slots: usize = 0,
    total_scheduled_ops: usize = 0,

    pub fn init(allocator: std.mem.Allocator) KernelOutlinePlanAnalysis {
        return .{
            .allocator = allocator,
            .kernels = .empty,
            .work_to_kernel = std.AutoHashMap(usize, usize).init(allocator),
        };
    }

    pub fn deinit(self: *KernelOutlinePlanAnalysis) void {
        for (self.kernels.items) |*kernel| {
            kernel.deinit(self.allocator);
        }
        self.kernels.deinit(self.allocator);
        self.work_to_kernel.deinit();
        self.* = undefined;
    }

    pub fn kernelCount(self: KernelOutlinePlanAnalysis) usize {
        return self.kernels.items.len;
    }

    pub fn getKernelForWork(
        self: *const KernelOutlinePlanAnalysis,
        work_item_id: usize,
    ) ?*const KernelOutline {
        const index = self.work_to_kernel.get(work_item_id) orelse return null;
        return &self.kernels.items[index];
    }
};

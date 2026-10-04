const std = @import("std");
const batch = @import("batch.zig");
const execute = @import("execute.zig");
const gradient = @import("grad.zig");
const lower = @import("lower.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const types = @import("type/root.zig");

pub const Function = struct {
    allocator: std.mem.Allocator,
    graph: program_mod.Program,
    root: ?*Function,
    derived: std.ArrayListUnmanaged(*Function),

    pub fn define(
        allocator: std.mem.Allocator,
        name: []const u8,
        specs: []const types.Spec,
        comptime body: anytype,
    ) !Function {
        return .{
            .allocator = allocator,
            .graph = try trace.define(allocator, name, specs, body),
            .root = null,
            .derived = .empty,
        };
    }

    pub fn deinit(self: *Function) void {
        std.debug.assert(self.root == null);
        for (self.derived.items) |child| {
            child.graph.deinit();
            self.allocator.destroy(child);
        }
        self.derived.deinit(self.allocator);
        self.graph.deinit();
        self.* = undefined;
    }

    pub fn grad(self: *Function, options: gradient.Options) !*Function {
        return self.adopt(try gradient.grad(self.allocator, &self.graph, options));
    }

    pub fn valueAndGrad(self: *Function, options: gradient.Options) !*Function {
        return self.adopt(try gradient.valueAndGrad(self.allocator, &self.graph, options));
    }

    pub fn vmap(self: *Function, options: batch.Options) !*Function {
        return self.adopt(try batch.vmap(self.allocator, &self.graph, options));
    }

    pub fn compileCpu(self: *const Function) !execute.Cpu {
        return execute.Cpu.init(self.allocator, &self.graph);
    }

    pub fn compileFragment(
        self: *const Function,
        handle: lower.BackendHandle,
        options: lower.FragmentCompilerOptions,
    ) !*lower.CompiledFragment {
        return lower.compileFragment(self.allocator, handle, &self.graph, options);
    }

    fn adopt(self: *Function, graph: program_mod.Program) !*Function {
        var owned = graph;
        errdefer owned.deinit();
        const root = self.root orelse self;
        const child = try root.allocator.create(Function);
        errdefer root.allocator.destroy(child);
        child.* = .{
            .allocator = root.allocator,
            .graph = owned,
            .root = root,
            .derived = .empty,
        };
        try root.derived.append(root.allocator, child);
        return child;
    }
};

fn productLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].mul(args[1]);
    return try product.sum(.lane);
}

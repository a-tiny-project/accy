const std = @import("std");
const ir = @import("../root.zig");
const rewrite = ir.rewrite;

pub const builtin_pattern_benefit: rewrite.PatternBenefit = 10;
pub const fold_pattern_benefit: rewrite.PatternBenefit = 100;

pub const DialectCanonicalizationInterface = struct {
    pub const interface_name = "choir.pass.dialect_canonicalization";
    pub const id: ir.InterfaceId = ir.interfaceId(interface_name);

    pub const VTable = struct {
        patterns: []const rewrite.RewritePattern,
    };

    fn entry(vtable: *const VTable) ir.InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime dialect_name: []const u8,
        comptime patterns: []const rewrite.RewritePattern,
    ) *const VTable {
        for (patterns, 0..) |pattern, index| {
            const separator = std.mem.indexOfScalar(u8, pattern.spec.root_op_name, '.') orelse
                @compileError("dialect canonicalization pattern root requires a dialect namespace");
            if (!std.mem.eql(u8, pattern.spec.root_op_name[0..separator], dialect_name)) {
                @compileError("dialect canonicalization pattern root must belong to its dialect");
            }
            if (pattern.spec.benefit <= builtin_pattern_benefit or
                pattern.spec.benefit >= fold_pattern_benefit)
            {
                @compileError("dialect canonicalization pattern benefit must remain between builtin and fold tiers");
            }
            for (patterns[0..index]) |previous| {
                if (!std.mem.eql(u8, previous.spec.root_op_name, pattern.spec.root_op_name)) continue;
                if (previous.spec.benefit < pattern.spec.benefit) {
                    @compileError("dialect canonicalization patterns must descend by benefit per root");
                }
            }
        }
        return &.{ .patterns = patterns };
    }

    pub fn entryFor(
        comptime dialect_name: []const u8,
        comptime patterns: []const rewrite.RewritePattern,
    ) ir.InterfaceEntry {
        return entry(vtableFor(dialect_name, patterns));
    }

    pub fn fromOpaque(ptr: *const anyopaque) *const VTable {
        return @ptrCast(@alignCast(ptr));
    }
};

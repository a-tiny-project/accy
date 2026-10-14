const std = @import("std");
const ir = @import("../core/root.zig");
const rewrite = ir.rewrite;
const passes = @import("../passes/root.zig");

pub const ConversionRewriteFn = *const fn (*ir.Operation, *rewrite.PatternRewriter) rewrite.PatternResult;

pub const ConversionPatternEntry = struct {
    spec: rewrite.RewritePatternSpec,
    rewrite: ConversionRewriteFn,
};

pub const ConversionLegalitySpec = struct {
    legal_ops: []const []const u8 = &.{},
    recursively_legal_ops: []const []const u8 = &.{},
    illegal_ops: []const []const u8 = &.{},
    legal_dialects: []const []const u8 = &.{},
    recursively_legal_dialects: []const []const u8 = &.{},
    illegal_dialects: []const []const u8 = &.{},

    pub fn apply(self: ConversionLegalitySpec, target: *passes.ConversionTarget) !void {
        for (self.legal_ops) |op_name| try target.addLegalOp(op_name);
        for (self.recursively_legal_ops) |op_name| try target.addRecursivelyLegalOp(op_name);
        for (self.illegal_ops) |op_name| try target.addIllegalOp(op_name);
        for (self.legal_dialects) |dialect_name| try target.addLegalDialect(dialect_name);
        for (self.recursively_legal_dialects) |dialect_name| try target.addRecursivelyLegalDialect(dialect_name);
        for (self.illegal_dialects) |dialect_name| try target.addIllegalDialect(dialect_name);
    }

    pub fn isLegalOpName(self: ConversionLegalitySpec, op_name: []const u8) bool {
        return containsName(self.legal_ops, op_name);
    }

    pub fn isRecursivelyLegalOpName(self: ConversionLegalitySpec, op_name: []const u8) bool {
        return containsName(self.recursively_legal_ops, op_name);
    }

    pub fn isIllegalOpName(self: ConversionLegalitySpec, op_name: []const u8) bool {
        return containsName(self.illegal_ops, op_name);
    }

    pub fn isLegalDialectName(self: ConversionLegalitySpec, dialect_name: []const u8) bool {
        return containsName(self.legal_dialects, dialect_name);
    }

    pub fn isRecursivelyLegalDialectName(self: ConversionLegalitySpec, dialect_name: []const u8) bool {
        return containsName(self.recursively_legal_dialects, dialect_name);
    }

    pub fn isIllegalDialectName(self: ConversionLegalitySpec, dialect_name: []const u8) bool {
        return containsName(self.illegal_dialects, dialect_name);
    }
};

pub const TargetSpec = struct {
    name: []const u8,
    description: []const u8 = "",
    target_dialect_name: []const u8,
    legality: ConversionLegalitySpec = .{},
    conversion_patterns: []const rewrite.RewritePatternSpec = &.{},
    pass_name: []const u8 = "",
    pass_description: []const u8 = "",
    pipeline_name: []const u8 = "",
    pipeline_description: []const u8 = "",

    pub fn applyLegality(self: TargetSpec, target: *passes.ConversionTarget) !void {
        try self.legality.apply(target);
    }

    pub fn conversionPatternRootCount(self: TargetSpec) usize {
        return self.conversion_patterns.len;
    }

    pub fn hasConversionPatternRoot(self: TargetSpec, root_op_name: []const u8) bool {
        for (self.conversion_patterns) |pattern| {
            if (std.mem.eql(u8, pattern.root_op_name, root_op_name)) return true;
        }
        return false;
    }

    pub fn marksIllegalOp(self: TargetSpec, op_name: []const u8) bool {
        return self.legality.isIllegalOpName(op_name);
    }

    pub fn legalizesDialect(self: TargetSpec, dialect_name: []const u8) bool {
        return self.legality.isLegalDialectName(dialect_name);
    }
};

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

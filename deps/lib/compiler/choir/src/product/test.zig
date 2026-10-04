const std = @import("std");
const product = @import("root.zig");
const hashing = @import("hashing/test.zig");
const revision = @import("revision/test.zig");

test {
    std.testing.refAllDecls(product);
    _ = hashing;
    _ = revision;
}

const revision_owner = product.revision;

const exhaustion = struct {
    const store_owner = revision_owner.store;
    const receipt = revision_owner.receipt;
    const record = revision_owner.record;

    const limits = store_owner.Limits{
        .revisions = 8,
        .kinds = 4,
        .builders = 4,
        .compiler_manifests = 2,
        .record_bytes = 16 * 1024,
        .gate_scratch_bytes = 1024,
        .candidate_count = 8,
        .screening_bytes = 16 * 1024,
    };

    const work = receipt.Limits{
        .allowance = receipt.WorkVector.uniform(4 * 1024 * 1024),
        .workspace = 1024 * 1024,
        .events = 32,
    };

    fn schema(input: store_owner.GateInput, scratch: []u8) !record.EntityCounts {
        if (scratch.len < 8) return error.OutOfMemory;
        scratch[0] = 0;
        if (input.exact.image.len == 0) return error.InvalidImage;
        if (input.exact.image[0] != 'v') return error.UnencodableProduct;
        var counts: record.EntityCounts = @splat(0);
        counts[@backingInt(record.Namespace.root)] = 1;
        return counts;
    }

    fn contract() store_owner.KindContract {
        return .{
            .identity = .{ .name = "exhaustion-fixture", .version = 1 },
            .schema = .{
                .identity = .{ .name = "exhaustion-fixture-schema", .version = 1 },
                .definition = "v prefix; one root",
                .scratch_bytes = 8,
                .run = schema,
            },
            .gates = &.{},
        };
    }

    fn request(kind: *const revision_owner.Kind) store_owner.Request {
        return .{
            .kind = kind,
            .address = .{ .producer = "test", .source = "source", .stage = "image", .variant = "" },
            .inputs = .{
                .compiler_manifest = "exact compiled inputs",
                .versions = &.{.{ .name = "codec", .version = 1 }},
                .pipeline = &.{},
                .options = "default=expanded",
                .policy = "strict",
            },
        };
    }

    fn publish(
        owner: *revision_owner.Store,
        kind: *const revision_owner.Kind,
        bytes: []const u8,
    ) !*const revision_owner.Revision {
        const builder = try owner.begin(request(kind), work);
        errdefer if (builder.abort(.rejected)) |failure| {
            var owned = failure;
            owned.deinit();
        };
        try builder.capture(bytes, &.{});
        return builder.seal(kind);
    }
};

test "CanonicalizationPass exhausted successor preserves its published ancestor" {
    const owner = try revision_owner.Store.create(std.testing.allocator, exhaustion.limits);
    defer owner.release();
    const kind = try owner.register(exhaustion.contract());
    owner.freeze();
    const ancestor = try exhaustion.publish(owner, kind, "valid-ancestor");
    defer ancestor.release();
    const before = ancestor.view();
    var request = exhaustion.request(kind);
    request.parent = ancestor;
    const builder = try owner.begin(request, exhaustion.work);
    var open = true;
    defer if (open) {
        if (builder.abort(.rejected)) |failed| {
            var failure = failed;
            failure.deinit();
        }
    };
    try runCanonicalizationLimit(builder.accounting());
    try std.testing.expectError(error.WorkExhausted, builder.capture("valid-successor", &.{}));
    try std.testing.expectError(error.InvalidBuilderState, builder.seal(kind));
    var failure = builder.abort(.rejected).?;
    open = false;
    defer failure.deinit();
    try std.testing.expectEqual(.exhausted, failure.work.outcome);
    try std.testing.expectEqual(1, failure.work.executed.counters.successful_rewrites);
    try std.testing.expectEqual(1, failure.work.executed.counters.rewrite_iterations);
    try std.testing.expectEqual(1, failure.work.executed.counters.passes_modified);
    try std.testing.expectEqual(1, failure.work.executed.counters.pass_runs);
    try std.testing.expectEqual(1, owner.publicationCount());
    try std.testing.expectEqualStrings("valid-ancestor", ancestor.view().exact.image);
    try std.testing.expectEqualDeep(before.event, ancestor.view().event);
    try std.testing.expectEqualDeep(before.digest, ancestor.view().digest);
    try std.testing.expectEqual(.success, ancestor.view().work.outcome);
}

fn runCanonicalizationLimit(ledger: *revision_owner.receipt.AccountingV1) !void {
    const choir = @import("../root.zig");
    const allocator = std.testing.allocator;
    var context = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try choir.ir.dialects.loadDialectSpec(&context, choir.dialects.arith.spec);
    const fixture = @import("../dialects/fixture/root.zig");
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const block = module.getBodyBlock();
    const arith = choir.dialects.ArithDialect;
    const typ = try arith.getScalarType(&context, .i32);
    const value = try block.addArgument(typ, .unknown);
    const zero = try arith.ConstantOp.createInt(&context, .unknown, typ, 0);
    try block.addOperation(zero.op);
    const add = try arith.AddOp.create(&context, .unknown, value, zero.getResult());
    try block.addOperation(add.op);
    var manager = choir.passes.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(choir.passes.CanonicalizationPass(.{
        .greedy_config = .{ .max_rewrites = 1 },
        .cleanup_dead_ops = false,
    }).init());
    var cache = try choir.passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    const result = manager.runWithAnalysisCache(module.op, &context, &cache, .{ .max_threads = 1 });
    try std.testing.expectEqual(.failure, result);
    try std.testing.expectEqual(.exhausted, manager.getLastFailureReproducer().?.failure_kind.?);
}

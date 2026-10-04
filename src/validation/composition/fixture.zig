const std = @import("std");
const choir = @import("choir");
const accy = @import("accy");
const executable = accy.executable;
const revision = choir.product.revision;
const operation = choir.product.operation;

pub const configuration = operation.Configuration{
    .context = choir.ir.Context.Limits.testing,
    .register = registerContext,
    .registration = .{ .name = "hybrid-composition-test-context", .version = 1 },
    .codec = .{ .operations = 1000, .entities = 10000, .fields = 10000, .depth = 64 },
    .image = .{ .bytes = 1024 * 1024, .entities = 10000, .depth = 64 },
    .roots = 1,
    .gate_scratch = 64 * 1024 * 1024,
    .verify = choir.ir.verify.default_options,
};

pub const artifact_workspace_bytes = 256 * 1024 * 1024;

fn registerContext(context: *choir.ir.Context) !void {
    try choir.dialects.registerChoirDialect(context);
    try accy.choir.registerAccyDialect(context);
    try choir.backends.gpu.registerTargetDialects(context);
}

pub fn request(source: []const u8, workspace: []u8) executable.FragmentCompilationRequest {
    return .{
        .source = source,
        .work = .{
            .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
            .workspace = 512 * 1024 * 1024,
            .events = 256,
        },
        .record_bytes = 32 * 1024 * 1024,
        .artifact_workspace = workspace,
    };
}

pub fn capture(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    address: revision.record.Address,
) !operation.Product {
    const store = try revision.Store.create(allocator, .{
        .revisions = 1,
        .kinds = 1,
        .builders = 1,
        .compiler_manifests = 2,
        .record_bytes = 32 * 1024 * 1024,
        .gate_scratch_bytes = configuration.gate_scratch,
        .candidate_count = 1,
        .screening_bytes = 32 * 1024 * 1024,
    });
    defer store.release();
    const kind = try operation.registerKind(allocator, store, configuration, .{
        .name = "composition-input",
        .version = 1,
    }, &.{});
    store.freeze();
    const policy = try choir.product.recipe.encode(allocator, .{
        .arithmetic = root.context.arithmetic_policy,
        .policy = "composition-input",
    });
    defer allocator.free(policy);
    const builder = try store.begin(.{
        .kind = kind,
        .address = address,
        .inputs = .{
            .compiler_manifest = try choir.product.compiler.manifest(),
            .versions = &.{operation.schema_identity},
            .pipeline = &.{},
            .options = "",
            .policy = policy,
        },
    }, request(address.source, &.{}).work);
    var open = true;
    defer if (open) {
        if (builder.abort(.rejected)) |failure| {
            var owned = failure;
            owned.deinit();
        }
    };
    try operation.capture(builder, &.{.{ .operation = root }}, "", &.{}, configuration);
    const result = try operation.Product.seal(builder, kind);
    open = false;
    return result;
}

const std = @import("std");
const model = @import("model.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn recipe(value: model.Recipe) [64]u8 {
    var hash = Sha256.init(.{});
    inline for (.{
        "schema",
        "id",
        "owner",
        "directory",
        "step",
        "class",
        "optimize",
        "target",
        "selection",
        "source",
        "test_cwd",
        "declaration",
        "declaration_sha256",
        "framework_sha256",
    }) |field| part(&hash, @field(value, field));
    count(&hash, value.argv.len);
    for (value.argv) |argument| part(&hash, argument);
    part(&hash, "runtime");
    count(&hash, value.runtime.len);
    for (value.runtime) |runtime| part(&hash, runtime);
    part(&hash, "environment");
    count(&hash, value.environment.len);
    for (value.environment) |pair| {
        part(&hash, pair.name);
        part(&hash, pair.value);
    }
    part(&hash, "suites");
    count(&hash, value.suites.len);
    for (value.suites) |suite| {
        part(&hash, suite.id);
        part(&hash, suite.backend);
        part(&hash, suite.selection_artifact);
        part(&hash, suite.result_artifact);
    }
    // Local records keep their historical identity. Nonlocal placement adds
    // a tagged extension, so it cannot reuse the digest of a local recipe.
    if (value.placement != .local) {
        part(&hash, "placement");
        part(&hash, @tagName(value.placement));
    }
    if (value.runner != .normalized) {
        part(&hash, "runner");
        part(&hash, @tagName(value.runner));
    }
    // An undeclared claim keeps the historical identity. A declared one binds
    // every field, so identity stays the hash of the canonical bytes.
    if (value.claim) |claim| {
        part(&hash, "claim");
        count(&hash, claim.memory_mib);
        count(&hash, claim.cpu);
        count(&hash, claim.peak_mib);
        part(&hash, claim.evidence);
    }
    // An undeclared product tree keeps the historical identity. A declared
    // one binds every field of its declaration.
    if (value.product_tree) |tree| {
        part(&hash, "product_tree");
        part(&hash, tree.mount);
        count(&hash, tree.inputs.len);
        for (tree.inputs) |input| part(&hash, input);
        count(&hash, tree.staging.len);
        for (tree.staging) |mapping| {
            part(&hash, mapping.from);
            part(&hash, mapping.to);
        }
        count(&hash, tree.environment.len);
        for (tree.environment) |pair| {
            part(&hash, pair.name);
            part(&hash, pair.value);
        }
        count(&hash, tree.policy.len);
        for (tree.policy) |word| part(&hash, word);
        count(&hash, tree.policy_version);
    }
    return finish(&hash);
}

pub fn sources(values: []const model.Source) [64]u8 {
    var hash = Sha256.init(.{});
    part(&hash, "tiny.build.validation-framework/v1");
    for (values) |value| {
        part(&hash, value.path);
        part(&hash, value.sha256);
    }
    return finish(&hash);
}

pub fn selection(binding: model.Binding, names: []const []const u8) [64]u8 {
    var hash = Sha256.init(.{});
    part(&hash, model.selection_schema);
    bind(&hash, binding);
    for (names) |name| part(&hash, name);
    return finish(&hash);
}

pub fn result(binding: model.Binding, selection_hash: []const u8, rows: anytype) [64]u8 {
    var hash = Sha256.init(.{});
    part(&hash, model.result_schema);
    bind(&hash, binding);
    part(&hash, selection_hash);
    for (rows) |row| {
        part(&hash, row.name);
        part(&hash, @tagName(row.status));
        hash.update(&.{@intFromBool(row.leaked)});
    }
    return finish(&hash);
}

fn bind(hash: *Sha256, binding: model.Binding) void {
    inline for (comptime std.meta.fieldNames(model.Binding)) |field| {
        part(hash, @field(binding, field));
    }
}

fn part(hash: *Sha256, value: []const u8) void {
    count(hash, value.len);
    hash.update(value);
}

fn count(hash: *Sha256, value: usize) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value), .little);
    hash.update(&length);
}

fn finish(hash: *Sha256) [64]u8 {
    var bytes: [32]u8 = undefined;
    hash.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

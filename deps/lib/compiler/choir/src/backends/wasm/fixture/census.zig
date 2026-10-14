const options = @import("wasm_node_options");

pub const qualified = options.path.len != 0;
pub const Validation = enum {
    backend_handle,
    verified_artifact,
    sealed_add,
    initialized_scalar,
    empty_module,
    declaration_module,
    sealed_snapshot,
    same_capacity_snapshot,
    owned_snapshot,
    allocation_completion,
    imported_call,
    imported_artifact,
    structured_memory,
    fixture_i32,
    fixture_i64,
    probe_leb,
    probe_address,
    probe_answer,
    probe_exit,
    probe_reply,
    probe_overflow,
    probe_deadline,
    probe_resistant,
};
pub const Negative = enum {
    signed_i32_leb,
    i64_memory_address,
    wrong_answer,
    exit_status,
    malformed_reply,
    truncated_reply,
    stdout_overflow,
    stderr_overflow,
    running_deadline,
    closed_pipe_deadline,
    resistant_deadline,
    resistant_overflow,
};
pub const Smoke = enum {
    backend_identity,
    verified_artifact,
    add,
    imported,
    fixture_i32,
    fixture_i64,
};
pub const validation_count = @typeInfo(Validation).@"enum".field_names.len;
pub const negative_count = @typeInfo(Negative).@"enum".field_names.len;
pub const smoke_count = @typeInfo(Smoke).@"enum".field_names.len;
var validations: [validation_count]u8 = @splat(0);
var negatives: [negative_count]u8 = @splat(0);
var smokes: [smoke_count]u8 = @splat(0);

fn record(comptime E: type, counts: []u8, identity: E) !void {
    const index = @backingInt(identity);
    if (qualified and counts[index] != 0) return error.DuplicateNodeObservation;
    counts[index] = 1;
}

pub fn validation(identity: Validation) !void {
    try record(Validation, &validations, identity);
}

pub fn negative(identity: Negative) !void {
    try record(Negative, &negatives, identity);
}

pub fn smoke(identity: Smoke) !void {
    try record(Smoke, &smokes, identity);
}

/// Called by the owning runner after every selected test has returned.
/// Runtime records prove presence independently of test discovery or order.
pub fn complete(selected: usize) !void {
    if (!qualified) return;
    if (selected == 0) return error.NoNodeQualificationTests;
    try requireComplete(&validations, error.MissingNodeValidation);
    try requireComplete(&negatives, error.MissingNodeNegative);
    try requireComplete(&smokes, error.MissingNodeSmoke);
}

pub fn requireComplete(counts: []const u8, missing: anyerror) !void {
    for (counts) |count| if (count != 1) return missing;
}

const implementation = @import("pass.zig");
const storage = @import("storage.zig");

pub const common_subexpression_elimination_pass_name =
    implementation.common_subexpression_elimination_pass_name;
pub const common_subexpression_elimination_pass_description =
    implementation.common_subexpression_elimination_pass_description;
pub const common_subexpression_elimination_pass_registration =
    implementation.common_subexpression_elimination_pass_registration;
pub const createCommonSubexpressionEliminationPass =
    implementation.createCommonSubexpressionEliminationPass;
pub const run = implementation.run;
pub const hasCandidateShape = storage.hasCandidateShape;
pub const inline_workspace_bytes = storage.inline_workspace_bytes;
pub const Table = storage.Table;
pub const Workspace = storage.Workspace;

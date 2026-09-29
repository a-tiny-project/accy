const output = @import("output.zig");
const parse = @import("parse.zig");
const repeated = @import("repeated.zig");
const spec = @import("spec.zig");

pub const AppSpec = spec.AppSpec;
pub const Commands = spec.Commands;
pub const parseApp = parse.parseApp;
pub const AppParseResult = parse.AppParseResult;
pub const Error = parse.Error;
pub const Repeated = repeated.Repeated;
pub const FieldMeta = spec.FieldMeta;
pub const dashedName = spec.dashedName;
pub const fieldMeta = spec.fieldMeta;
pub const isPositional = spec.isPositional;
pub const matchesCommand = spec.matchesCommand;
pub const positionalNames = spec.positionalNames;

pub const Output = output.Output;
pub const renderTableAlloc = output.renderTableAlloc;
pub const tableFrameLength = output.tableFrameLength;
pub const OutputMode = output.Mode;
pub const die = output.die;

const table = @import("table.zig");
const capacity = @import("capacity.zig");
const storage = @import("storage.zig");
const scratch = @import("workspace/root.zig");
const path = @import("path.zig");
const parser = @import("parser.zig");
const loading = @import("load.zig");
const state = @import("state.zig");

pub const max_sequence_length = table.max_sequence_length;
pub const max_output_bytes = table.max_output_bytes;
pub const max_nodes = table.max_nodes;
pub const max_include_depth = scratch.max_include_depth;
pub const max_file_bytes = scratch.max_file_bytes;
pub const max_registry_bytes = scratch.max_registry_bytes;
pub const max_path_bytes = scratch.max_path_bytes;
pub const default_system_directory = path.default_system_directory;
pub const default_scratch_limits = scratch.default_limits;

pub const Result = table.Result;
pub const Entry = table.Entry;
pub const Table = table.Table;
pub const View = table.View;
pub const Iterator = table.Iterator;
pub const Limits = capacity.Limits;
pub const Capacity = capacity.Capacity;
pub const Storage = storage.Storage;
pub const StorageStatus = storage.Status;
pub const Exhaustion = storage.StorageExhaustion;
pub const ScratchLimits = scratch.Limits;
pub const ScratchCapacity = scratch.Capacity;
pub const ScratchStorage = scratch.Storage;
pub const ScratchStatus = scratch.Status;
pub const ScratchExhaustion = scratch.Exhaustion;

pub const PathOptions = path.Options;
pub const xdgPath = path.xdg;
pub const homePath = path.home;
pub const localePath = path.locale;
pub const expandInclude = path.expandInclude;

pub const DiagnosticCode = parser.DiagnosticCode;
pub const Diagnostic = parser.Diagnostic;
pub const DiagnosticFn = parser.DiagnosticFn;
pub const ParserOptions = parser.Options;
pub const ParseError = parser.Error;
pub const parse = parser.parse;
pub const parseOpenedFile = parser.parseOpenedFile;

pub const Options = loading.Options;
pub const LoadError = loading.Error;
pub const compile = loading.compile;
pub const load = loading.load;

pub const Status = state.Status;
pub const FeedResult = state.FeedResult;
pub const TextError = state.TextError;
pub const State = state.State;

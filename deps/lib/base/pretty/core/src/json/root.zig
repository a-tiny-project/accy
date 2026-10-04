//! Deterministic JSON escaping, tree rendering, and allocation-free streaming.
//! Streaming scopes own punctuation and escaping; callers close every scope with `end`.

const document = @import("document.zig");
const escape = @import("escape.zig");
const field = @import("field.zig");
const format = @import("format.zig");
const scalar = @import("scalar.zig");
const sort = @import("sort.zig");
const stream = @import("stream.zig");

pub const Field = field.Field;
pub const Style = format.Style;
pub const Writer = stream.Writer;
pub const Object = stream.Object;
pub const Array = stream.Array;

pub const writeString = escape.writeString;
pub const writeStringParts = escape.writeStringParts;
pub const stringAlloc = escape.stringAlloc;

pub const writeMinified = format.writeMinified;
pub const writeMinifiedLine = format.writeMinifiedLine;
pub const renderMinifiedAlloc = format.renderMinifiedAlloc;
pub const renderMinifiedLineAlloc = format.renderMinifiedLineAlloc;
pub const writeIndented = format.writeIndented;
pub const renderIndentedAlloc = format.renderIndentedAlloc;

pub const writeSortedMinified = sort.writeSortedMinified;
pub const renderSortedMinifiedAlloc = sort.renderSortedMinifiedAlloc;

pub const writeNull = scalar.writeNull;
pub const writeBool = scalar.writeBool;
pub const writeInt = scalar.writeInt;
pub const writeNumberString = scalar.writeNumberString;

pub const writeFieldName = field.writeFieldName;
pub const writeFieldString = field.writeFieldString;
pub const writeFieldOptionalString = field.writeFieldOptionalString;
pub const writeFieldBool = field.writeFieldBool;
pub const writeFieldInt = field.writeFieldInt;
pub const writeFieldRaw = field.writeFieldRaw;

pub const valueDoc = document.valueDoc;
pub const renderValueAlloc = document.renderValueAlloc;
pub const writeValue = document.writeValue;
pub const writeValueWithState = document.writeValueWithState;

//! Bounded tables for compact terminal and agent output.
//! `Table` retains caller-sized storage; `table` returns one caller-owned allocation.

const cap = @import("cap.zig");
const table_mod = @import("table.zig");

pub const Align = table_mod.Align;
pub const Column = table_mod.Column;
pub const Table = table_mod.Table;
pub const TableLimits = table_mod.Limits;
pub const TableCapacity = table_mod.Capacity;
pub const TableRenderError = table_mod.RenderError;
pub const table = table_mod.table;
pub const cap16kb = cap.cap16kb;
pub const truncation_line = cap.truncation_line;
pub const full_cap = cap.full_cap;
pub const body_budget = cap.body_budget;

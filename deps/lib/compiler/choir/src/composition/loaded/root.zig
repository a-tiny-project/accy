//! Process-local fragment materialization, symbol lookup, invocation gating, and teardown.
//! A loaded composition owns runtime state; each invocation owns its mutable call frame.

pub const lifecycle = @import("lifecycle.zig");
pub const fragment = @import("fragment.zig");
pub const gate = @import("gate.zig");
pub const dispatch = @import("dispatch.zig");
pub const composition = @import("composition.zig");

pub const LifecycleEvent = lifecycle.LifecycleEvent;
pub const LifecycleObserver = lifecycle.LifecycleObserver;
pub const FragmentVTable = fragment.FragmentVTable;
pub const MaterializedFragment = fragment.MaterializedFragment;
pub const FragmentMaterializer = fragment.FragmentMaterializer;
pub const LoadedFragment = fragment.LoadedFragment;
pub const ValidationError = composition.ValidationError;
pub const EntryError = composition.EntryError;
pub const LoadedComposition = composition.LoadedComposition;
pub const invoke = dispatch.invoke;

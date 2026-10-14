//! One execution contract for every target that runs compiled Choir code.
//!
//! A default-qualified consumer builds `native.Runtime` with its limits, compiles or loads
//! modules into it, and calls through a checked pointer or checked call. It never names an
//! instruction set. Apple scalar execution has a target but no default product policy: an
//! inspected startup-linked, non-hardened product must call `initWithExecutablePolicy` with
//! its supported declaration. Ordinary `init` refuses that unverified mode before allocation;
//! `native.available` and `native.reason` describe ordinary initialization.

const host = @import("host.zig");
const image = @import("image.zig");
const runtime = @import("runtime.zig");
const target = @import("target.zig");
const value = @import("value.zig");

pub const Limits = @import("limits.zig").Limits;
pub const Handle = image.Handle;
pub const Emitted = image.Emitted;
pub const Placement = image.Placement;
pub const Homes = image.Homes;
pub const Value = value.Value;
pub const Vector = value.Vector;
pub const check = value.check;
pub const agrees = value.agrees;

pub const Runtime = runtime.Runtime;
pub const Refusal = runtime.Refusal;
pub const Math = runtime.Math;
pub const BindError = runtime.BindError;
pub const Reported = runtime.Reported;
pub const UnavailableError = runtime.UnavailableError;
pub const CapacityError = runtime.CapacityError;
pub const HandleError = runtime.HandleError;
pub const LookupError = runtime.LookupError;
pub const CallError = runtime.CallError;
pub const SymbolError = runtime.SymbolError;
pub const InitError = runtime.InitError;
pub const LoadError = runtime.LoadError;
pub const CompileError = runtime.CompileError;

pub const assertTarget = target.assertTarget;
pub const Bound = target.Bound;
pub const Bounds = target.Bounds;
pub const Excess = target.Excess;
pub const Refused = target.Refused;
pub const Unavailable = target.Unavailable;
pub const Builtin = target.Builtin;
pub const Failure = target.Failure;
pub const LowerError = target.LowerError;

pub const native = host.native;
pub const Select = host.Select;
pub const reason = host.reason;

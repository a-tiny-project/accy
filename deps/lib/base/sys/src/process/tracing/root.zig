//! A recorder that wants every file a program opens has to stop that program at
//! each syscall, attached from the start as the process that receives its
//! stops, the *tracer*. This namespace holds the Linux primitives for that:
//! launching a child held at a gate, attaching to it, waiting for its stops,
//! continuing it, and reading the syscall it stopped on.
//!
//! Attaching carries the fork, vfork, clone, exec, and exit-kill options, so
//! the tracer sees new descendants and the tracees die with it. One tracer owns
//! the wait domain, because the wait drains every child status change in the
//! calling process, so a second waiter in that process takes stops meant for
//! the tracer.
pub const launch = @import("launch.zig");
pub const operations = @import("operations.zig");
pub const start = launch.start;
pub const attach = operations.attach;
pub const wait = operations.wait;
pub const continueTask = operations.continueTask;
pub const listen = operations.listen;
pub const message = operations.message;
pub const terminate = operations.terminate;
pub const Event = operations.Event;
pub const Observation = operations.Observation;
pub const syscall = @import("syscall.zig");

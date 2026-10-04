//! A way to compile tensor programs for the host CPU inside the calling process and run them
//! directly on memory the caller supplies. A host program, possibly written in another language,
//! needs to compile and run array programs through a few calls and report failures across a
//! language boundary as plain numbers. A host that hands over large buffers wants them used in
//! place on every run. Host code can keep a program's name after it released the program, and a
//! reused slot would then run the wrong program.
//!
//! A table inside the host process (*session*) holds up to 64 compiled programs, which arrive as
//! versioned bytes and run on the CPU backend. Each compiled program is named by its slot and a
//! generation count that changes on release (*handle*), so a name kept past release is refused.
//! Runs use the caller's buffers in place wherever the plans allow, and inputs the program writes
//! are copied first so the caller's inputs stay unchanged. Every failure maps to one fixed number
//! that never changes meaning (*status code*).
//!
//! - *descriptor*: the element type, axes, byte length and alignment of one program input or
//!   output.
const session = @import("session.zig");

pub const Session = session.Session;
pub const Handle = session.Handle;
pub const Descriptor = session.Descriptor;
pub const Error = session.Error;
pub const Status = session.Status;
pub const max_programs = session.max_programs;

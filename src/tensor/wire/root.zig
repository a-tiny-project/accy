//! A way to write a tensor program as bytes and read it back, for hosts outside this process. A
//! host has to hand over a program, and this side has to accept only programs that are well typed.
//! Any host can send any bytes, and a layout that changes without notice breaks senders built
//! against the old one.
//!
//! Programs travel as versioned bytes (*wire bytes*) that begin with the four bytes "ACTP" and
//! version 1. The reader replays every operation through the same checked step that builds a
//! program one operation at a time, so the bytes cannot introduce a type that step did not derive.
//! The parts are the byte layout (`format`), the encoder (`encode`) and the decoder (`decode`).
pub const format = @import("format.zig");

pub const magic = format.magic;
pub const version = format.version;
pub const max_scan_depth = format.max_scan_depth;
pub const Error = format.Error;
pub const encode = @import("encode.zig").encode;
pub const decode = @import("decode.zig").decode;

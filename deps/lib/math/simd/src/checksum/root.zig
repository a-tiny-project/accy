//! Checksums of byte streams: CRC-32 folded by carryless multiplication,
//! and Adler-32 summed in vector lanes. Each returns the value of its
//! standard definition on every target, and falls back to tables or a byte
//! loop where the target lacks the instructions.

/// CRC-32/ISO-HDLC, the check of PNG chunks, gzip members and Ethernet
/// frames.
pub const crc = @import("crc.zig");
/// Adler-32, the check that ends a zlib stream.
pub const adler = @import("adler.zig");

pub const Crc32 = crc.Crc32;
pub const Adler32 = adler.Adler32;

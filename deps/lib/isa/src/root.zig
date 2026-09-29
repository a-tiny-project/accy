//! The package reads x86-64 machine code and describes the first instruction in
//! a byte slice as a structured value, calling no allocator. A caller walks a
//! stream of instructions by advancing past the length each decoded instruction
//! reports.
//!
//! A verifier has to know which instructions a program holds before the program
//! runs, and an executor has to know what each instruction reads and writes,
//! and both must read the same bytes the same way.
//!
//! x86-64 instructions vary in length up to 15 bytes, and optional prefix bytes
//! change how the rest is read, so every prefix combination has to be
//! recognized or refused. An allow list needs a compact, stable identity for
//! each kind of instruction, one that does not change when a register or a
//! constant does. What an instruction does to flags and memory is a question of
//! execution, which a decoder that stops at the encoding cannot settle.
//!
//! The
//! [Intel Software Developer's Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
//! define the x86-64 instruction format, and the decoder follows that format:
//! prefix bytes, a one-byte opcode table and a second table reached through the
//! escape byte 0x0F, a byte that selects registers or a memory address form
//! with an optional scaled-index byte, then displacement and immediate bytes,
//! at most 15 bytes in all.
//!
//! The decoder covers the instructions it models and returns a named error for
//! the rest, such as `error.UnsupportedOpcode` or
//! `error.UnsupportedAddressSize`. The decoder describes each instruction by
//! its shape as one 64-bit value (a *form*), and consumers compare that value
//! against allow lists, such as a kernel policy table searched by that value
//! and a loader that checks each decoded instruction against a recorded one.
//! That summary records the prefix combination, the opcode table and byte, the
//! operand width, the addressing mode, the role and access of each operand, and
//! for `int` its vector byte. That value leaves out register numbers,
//! displacements and immediate values, so a consumer that needs the exact bytes
//! checks them separately. Each decoded instruction also names what it does as
//! a numbered identity (an *operation*), such as `add` or `jne`, each belonging
//! to one family such as arithmetic or control. The numbers 0 to 48 are stored
//! in kernel policy, so new identities take new numbers and existing ones never
//! move. The decoded value reports operands, their read and write access, and
//! the registers an instruction uses implicitly, and the execution backends
//! keep the effects on flags and memory for themselves.

pub const x86 = @import("x86/root.zig");

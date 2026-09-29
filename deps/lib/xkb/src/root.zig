//! The package turns key presses into the symbols and text a program acts on:
//! it compiles a keyboard layout, tracks which modifier keys are in force, and
//! resolves sequences of key presses that produce one character.
//!
//! The operating system reports only a number for the key that moved, and a
//! program needs the letter or symbol that key means at that moment, and the
//! Unicode text it produces. What a key means depends on the alphabet in force
//! and on which modifier keys, such as Shift or Caps Lock, are held, latched
//! for the next key, or locked on. Some characters take a run of key presses,
//! as a dead accent key followed by a letter gives an accented letter.
//!
//! A layout arrives as text read at startup, so something has to compile it
//! into a table a key press can be looked up in. The three parts of the
//! modifier state change on different schedules, and the alphabet in force is a
//! sum of three parts that has to be brought back into range. Files that
//! describe multi-key sequences include other such files, so a loader with no
//! limits could follow includes forever or read a file of any size. A program
//! that wants a fixed memory footprint needs every table and every loader
//! workspace to have a size known in advance.
//!
//! [libxkbcommon](https://github.com/xkbcommon/libxkbcommon), the C library
//! Linux desktops use for keyboard handling, answers these for the X Keyboard
//! Extension layout format, and the package takes its semantics: layout
//! interpretation, modifiers, the names of key symbols and their Unicode
//! mappings, and the behavior of multi-key sequences (*Compose*). The package
//! generates tables for the 32-bit name of a key symbol (a *keysym*) from files
//! of libxkbcommon 1.13.2, each pinned by hash.
//!
//! The package is written in Zig and carries those semantics itself, and a
//! layout compiles into lookup tables (a *keymap*) with no C library involved.
//! One test step alone links the pinned library, running both implementations
//! over the same input and comparing the results (*differential conformance*),
//! so the lineage can be checked from this tree. A small state machine,
//! `state.State`, holds the three modifier masks (the *modifier state*) and the
//! three alphabet parts for one keyboard and, given a key number, answers with
//! its symbols and its Unicode text. Loading multi-key sequences parses into
//! workspace storage the caller supplies (a *scratch workspace*), which the
//! load takes at its start and gives back at its end. Every bound is fixed in
//! advance: a sequence of at most 10 key presses, at most 255 bytes of output
//! per sequence, at most 2^23 table nodes, and caps on include depth, file
//! bytes and path bytes.
//!
//! - *keycode*: the number the operating system reports for one physical key.
//! - *layout*: the index of the alphabet in force, which lets one keyboard
//!   carry more than one.
//! - *Compose table*: the trie of runs of key presses that produce one symbol,
//!   compiled from a Compose file, with a fixed bound on the length of a run
//!   and on the bytes one run produces.

pub const keysym = @import("keysym/root.zig");
pub const keymap = @import("keymap/root.zig");
pub const state = @import("state/root.zig");
pub const compose = @import("compose/root.zig");

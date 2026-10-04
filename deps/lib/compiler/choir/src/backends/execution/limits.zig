/// How much one execution runtime may hold at once. A caller picks a preset or states its own.
pub const Limits = struct {
    /// Bounds how many modules may be live at one time. `compile` and `loadArtifact`
    /// fail with `error.JitRuntimeFull` at this limit, and a `release` admits the next module.
    /// Bounds slots rather than bytes, backstopping against a host that retains handles without
    /// releasing them. Must be nonzero. A runtime built with zero asserts in a safe build and
    /// refuses every compile in an optimized one.
    live_modules: u32,

    /// Bounds the total bytes live modules may hold mapped, code and read-only data together,
    /// charging what the kernel reserves rather than what the emitter asked, because every
    /// mapping rounds up to a page. `compile` and `loadArtifact` fail with
    /// `error.JitRuntimeFull` before mapping anything when the next module would cross the
    /// budget, and a `release` admits the next module. Must be nonzero. A runtime built with
    /// zero refuses every module that emits code.
    mapped_bytes: u64,

    /// Bounds distinct registered external names, including the target's built-ins. A new
    /// name at the limit fails with `error.JitRuntimeFull` before allocating. Replacing an
    /// existing name costs no entry. Zero permits no registrations. Names remain registered
    /// until runtime teardown, so releasing a module does not return this budget. A host
    /// needing more names states a larger limit or rebuilds its runtime.
    ///
    /// Enumerated at da68c7979282, before the bound witnesses: each backend registers 18 math
    /// names plus malloc/free (20). Accy composition and the
    /// research sampler add one each (21); the largest Choir integration case adds two (22).
    /// Chant, Choir's profiling/versus hosts, Accy payload and the web recorder add none (20).
    /// Direct JIT tests registered at most two. `testing` admits the enumerated maximum of
    /// 22; `standard` is the smallest power of two covering it, 32. The default preserves
    /// callers that state only module and mapping limits. This bounds names, not their bytes.
    external_symbols: u32 = standard.external_symbols,

    /// Whether each compiled function keeps a line table, which the debug map and the
    /// debugger registration read. The table holds one entry per operation, 64 bytes each on
    /// x64, for as long as the module lives. A host that reads neither declines it.
    line_tables: bool = standard.line_tables,

    /// The limits a host gets when it states none of its own.
    ///
    /// Measured code mappings span 4 KiB to 152 KiB, a factor of 38, so 65,536 modules hold at
    /// least 256 MiB and at least 9.5 GiB respectively, and the count alone is a weak proxy for
    /// memory. Both figures are floors rather than totals, because the shapes measured carried
    /// no data symbols and this budget charges a module's data mapping too. 1 GiB narrows what
    /// the count admitted rather than restating it. A host that mapped more than 1 GiB while
    /// staying under the count compiled before this budget and is refused now. Such a host
    /// states its own limits or releases what it no longer runs. No known consumer
    /// comes near the figure, because every suite passes with it set to 16 MiB. The bounds cross
    /// at 16 KiB of charged bytes per module, the count binding below that average and the bytes
    /// above it.
    pub const standard: Limits = .{
        .live_modules = 64 * 1024,
        .mapped_bytes = 1024 * 1024 * 1024,
        .external_symbols = 32,
        .line_tables = true,
    };

    /// The limits the unit tests run under. The largest runtime under the suite holds 33 modules,
    /// and the suite passes within a byte budget of 512 KiB, so its peak holding is under that.
    /// Reaching 16 MiB therefore means a test leaked modules rather than outgrew the budget. A
    /// benchmark states `standard` even when a test drives the run, because the benchmark's
    /// workload governs its module count rather than the test harness.
    pub const testing: Limits = .{
        .live_modules = 256,
        .mapped_bytes = 16 * 1024 * 1024,
        .external_symbols = 22,
        .line_tables = true,
    };
};

test "JIT testing limits fit within standard limits" {
    const testing = @import("std").testing;
    try testing.expect(Limits.testing.live_modules <= Limits.standard.live_modules);
    try testing.expect(Limits.testing.mapped_bytes <= Limits.standard.mapped_bytes);
    try testing.expect(Limits.testing.external_symbols <= Limits.standard.external_symbols);
    const custom: Limits = .{ .live_modules = 1, .mapped_bytes = 4096 };
    try testing.expectEqual(Limits.standard.external_symbols, custom.external_symbols);
}

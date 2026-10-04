const sys = @import("sys");

pub const FragmentPhase = enum {
    run_contract_pipeline,
    run_tensor_pipeline,
    run_dispatch_pipeline,
    run_memory_pipeline,
    run_kernel_pipeline,
    run_target_pipeline,
    plan_create_backend_artifacts,
    compile_fragment,
    load_backend_artifacts,
    import_launch_tuning,

    pub fn name(self: FragmentPhase) []const u8 {
        return switch (self) {
            .run_contract_pipeline => "run_contract_pipeline",
            .run_tensor_pipeline => "run_tensor_pipeline",
            .run_dispatch_pipeline => "run_dispatch_pipeline",
            .run_memory_pipeline => "run_memory_pipeline",
            .run_kernel_pipeline => "run_kernel_pipeline",
            .run_target_pipeline => "run_target_pipeline",
            .plan_create_backend_artifacts => "plan_create_backend_artifacts",
            .compile_fragment => "compile_fragment",
            .load_backend_artifacts => "load_backend_artifacts",
            .import_launch_tuning => "import_launch_tuning",
        };
    }
};

pub const FragmentPhaseObserver = *const fn (?*anyopaque, []const u8, u64) anyerror!void;

pub const FragmentInstrumentation = struct {
    context: ?*anyopaque = null,
    observe: ?FragmentPhaseObserver = null,

    pub fn record(self: FragmentInstrumentation, phase_value: FragmentPhase, start_ns: i128) !void {
        const observe = self.observe orelse return;
        try observe(self.context, phase_value.name(), elapsedNs(start_ns));
    }

    pub fn recordElapsed(
        self: FragmentInstrumentation,
        phase_value: FragmentPhase,
        elapsed_ns: u64,
    ) !void {
        const observe = self.observe orelse return;
        try observe(self.context, phase_value.name(), elapsed_ns);
    }
};

fn elapsedNs(start: i128) u64 {
    const end = sys.time.nanoTimestamp();
    const delta = if (end >= start) end - start else 0;
    return @intCast(delta);
}

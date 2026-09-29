const std = @import("std");
const sys_build = @import("sys");
const profiling = @import("profiling.zig");
const tests = @import("tests.zig");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    validation: tests.Validation,
    benchmark: profiling.Graph,
) void {
    const operational_no_libc = sys_build.addNoLibcNeededCheck(b, .{
        .target = target,
        .step_name = "no-libc-needed",
        .description = "Check windowing operational artifacts do not require libc",
        .label = "windowing-no-libc-needed",
        .artifacts = &.{
            validation.library,
            validation.desktop,
            validation.properties,
            benchmark.no_libc_witness,
        },
        .strict_undefined = .all,
    });
    if (operational_no_libc) |check| {
        validation.test_step.dependOn(check);
        validation.property_step.dependOn(check);
    }
    const benchmark_no_libc = sys_build.addNoLibcNeededCheck(b, .{
        .target = target,
        .step_name = "bench-no-libc-test",
        .description = "Test that the LLVM windowing benchmark does not require libc",
        .label = "windowing-bench-no-libc-test",
        .artifacts = &.{benchmark.benchmark},
        .strict_undefined = .all,
    });
    if (benchmark_no_libc) |check| {
        benchmark.step.dependOn(check);
        benchmark.install_step.dependOn(check);
    }
    if (operational_no_libc) |operational_check| {
        const validate_step = b.step(
            "no-libc-validate",
            "Validate windowing artifacts across compiler backends",
        );
        validate_step.dependOn(operational_check);
        if (benchmark_no_libc) |benchmark_check| {
            validate_step.dependOn(benchmark_check);
        }
    }
}

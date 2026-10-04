const std = @import("std");
const coz = @import("root.zig");

const analysis = coz.analysis;
const debug_info = coz.debug_info;
const delay = coz.delay;
const experiment = coz.experiment;
const loaded_files = coz.loaded_files;
const path_filter = coz.path_filter;
const profile = coz.profile;
const profile_file = coz.profile_file;
const profiler = coz.profiler;
const progress_point = coz.progress_point;
const registry = coz.registry;
const runtime = @import("runtime.zig");
const sampler = coz.sampler;
const signals = coz.signals;
const source_map = coz.source_map;
const thread = coz.thread;

test "coz: package namespace" {
    _ = std;
    _ = analysis;
    _ = debug_info;
    _ = delay;
    _ = experiment;
    _ = loaded_files;
    _ = path_filter;
    _ = profile;
    _ = profile_file;
    _ = profiler;
    _ = progress_point;
    _ = registry;
    _ = sampler;
    _ = signals;
    _ = source_map;
    _ = thread;
    _ = runtime;
}

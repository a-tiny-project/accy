const model = @import("model.zig");
const native = @import("native.zig");
const parsing = @import("parse/root.zig");

pub const max_logical_processors = model.max_logical_processors;
pub const LogicalProcessorSet = model.LogicalProcessorSet;
pub const LP = model.LP;
pub const Cluster = model.Cluster;
pub const Core = model.Core;
pub const Package = model.Package;
pub const Cache = model.Cache;
pub const ProcessorRecord = model.ProcessorRecord;
pub const Topology = model.Topology;
pub const Error = model.Error;
pub const computeCacheSets = model.computeCacheSets;

pub const haveThreadingSupport = native.haveThreadingSupport;
pub const totalLogicalProcessors = native.totalLogicalProcessors;
pub const getThreadAffinity = native.getThreadAffinity;
pub const setThreadAffinity = native.setThreadAffinity;
pub const pinThreadToLogicalProcessor = native.pinThreadToLogicalProcessor;
pub const init = native.init;
pub const dataCaches = native.dataCaches;

pub const testing = struct {
    pub const CpuListOptions: type = parsing.CpuListOptions;
    pub const parseCpuList = parsing.cpuList;
    pub const parseNumberWithOptionalSuffix =
        parsing.numberWithOptionalSuffix;
    pub const computeCacheSets = model.computeCacheSets;
};

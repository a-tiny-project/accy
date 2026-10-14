const graph = @import("graph/root.zig");
const surface_factory = @import("builder/surface/root.zig");

const surface = surface_factory.Surface(graph.Program, .{});

pub const Index1D = surface.Index1D;
pub const VectorIndex1D = surface.VectorIndex1D;
pub const DomainAxis = surface.DomainAxis;
pub const Domain2D = surface.Domain2D;
pub const Domain3D = surface.Domain3D;
pub const Index2D = surface.Index2D;
pub const Index3D = surface.Index3D;
pub const Vec2 = surface.Vec2;
pub const Vec3 = surface.Vec3;
pub const TypedValue = surface.TypedValue;
pub const TypedVec2 = surface.TypedVec2;
pub const TypedVec3 = surface.TypedVec3;
pub const domainAxis = surface.domainAxis;
pub const BufferView = surface.BufferView;
pub const Program = graph.Program;
pub const Builder = surface.Builder;
pub const Limits = surface.Limits;
pub const Capacity = surface.Capacity;
pub const Guard = surface.Guard;
pub const define = surface.define;
pub const defineWithDiagnostic = surface.defineWithDiagnostic;

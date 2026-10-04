pub const StorageClass = struct {
    pub const UniformConstant: u32 = 0;
    pub const Input: u32 = 1;
    pub const Uniform: u32 = 2;
    pub const Output: u32 = 3;
    pub const Workgroup: u32 = 4;
    pub const CrossWorkgroup: u32 = 5;
    pub const Private: u32 = 6;
    pub const Function: u32 = 7;
    pub const PushConstant: u32 = 9;
    pub const StorageBuffer: u32 = 12;
};

pub const Scope = struct {
    pub const CrossDevice: u32 = 0;
    pub const Device: u32 = 1;
    pub const Workgroup: u32 = 2;
    pub const Subgroup: u32 = 3;
    pub const Invocation: u32 = 4;
    pub const QueueFamily: u32 = 5;
};

pub const MemorySemanticsMask = struct {
    pub const None: u32 = 0;
    pub const Acquire: u32 = 0x2;
    pub const Release: u32 = 0x4;
    pub const AcquireRelease: u32 = 0x8;
    pub const SequentiallyConsistent: u32 = 0x10;
    pub const UniformMemory: u32 = 0x40;
    pub const SubgroupMemory: u32 = 0x80;
    pub const WorkgroupMemory: u32 = 0x100;
    pub const CrossWorkgroupMemory: u32 = 0x200;
    pub const AtomicCounterMemory: u32 = 0x400;
    pub const ImageMemory: u32 = 0x800;
    pub const OutputMemory: u32 = 0x1000;
};

pub const Decoration = struct {
    pub const SpecId: u32 = 1;
    pub const Block: u32 = 2;
    pub const ArrayStride: u32 = 6;
    pub const BuiltIn: u32 = 11;
    pub const Flat: u32 = 14;
    pub const Location: u32 = 30;
    pub const Binding: u32 = 33;
    pub const DescriptorSet: u32 = 34;
    pub const Offset: u32 = 35;
    pub const NonWritable: u32 = 24;
    pub const NoContraction: u32 = 42;
};

pub const Capability = struct {
    pub const Shader: u32 = 1;
    pub const Float16: u32 = 9;
    pub const Float64: u32 = 10;
    pub const Int64: u32 = 11;
    pub const Int16: u32 = 22;
    pub const Int8: u32 = 39;
    pub const DerivativeControl: u32 = 51;
    pub const StorageBuffer16BitAccess: u32 = 4433;
    pub const UniformAndStorageBuffer16BitAccess: u32 = 4434;
    pub const StorageBuffer8BitAccess: u32 = 4448;
    pub const UniformAndStorageBuffer8BitAccess: u32 = 4449;
    pub const GroupNonUniform: u32 = 61;
    pub const GroupNonUniformVote: u32 = 62;
    pub const GroupNonUniformArithmetic: u32 = 63;
    pub const GroupNonUniformBallot: u32 = 64;
    pub const GroupNonUniformShuffle: u32 = 65;
    pub const GroupNonUniformShuffleRelative: u32 = 66;
    pub const DenormPreserve: u32 = 4464;
    pub const SignedZeroInfNanPreserve: u32 = 4466;
    pub const RoundingModeRTE: u32 = 4467;
};

pub const AddressingModel = struct {
    pub const Logical: u32 = 0;
};

pub const MemoryModel = struct {
    pub const GLSL450: u32 = 1;
};

pub const ExecutionModel = struct {
    pub const Vertex: u32 = 0;
    pub const Fragment: u32 = 4;
    pub const GLCompute: u32 = 5;
};

pub const ExecutionMode = struct {
    pub const OriginUpperLeft: u32 = 7;
    pub const LocalSize: u32 = 17;
    pub const DenormPreserve: u32 = 4459;
    pub const SignedZeroInfNanPreserve: u32 = 4461;
    pub const RoundingModeRTE: u32 = 4462;
};

pub const Dim = struct {
    pub const @"2D": u32 = 1;
};

pub const ImageFormat = struct {
    pub const Unknown: u32 = 0;
};

pub const ImageOperands = struct {
    pub const Lod: u32 = 0x2;
};

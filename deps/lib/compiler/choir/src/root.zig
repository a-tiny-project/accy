//! Multi-level intermediate representation framework with extensible
//! dialects and interned contexts.
//!
//! Dialects declare domain-specific operations, types, and attributes on top of
//! a common structural substrate (`Context`, `Operation`, `Block`, `Region`).
//! The shared context interns identifiers, types, and attributes, centralizing
//! memory ownership across dialect boundaries.
//!
//! `PassManager` coordinates transformation pipelines across IR regions. Callers
//! can opt into runtime structural verification with `enableVerifier`, checking
//! dominance, typing, and predecessor-successor symmetry between passes.

pub const ir = @import("core/root.zig");

pub const passes = @import("passes/root.zig");

pub const egraph = @import("egraph/root.zig");

pub const eval = @import("eval/root.zig");

pub const bytecode = @import("bytecode/root.zig");
pub const serialization = @import("serialization/root.zig");

pub const extensions = @import("extensions.zig");

pub const compiler = @import("compiler/root.zig");

pub const dialects = @import("dialects/root.zig");

pub const backends = @import("backends/root.zig");

pub const product = @import("product/root.zig");
pub const composition = @import("composition/root.zig");

pub const Context = ir.Context;
pub const Operation = ir.Operation;
pub const OperationEquivalence = ir.OperationEquivalence;
pub const OperationPropertiesModel = ir.OperationPropertiesModel;
pub const singleAttributePropertiesModel = ir.singleAttributePropertiesModel;
pub const OperationBuilder = ir.OperationBuilder;
pub const threading = ir.threading;
pub const ThreadingOptions = ir.ThreadingOptions;
pub const ThreadingPool = ir.ThreadingPool;
pub const Block = ir.Block;
pub const Region = ir.Region;
pub const Value = ir.Value;
pub const Type = ir.Type;
pub const Attribute = ir.Attribute;
pub const Location = ir.Location;
pub const Dialect = ir.Dialect;
pub const NamedAttribute = ir.NamedAttribute;
pub const NamedAttributeList = ir.NamedAttributeList;
pub const SymbolTable = ir.SymbolTable;
pub const inspection = ir.inspection;

pub const Pass = passes.Pass;
pub const PassManager = passes.PassManager;
pub const choir_optimization_package_extension = extensions.choir_optimization_package_extension;
pub const initCompilerContext = compiler.initContext;
pub const CompilerContextOptions = compiler.ContextOptions;
pub const CompilerSession = compiler.Session;

pub const StableHasher = product.StableHasher;
pub const StableValueNumbering = product.StableValueNumbering;
pub const OperationFingerprintError = product.OperationFingerprintError;
pub const operationFingerprint = product.operationFingerprint;
pub const OperationProduct = product.OperationProduct;

pub const diagnostics = @import("diagnostics/root.zig");

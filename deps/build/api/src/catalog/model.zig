pub const schema = "tiny.build.facts/v1";
pub const maximum_steps = 65536;
pub const maximum_modules = 16384;
pub const maximum_edges = 262144;
pub const maximum_arguments = 16384;
pub const maximum_bytes = 64 * 1024 * 1024;

pub const Path = struct {
    kind: enum { source, generated, relative, absent },
    value: []const u8 = "",
};

pub const Root = struct {
    name: []const u8,
    step: u32,
    registration_files: []const []const u8,
};

pub const Compile = struct {
    name: []const u8,
    kind: []const u8,
    module: u32,
};

pub const Argument = struct {
    kind: enum { bytes, artifact, path, directory, file_content, output, passthru },
    value: []const u8 = "",
    path: Path = .{ .kind = .absent },
    artifact: ?u32 = null,
    prefix: []const u8 = "",
    suffix: []const u8 = "",
};

pub const Run = struct {
    cwd: Path,
    arguments: []const Argument,
};

pub const Step = struct {
    name: []const u8,
    kind: []const u8,
    dependencies: []const u32,
    compile: ?Compile = null,
    run: ?Run = null,
};

pub const Import = struct {
    name: []const u8,
    module: u32,
};

pub const Module = struct {
    source: Path,
    imports: []const Import,
};

pub const Catalog = struct {
    schema: []const u8,
    build_root: []const u8,
    roots: []const Root,
    steps: []const Step,
    modules: []const Module,
};

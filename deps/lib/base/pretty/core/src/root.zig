//! Pretty is a width-aware document layout and structured output package.
//!
//! ### Design rationale and problem model
//!
//! Pretty printing separates declarative document structure from geometric
//! layout to resolve formatting choices without output backtracking:
//! formatters cannot determine whether an expression fits on a single line
//! until both the expression and its trailing syntactic context are known.
//! An algebraic tree (`Doc`) defers line-break selection to the renderer.
//!
//! The package enforces strict separation between construction and rendering:
//!
//! - Construction: `Builder` allocates AST nodes using any caller-supplied
//!   allocator, while text nodes borrow source slices. Callers bear the
//!   obligation of ensuring both allocated nodes and borrowed slices remain
//!   valid until rendering finishes.
//! - Traversal: The layout pass (`write`, `writeWithState`) performs zero
//!   dynamic allocation, streaming directly to a caller-owned `*std.Io.Writer`.
//!   Callers retain control over output buffering, flush timing, and I/O side
//!   effects, trading automated memory management for zero-allocation
//!   traversal. The output writer still owns its effects and allocations.
//!   `renderAlloc` owns an allocating writer and grows traversal storage from
//!   the caller allocator before output for documents beyond the D64 preset.
//!
//! ### Continuation-sensitive layout and mode inheritance
//!
//! Line-break decisions require continuation lookahead: evaluating a group
//! in isolation is insufficient because trailing tokens on the same line
//! (such as closing delimiters or commas) could force an immediate overflow.
//! The renderer therefore tests whether the candidate and its inline sibling
//! continuation fit the saturating remaining width `width -| col`.
//!
//! Mode inheritance is deliberately asymmetric:
//!
//! - A flat parent forces all descendant groups into flat mode, because an
//!   inner line break would contradict the parent's single-line commitment.
//! - A broken parent permits nested groups to choose independently, allowing
//!   localized compaction of sub-expressions within an expanded structure.
//!
//! Lookahead revisits subtrees to measure flat width prior to emission, and
//! preflight checks active depth before output. The renderer and fit lookahead
//! use bounded frame regions, with a small built-in preset or exclusive caller
//! workspace passed explicitly to `writeBounded`. LayoutOptions carries only
//! layout policy. Allocating entrypoints retain user-shaped depth behavior;
//! they grow only on preflight depth exhaustion, before output, with checked
//! u32 capacities ending at maxInt(u32). At most27 preflight attempts visit
//! at most27*N occurrences for an acyclic document. An arena may retain every
//! freed growth region, whose cumulative price is the sum of their layouts.
//! json.document.writeValueWithState still recursively constructs in an arena;
//! this traversal contract does not make that constructor sealed-clean.
//! Unconditional
//! breaks (`hardline`) emit a newline followed by the current nesting indentation
//! in all modes.
//!
//! ### Layout metrics, control breaks, and styling
//!
//! Column advancement strictly measures raw byte length (`bytes.len`),
//! omitting Unicode scalar, grapheme, and terminal display-width semantics.
//! Raw escape bytes inside text count as bytes. When indivisible text exceeds
//! the margin, it emits across it without error, prioritizing semantic data
//! preservation over rigid column boundaries.
//!
//! Only carriage returns and line feeds reset the column:
//!
//! - In text, `\r` and `\n` reset column tracking, where CR alone produces
//!   zero line feeds. They do not insert structural indentation.
//! - In soft breaks, alternatives containing CR or LF force broken mode to
//!   prevent broken control characters from polluting flat layout.
//!
//! Semantic styling (`styled`) emits ANSI sequences under `ColorMode.ansi`.
//! These escape sequences consume zero layout columns, ensuring monochrome
//! and styled outputs make identical line-break decisions.
//!
//! ### Worked example: Why continuation lookahead matters
//!
//! The trailing-continuation witness from `test.zig` demonstrates why groups
//! cannot evaluate fit in isolation:
//!
//! ```zig
//! const grouped = try builder.group(try builder.concat(&.{
//!     builder.text("abc"),
//!     pretty.softline,
//!     builder.text("de"),
//! }));
//! const doc = try builder.concat(&.{ grouped, builder.text("XY") });
//! ```
//!
//! At width 6, `grouped` alone has a flat width of 6 (`"abc de"`).
//! Evaluated in isolation, it would fit flat. However, trailing sibling
//! `"XY"` shares the same output line without an intervening break,
//! requiring 8 columns total.
//!
//! Continuation lookahead inspects `"XY"`, detects that $6 + 2 > 6$, and
//! forces `grouped` to break, emitting `"abc\ndeXY"` instead of overflowing
//! to `"abc deXY"`.
//!
//! ### Verification boundary
//!
//! Evidence is partitioned across formal models and test suites:
//!
//! - Formal model: A Lean specification proves
//!   compositionality and layout properties for finite trees over abstract
//!   byte classes (`cell`, `LF`, `CR`) and unbounded natural numbers (`Nat`).
//!   It assumes successful writes and omits continuation lookahead, machine
//!   `usize` saturation, and display width. No formal theorem proves that the
//!   Zig implementation refines the Lean specification.
//! - Empirical and capacity evidence: Automated unit tests in `test.zig` and
//!   Hypothesis property tests in `src/properties/` test ANSI neutrality,
//!   saturating arithmetic, and position composition, while bounded table
//!   capacity contracts are declared in `compact/table.zig`.

const types = @import("types.zig");
const builder_product = @import("builder.zig");
const render = @import("render.zig");

pub const json = @import("json/root.zig");
pub const compact = @import("compact/root.zig");
pub const diagnostic = @import("diagnostic.zig");

pub const default_width = types.default_width;
pub const LayoutOptions = types.LayoutOptions;
pub const ColorMode = types.ColorMode;
pub const Style = types.Style;
pub const Doc = types.Doc;
pub const Nested = types.Nested;
pub const Styled = types.Styled;
pub const WriteState = types.WriteState;
pub const TextWriter = @import("stream.zig").TextWriter;
pub const softline = types.softline;
pub const softbreak = types.softbreak;
pub const hardline = types.hardline;
pub const Builder = builder_product.Builder;
pub const RenderError = render.Error;
pub const FlatFitWriter = render.FlatFitWriter;
pub const renderAlloc = render.renderAlloc;
pub const write = render.write;
pub const writeWithState = render.writeWithState;
pub const writeWithFailure = render.writeWithFailure;
pub const writeBounded = render.writeBounded;
pub const writeBoundedWithState = render.writeBoundedWithState;
pub const preflightBounded = render.preflightBounded;

pub const Workspace = types.Workspace;
pub const RenderFailure = types.RenderFailure;
pub const RenderLimit = types.RenderLimit;
pub const DocContext = types.DocContext;
pub const WorkspaceLayout = render.WorkspaceLayout;
pub const default_render_depth = render.default_render_depth;
pub const default_workspace_bytes = render.default_workspace_bytes;
pub const workspace_alignment = render.workspace_alignment;
pub const workspaceLayout = render.workspaceLayout;
pub const workspaceBytes = render.workspaceBytes;
pub const builtinDepthFailure = render.builtinDepthFailure;
pub const preflight = render.preflight;

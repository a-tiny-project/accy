//! Runs tests by searching for inputs that make a test fail. A function that
//! draws its inputs and fails when the claim under test fails for them is a
//! *property*. Every draw goes through the run's data object, which appends the
//! choice with its kind, its value, and the bounds it was drawn within. The
//! recorded list of the draws a property made is the *choice sequence*. Because
//! the draws are recorded in order, a later run can feed the same sequence back
//! into the same generator and get the same input.
//!
//! The search for a smaller choice sequence that still fails is *shrinking*. A
//! generator can label a range of the choice sequence, opened and closed around
//! a part of the generator, as a *span*, which gives shrinking a unit to delete
//! or simplify. Shrinking replays a candidate sequence through the property and
//! keeps the candidate when the property still fails, within the run's shrink
//! budget. The passes delete spans, replace a span with its simplest value, and
//! reduce individual choices.
//!
//! A property can report a finite number to say how interesting its input was
//! as a *target score*, and the engine then spends a further budget mutating
//! the best-scoring sequence to raise that score.
//!
//! A failing sequence is saved to the directory called the *failure database*
//! and replayed first on the next run. Limits for one run, called *settings*,
//! bound a run by examples, replays, choices, input bytes, shrinks, and
//! targeted attempts, with `quick`, `dev`, and `ci` presets scaling all of them
//! together.

pub const conjecture = @import("conjecture.zig");
pub const strategies = @import("strategy.zig");
pub const composites = @import("composites.zig");
pub const engine = @import("engine.zig");
pub const shrinker = @import("shrinker.zig");
pub const database = @import("database.zig");
pub const report = @import("report.zig");
pub const stateful = @import("stateful.zig");
pub const swarm = @import("swarm.zig");
pub const coverage = @import("coverage.zig");
pub const artifact = @import("artifact.zig");
const testing = @import("testing.zig");
pub const autoderive = @import("auto.zig");
pub const value = @import("value.zig");

pub const auto = autoderive.auto;

pub const ConjectureData = conjecture.ConjectureData;
pub const ChoiceNode = conjecture.ChoiceNode;
pub const ChoiceKind = conjecture.ChoiceKind;
pub const Status = conjecture.Status;
pub const Span = conjecture.Span;
pub const DrawError = conjecture.DrawError;
pub const TargetError = conjecture.TargetError;
pub const TargetObservation = conjecture.TargetObservation;
pub const Strategy = strategies.Strategy;
pub const Config = value.Config;
pub const Generator = value.Generator;

pub const check = testing.check;
pub const checkNamed = testing.checkNamed;
pub const forAll = testing.forAll;
pub const forAllNamed = testing.forAllNamed;
pub const fuzz = testing.fuzz;
pub const fuzzWithSettings = testing.fuzzWithSettings;
pub const checkFn = engine.run;
pub const Settings = engine.Settings;
pub const TestResult = engine.TestResult;
pub const FuzzInputOptions = testing.FuzzInputOptions;
pub const Coverage = coverage.Counters;
pub const CoverageCounts = coverage.Counts;
pub const integer = value.integer;
pub const float32 = value.float32;
pub const float64 = value.float64;
pub const boolean = value.boolean;
pub const bytes = value.bytes;
pub const BoundedArray = value.BoundedArray;
pub const list = value.list;
pub const fixedArray = value.fixedArray;
pub const tuple = value.tuple;
pub const oneOf = value.oneOf;
pub const target = conjecture.target;
pub const gen_point = value.gen_point;
pub const gen_unit_vec3 = value.gen_unit_vec3;
pub const gen_quaternion = value.gen_quaternion;
pub const checkValue = value.checkValue;
pub const checkValueAlloc = value.checkValueAlloc;

pub const ReplayCursor = @import("database.zig").ReplayCursor;

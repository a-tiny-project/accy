//! Structured command facts, terminal policy, help rendering, and typo suggestions.
//! One `Help` tree drives command lookup, aliases, usage errors, and rendered help.

pub const pretty = @import("pretty");
pub const command = @import("command/root.zig");
pub const types = @import("types.zig");
pub const terminal = @import("terminal.zig");
pub const render = @import("render.zig");

pub const UsageTextStyles = types.UsageTextStyles;
pub const UsageTextOptions = types.UsageTextOptions;
pub const HelpStyles = types.HelpStyles;
pub const HelpOptions = types.HelpOptions;
pub const TerminalOptions = types.TerminalOptions;
pub const ErrorTextOptions = types.ErrorTextOptions;
pub const HelpErrorOptions = types.HelpErrorOptions;
pub const CommandSuggestionOptions = types.CommandSuggestionOptions;
pub const CommandSuggestion = types.CommandSuggestion;
pub const CommandSuggestionWriteOptions = types.CommandSuggestionWriteOptions;
pub const CommandHelpErrorOptions = types.CommandHelpErrorOptions;
pub const CommandPathHelpErrorOptions = types.CommandPathHelpErrorOptions;
pub const Help = types.Help;
pub const CommandPathMissing = types.CommandPathMissing;
pub const Usage = types.Usage;
pub const CommandUsage = types.CommandUsage;
pub const BuildUsage = types.BuildUsage;
pub const CommandGroup = types.CommandGroup;
pub const Command = types.Command;
pub const Argument = types.Argument;
pub const Option = types.Option;
pub const OptionGroup = types.OptionGroup;
pub const Section = types.Section;
pub const SectionRow = types.SectionRow;
pub const Example = types.Example;
pub const isHelpArg = types.isHelpArg;
pub const hasHelpArg = types.hasHelpArg;
pub const suggestionDistance = types.suggestionDistance;

pub const Terminal = terminal.Terminal;
pub const layoutOptions = terminal.layoutOptions;
pub const terminalWidth = terminal.terminalWidth;
pub const terminalColorMode = terminal.terminalColorMode;
pub const writeStdoutUsageText = terminal.writeStdoutUsageText;
pub const writeStderrUsageText = terminal.writeStderrUsageText;
pub const writeStdoutHelp = terminal.writeStdoutHelp;
pub const writeStderrHelp = terminal.writeStderrHelp;
pub const writeFileUsageText = terminal.writeFileUsageText;
pub const writeFileUsageTextFmt = terminal.writeFileUsageTextFmt;
pub const writeFileHelp = terminal.writeFileHelp;
pub const writeFileErrorText = terminal.writeFileErrorText;
pub const writeFileErrorTextFmt = terminal.writeFileErrorTextFmt;
pub const writeFileWarningText = terminal.writeFileWarningText;
pub const writeFileWarningTextFmt = terminal.writeFileWarningTextFmt;

pub const writeUsageText = render.writeUsageText;
pub const writeHelp = render.writeHelp;
pub const writeHelpError = render.writeHelpError;
pub const writeCommandHelpOrError = render.writeCommandHelpOrError;
pub const writeCommandPathHelpOrError = render.writeCommandPathHelpOrError;
pub const writeCommandSuggestion = render.writeCommandSuggestion;
pub const renderUsageTextAlloc = render.renderUsageTextAlloc;
pub const renderHelpAlloc = render.renderHelpAlloc;
pub const writeErrorText = render.writeErrorText;
pub const renderErrorTextAlloc = render.renderErrorTextAlloc;

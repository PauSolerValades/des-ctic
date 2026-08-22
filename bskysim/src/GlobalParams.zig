/// GlobalParams: global input parameters of the simulation.
/// They are the following:
/// - seed: control randomness
/// - horizion: maximum timestamp of the simulation
/// - duration: duration of the main simuation
/// - warmup_time: timestamp where warmup ends
/// - user_policy: Categorical with (repost, like, and ignore)
/// - user_inter_action: time between two user actions
/// - propagation_delay: time that a post from being propagated into appear in another user timeline.
/// - interaction_delay: time between a user initiating the action and actually performing the action
/// - creation_delay: time between a user deciding to create the post and the actual post being created
/// - offline_startup_ratio: which proportion of the users start in vacation
/// - gap_shift: constant added to every sampled inter-session gap. The gap
///   distributions are fitted on (gap - eps) after session clustering with
///   DBSCAN eps=300, so the shift must be reapplied here. Required so the
///   user is always aware that gaps may be shifted.
/// - trace_to_file: should the simulation write the traces?
const std = @import("std");

const Random = std.Random;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const json = std.json;
const Scanner = std.json.Scanner;
const Token = std.json.Token;

const entities = @import("entities.zig");

const stats = @import("distributions");
const NNContDist = stats.NonNegativeContinuousDistribution;
const DiscDist = stats.DiscreteDistribution;

const Categorical = stats.Categorical;

const parse = @import("dist-json-parse/parse.zig");
const ParseError = parse.ParseError;
const JsonScannerError = parse.JsonScannerError;
const ReadFileError = std.Io.Dir.ReadFileAllocError;
const readKeyNumber = parse.readKeyNumber;
const readKeyBool = parse.readKeyBool;
const readKeyString = parse.readKeyString;

pub const GlobalConfigError = error{
    NegativeHorizon,
    NegativeDuration,
    NegativeWarmup,
    DurationBiggerThenHorizon,
};

const Field = blk: {
    const fields = @typeInfo(@This()).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var vals: [fields.len]u8 = undefined;
    for (fields, 0..) |f, i| {
        names[i] = f.name;
        vals[i] = i;
    }
    break :blk @Enum(u8, .exhaustive, &names, &vals);
};

const DistTag = std.meta.Tag(NNContDist(f32));

seed: ?u64,
// time marks
horizon: f64, // max duration of the simulation
duration: f64, // Duration of the simulation
warmup_time: f64, // time when warmup ends
// user related actions
user_policy: Categorical(f32, entities.Action),
user_inter_action: NNContDist(f32), // time between a user two actions
// delays on posts transmissions
propagation_delay: NNContDist(f32), // time between an action over a post and showing up followers timeline
interaction_delay: NNContDist(f32), // time between
creation_delay: NNContDist(f32),
// session configuration
offline_startup_ratio: f32, // which proportion of the users start on vacation
gap_shift: f64, // added to every sampled inter-session gap (see header)
trace_to_file: bool,

/// Opens the json file and loads the distributions in memory
pub fn create(io: Io, gpa: Allocator, config_file: []const u8, stderr: *Io.Writer) (parse.ParseError || parse.JsonScannerError || Io.Dir.ReadFileAllocError || json.ParseError(Scanner) || error{ InvalidCharacter, WriteFailed })!@This() {
    const content = try Io.Dir.cwd().readFileAlloc(io, config_file, gpa, .unlimited);
    defer gpa.free(content);

    var scanner = Scanner.initCompleteInput(gpa, content);
    defer scanner.deinit();

    if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

    var config: @This() = undefined;
    const num_fields: usize = @typeInfo(Field).@"enum".fields.len;
    var have: std.StaticBitSet(num_fields) = .empty;

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.object_end) break;
        if (tok != Token.string) return error.UnexpectedToken;

        const field = std.meta.stringToEnum(Field, tok.string) orelse {
            try stderr.print("Parameter '{s}' is not an input parameter of the simulation\n", .{tok.string});
            return error.UnknownParameter;
        };

        // bit index == enum value, so name lookup stays free
        have.set(@intFromEnum(field));

        switch (field) {
            .seed => config.seed = @intFromFloat(try readKeyNumber(&scanner, f64)),
            .horizon => config.horizon = try readKeyNumber(&scanner, f64),
            .duration => config.duration = try readKeyNumber(&scanner, f64),
            .warmup_time => config.warmup_time = try readKeyNumber(&scanner, f64),
            .user_policy => config.user_policy = try parse.parseUserPolicyCategorical(gpa, &scanner, stderr),
            .user_inter_action => config.user_inter_action = try parse.parseNonNegativeContinuousDist(&scanner, stderr, "user_inter_action"),
            .propagation_delay => config.propagation_delay = try parse.parseNonNegativeContinuousDist(&scanner, stderr, "propagation_delay"),
            .interaction_delay => config.interaction_delay = try parse.parseNonNegativeContinuousDist(&scanner, stderr, "interaction_delay"),
            .creation_delay => config.creation_delay = try parse.parseNonNegativeContinuousDist(&scanner, stderr, "creation_delay"),
            .offline_startup_ratio => config.offline_startup_ratio = try readKeyNumber(&scanner, f32),
            .gap_shift => config.gap_shift = try readKeyNumber(&scanner, f64),
            .trace_to_file => config.trace_to_file = try readKeyBool(&scanner),
        }
    }

    if (have.count() != num_fields) {
        inline for (@typeInfo(Field).@"enum".fields) |f| {
            if (!have.isSet(f.value)) try stderr.print("missing field: '{s}'\n", .{f.name});
        }
        return error.MissingField;
    }
    return config;
}

pub fn delete(self: *const @This(), gpa: Allocator) void {
    gpa.free(self.user_policy.weights);
    gpa.free(self.user_policy.data);
    self.user_policy.deinit(gpa);
}

pub fn checkValidity(self: *const @This()) (error{OutOfMemory} || GlobalConfigError || error{WriteFailed})!void {
    if (self.horizon <= 0) return error.NegativeHorizon;
    if (self.duration <= 0) return error.NegativeDuration;
    if (self.warmup_time < 0) return error.NegativeWarmup;

    if (self.warmup_time + self.duration > self.horizon) return error.DurationBiggerThenHorizon;
}

pub fn format(
    self: *const @This(),
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("\n");
    try writer.writeAll("+--------------------------+\n");
    try writer.print("| SIMULATION CONFIGURATION |\n", .{});
    try writer.writeAll("+--------------------------+\n");

    try writer.writeAll("--- User Actions Config ---\n");
    try writer.print("{s: <24}:  {f}\n", .{ "User policy", self.user_policy });
    try writer.print("{s: <24}:  {f}\n", .{ "Time between actions", self.user_inter_action });

    try writer.writeAll("--- Post Propagation Delays ---\n");
    try writer.print("{s: <24}:  {f}\n", .{ "Propagation delay", self.propagation_delay });
    try writer.print("{s: <24}:  {f}\n", .{ "Interaction delay", self.interaction_delay });
    try writer.print("{s: <24}:  {f}\n", .{ "Creation delay", self.creation_delay });

    try writer.writeAll("--- User Sessions (Vacations) ---\n");
    try writer.print("{s: <24}:  {d}\n", .{ "% starting offline", self.offline_startup_ratio });
    try writer.writeAll("--- Misc ---\n");
    try writer.print("{s: <24}:  {}\n", .{ "Trace to file", self.trace_to_file });
    try writer.writeAll("---------------------------------\n");
    try writer.print("{s: <24}:  {d: <23.2}\n", .{ "Warm-up (Time)", self.warmup_time });
    try writer.print("{s: <24}:  {d: <23.2}\n", .{ "Duration", self.duration });
    try writer.print("{s: <24}:  {d: <23.2}\n", .{ "Horizon (Time)", self.horizon });
}

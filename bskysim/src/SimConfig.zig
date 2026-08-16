/// SimConfig: Input parameters of the simulation.
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

pub const Precision: type = f32;

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
trace_to_file: bool,
//the config
users: []UserConf,

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
            .offline_startup_ratio => config.offline_startup_ratio = try readKeyNumber(&scanner, Precision),
            .trace_to_file => config.trace_to_file = try readKeyBool(&scanner),
            .users => config.users = try parse.parseUsers(gpa, &scanner, stderr),
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

    for (self.users) |u| {
        gpa.free(u.session_params_path);
        gpa.free(u.gap_params_path);
        gpa.free(u.ecdf_post_creation_path);
        gpa.free(u.ecdf_offset_creation_path);
    }
    gpa.free(self.users);
}

pub fn isValid(self: *const @This(), io: Io, stderr: *Io.Writer) (error{OutOfMemory} || ConfigError || error{WriteFailed})!void {
    if (self.horizon <= 0) return error.NegativeHorizon;
    if (self.duration <= 0) return error.NegativeDuration;
    if (self.warmup_time <= 0) return error.NegativeWarmup;

    if (self.warmup_time + self.duration > self.horizon) return error.DurationBiggerThenHorizon;

    const Pair = struct {
        first: DistTag,
        second: DistTag,
    };

    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();

    var pairs: ArrayList(Pair) = .empty;
    defer pairs.deinit(allocator);

    var acc_prob: f32 = 0.0;
    for (self.users, 0..) |u, i| {
        const pair = .{ @tagName(u.session_duration), @tagName(u.inter_session_time) };

        std.Io.Dir.cwd().access(io, u.ecdf_post_creation_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): ecdf_post_creation_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.ecdf_post_creation_path, @errorName(err) });
            return error.EcdfPostFileError;
        };
        std.Io.Dir.cwd().access(io, u.session_params_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): session_params_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.session_params_path, @errorName(err) });
            return error.SampleParamsFileError;
        };
        std.Io.Dir.cwd().access(io, u.gap_params_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): gap_params_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.gap_params_path, @errorName(err) });
            return error.SampleParamsFileError;
        };
        std.Io.Dir.cwd().access(io, u.ecdf_offset_creation_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): ecdf_offset_creation_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.ecdf_offset_creation_path, @errorName(err) });
            return error.EcdfOffsetFileError;
        };
        acc_prob += u.probability;

        // this should be not very big, a small linear search won't hurt anyone
        for (pairs.items) |p| {
            if (p.first == u.session_duration and p.second == u.inter_session_time) return error.RepeatedUserPair;
        }
        // terrorism
        try pairs.append(allocator, .{ .first = u.session_duration, .second = u.inter_session_time });
    }

    // TODO: check that the Distribution picked to generate the posts is not able to
    // generate a post later than warmup_time. that is:
    // warmup_inter_post_time.sample(rng) <= conf.warmup_time <==> P(x > conf.warmup_time) = 0 <==> 1 - F(x) = 0
    // warmup_inter_post_time.cdf(conf.warmup_time) = 1
    // the problem is that not all the distributions implemented have cdf, and they are not even tested lolol
    // therefore, we will ---for now--- trust the user

    // TODO: make a reasonable tolerance, not just made up
    if (!std.math.approxEqRel(f32, acc_prob, 1.0, 0.001)) return error.ProbabilityNotOne;
}

pub const ConfigError = error{
    NegativeHorizon,
    NegativeDuration,
    NegativeWarmup,
    DurationBiggerThenHorizon,
    RepeatedUserPair,
    ProbabilityNotOne,
    EcdfPostFileError,
    EcdfOffsetFileError,
    SampleParamsFileError,
};

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

const DistTag = std.meta.Tag(NNContDist(f32));

pub const UserConf = struct {
    session_duration: DistTag,
    inter_session_time: DistTag,
    session_params_path: []const u8,
    gap_params_path: []const u8,
    ecdf_post_creation_path: []const u8,
    ecdf_offset_creation_path: []const u8,
    probability: f32,
};

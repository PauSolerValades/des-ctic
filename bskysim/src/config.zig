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

// accepts just f64 and f32 due to rng implementaiton
pub const Precision = f32;
pub const DataType = entities.Action;

const parse = @import("dist-json-parse/parse.zig");
const ParseError = parse.ParseError;
const JsonScannerError = parse.JsonScannerError;
const ReadFileError = std.Io.Dir.ReadFileAllocError;
const readKeyNumber = parse.readKeyNumber;
const readKeyBool = parse.readKeyBool;
const readKeyString = parse.readKeyString;

const Field = blk: {
    const fields = @typeInfo(SimConfig).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var vals: [fields.len]u8 = undefined;
    for (fields, 0..) |f, i| {
        names[i] = f.name;
        vals[i] = i;
    }
    break :blk @Enum(u8, .exhaustive, &names, &vals);
};

/// Input parameters of the simulation.
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
pub const SimConfig = struct {
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
    offline_startup_ratio: Precision, // which proportion of the users start on vacation
    trace_to_file: bool,
    //the config
    users: []UserConf,

    /// Opens the json file and loads the distributions in memory
    pub fn create(io: Io, gpa: Allocator, config_file: []const u8, stderr: *Io.Writer) (parse.ParseError || parse.JsonScannerError || Io.Dir.ReadFileAllocError || json.ParseError(Scanner) || error{ InvalidCharacter, WriteFailed })!SimConfig {
        const content = try Io.Dir.cwd().readFileAlloc(io, config_file, gpa, .unlimited);
        defer gpa.free(content);

        var scanner = Scanner.initCompleteInput(gpa, content);
        defer scanner.deinit();

        if (try scanner.next() != Token.object_begin) return error.UnexpectedToken;

        var config: SimConfig = undefined;
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
                .users => config.users = try parseUsers(gpa, &scanner, stderr),
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

    pub fn delete(self: *const SimConfig, gpa: Allocator) void {
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

    pub fn isValid(self: @This(), io: Io, stderr: *Io.Writer) (error{OutOfMemory} || ConfigError || error{WriteFailed})!void {
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
        self: @This(),
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
};

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

fn readDistTag(scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{WriteFailed})!DistTag {
    const tok = try scanner.next();
    if (tok != Token.string) return error.UnexpectedToken;
    return std.meta.stringToEnum(DistTag, tok.string) orelse {
        try stderr.print("users: unknown distribution tag '{s}'\n", .{tok.string});
        return error.UnknownDistribution;
    };
}

fn parseUsers(gpa: Allocator, scanner: *Scanner, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })![]UserConf {
    if (try scanner.next() != Token.array_begin) return error.UnexpectedToken;

    var users: ArrayList(UserConf) = .empty;
    defer users.deinit(gpa);

    while (true) {
        const tok = try scanner.next();
        if (tok == Token.array_end) break;
        if (tok != Token.object_begin) return error.UnexpectedToken;

        var user: UserConf = undefined;
        var has_params: std.StaticBitSet(7) = .empty;

        while (true) {
            const key = try scanner.next();
            if (key == Token.object_end) break;
            if (key != Token.string) return error.UnexpectedToken;

            if (std.mem.eql(u8, key.string, "session_duration")) {
                user.session_duration = try readDistTag(scanner, stderr);
                has_params.set(0);
            } else if (std.mem.eql(u8, key.string, "inter_session_time")) {
                user.inter_session_time = try readDistTag(scanner, stderr);
                has_params.set(1);
            } else if (std.mem.eql(u8, key.string, "session_params_path")) {
                user.session_params_path = try readKeyString(gpa, scanner);
                has_params.set(2);
            } else if (std.mem.eql(u8, key.string, "gap_params_path")) {
                user.gap_params_path = try readKeyString(gpa, scanner);
                has_params.set(3);
            } else if (std.mem.eql(u8, key.string, "ecdf_post_creation_path")) {
                user.ecdf_post_creation_path = try readKeyString(gpa, scanner);
                has_params.set(4);
            } else if (std.mem.eql(u8, key.string, "ecdf_offset_creation_path")) {
                user.ecdf_offset_creation_path = try readKeyString(gpa, scanner);
                has_params.set(5);
            } else if (std.mem.eql(u8, key.string, "probability")) {
                user.probability = try readKeyNumber(scanner, Precision);
                has_params.set(6);
            } else {
                try stderr.print("users: unknown param '{s}'\n", .{key.string});
                return error.UnknownParameter;
            }
        }

        if (has_params.count() != 7) {
            try stderr.print("users: missing required field (need 'session_duration', 'inter_session_time', 'session_params_path', 'gap_params_path', 'ecdf_post_creation_path', 'ecdf_offset_creation_path' and 'probability')\n", .{});
            return error.MissingField;
        }
        try users.append(gpa, user);
    }

    return users.toOwnedSlice(gpa);
}

pub const SimResults = struct {
    duration: f64,
    processed_events: u64,
    generated_events: u64,
    dropped_events: u64,

    posts_at_warmup: f64,

    total_impressions: u64, // Every time a post is popped from a timeline
    total_likes: u64,
    total_reposts: u64,
    total_interactions: u64, // Sum of likes, replies, reposts, quotes
    total_ignored: u64, // Events where action was .nothing

    avg_impressions_per_user: f64,
    engagement_rate: f64, // interactions / impressions
    avg_active_backlog: f64, // unread posts in active timelines at horizon
    avg_backlog: f64, // unread posts total (active + background) at horizon
    variance_backlog: f64,
    ci_backlog: f64,

    total_sessions: u64, // number of sessions for all the users
    total_boredom_ends: u64, // sessions terminated by empty timeline
    avg_session_length: f64, // mean length of sessionsa
    avg_post_per_session: f64, // mean posts per sessions
    timeline_drain_ratio: f64,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("\n+---------------------------------+\n");
        try writer.print("| SOCIAL NETWORK SIMULATION STATS |\n", .{});
        try writer.writeAll("+---------------------------------+\n");
        try writer.print("{s: <28}: {d:.4}\n", .{ "Simulation Duration (T)", self.duration });
        try writer.print("{s: <28}: {d}\n", .{ "Total Events Processed", self.processed_events });
        try writer.print("{s: <28}: {d}\n", .{ "Total Events Generated", self.generated_events });
        try writer.print("{s: <28}: {d}\n", .{ "Total Events Dropped", self.dropped_events });
        try writer.writeAll("------ Warmup -----\n");
        try writer.print("{s: <28}: {d}\n", .{ "% of posts created", self.posts_at_warmup });
        try writer.writeAll("------- Global Post Metrics -------\n");
        try writer.print("{s: <28}: {d}\n", .{ "Total Likes", self.total_likes });
        try writer.print("{s: <28}: {d}\n", .{ "Total Reposts", self.total_reposts });
        try writer.print("{s: <28}: {d}\n", .{ "Total Impressions", self.total_impressions });
        try writer.print("{s: <28}: {d}\n", .{ "Total Interactions", self.total_interactions });
        try writer.print("{s: <28}: {d}\n", .{ "Total Ignored", self.total_ignored });
        try writer.writeAll("------------- Averages ------------\n");
        try writer.print("{s: <28}: {d:.4}\n", .{ "Avg Impressions / User", self.avg_impressions_per_user });
        try writer.print("{s: <28}: {d:.2}%\n", .{ "Global Engagement Rate", self.engagement_rate * 100.0 });
        try writer.print("{s: <28}: {d:.2}\n", .{ "Avg Active Backlog / User", self.avg_active_backlog });
        try writer.print("{s: <28}: {d:.2}\n", .{ "Avg Total Backlog / User", self.avg_backlog });
        try writer.print("{s: <28}: {d:.2}\n", .{ "Var Unread Backlog", self.variance_backlog });
        try writer.print("{s: <28}: {d:.2}\n", .{ "CI Unread Backlog", self.ci_backlog });
        try writer.writeAll("------------- Sessions ------------\n");
        try writer.print("{s: <28}: {d}\n", .{ "Total Sessions (all users)", self.total_sessions });
        try writer.print("{s: <28}: {d}\n", .{ "Boredom-Ended Sessions", self.total_boredom_ends });
        try writer.print("{s: <28}: {d:.4}\n", .{ "Avg session length", self.avg_session_length });
        try writer.print("{s: <28}: {d:.4}\n", .{ "Avg posts / User ", self.avg_post_per_session });
        try writer.print("{s: <28}: {d:.2}\n", .{ "Timeline Drain Ratio", self.timeline_drain_ratio });
        try writer.writeAll("+---------------------------------+\n");
    }
};

pub const Stats = struct {
    mean: f64,
    variance: f64,
    ci: f64,

    pub fn calculateFromData(data: []f64) Stats {
        var sum: f64 = 0.0;
        for (data) |v| sum += v;
        const mean = sum / @as(f64, @floatFromInt(data.len));

        var sum_sq_diff: f64 = 0.0;
        for (data) |v| {
            const diff = v - mean;
            sum_sq_diff += diff * diff;
        }

        const variance = sum_sq_diff / @as(f64, @floatFromInt(data.len - 1));
        const std_dev = std.math.sqrt(variance);

        const margin_error = 1.96 * (std_dev / std.math.sqrt(@as(f64, @floatFromInt(data.len))));

        return Stats{ .mean = mean, .variance = variance, .ci = margin_error };
    }
};

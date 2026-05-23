const std = @import("std");

const Random = std.Random;
const ArrayList = std.ArrayList;
const Io = std.Io;

const stats = @import("distributions");
const assert = std.debug.assert;

const main = @import("main.zig");
const entities = @import("entities.zig");

const ContDist = stats.ContinuousDistribution;
const DiscDist = stats.DiscreteDistribution;
const Uniform = stats.Uniform;

const is_v1 = std.mem.eql(u8, "v1", @import("build").build);

// accepts just f64 and f32 due to rng implementaiton
pub const Precision = f32;

pub const SimConfig = struct {
    seed: ?u64,
    // time marks
    horizon: f64,                           // max duration of the simulation
    duration: f64,                          // Duration of the simulation
    warmup_time: f64,                       // time when warmup ends
    // user related actions
    user_policy: DiscDist(Precision, entities.Action),      // probability of available actions of the user
    user_inter_action: ContDist(Precision),                 // time between a user two actions
    // to init posts
    warmup_post_inter_creation: ContDist(f64),           // time of the post created in the simulation 
    post_inter_creation: ContDist(f64),
    // delays on posts transmissions
    propagation_delay: ContDist(f64),           // time between an action over a post and showing up followers timeline
    interaction_delay: ContDist(f64),           // time between 
    // session configuration                                        
    offline_startup_ratio: Precision,             // which proportion of the users start on vacation
    session_duration: ContDist(f64),           // duration of the current session
    user_inter_session: ContDist(f64),         // duration of time between sessions

    creation_delay: ContDist(f64),
    
    // misc config
    trace_to_file: bool,                        // true is trace is written to a file. False not

    pub fn isValid(self: @This()) bool {
        assert(self.horizon > 0);
        assert(self.duration > 0);
        assert(self.warmup_time > 0);
        assert(self.warmup_time + self.duration <= self.horizon);

        // check that the Distribution picked to generate the posts is not able to 
        // generate a post later than warmup_time
        return true;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("\n");
        try writer.writeAll("+--------------------------+\n");
        try writer.print("| SIMULATION CONFIGURATION |\n", .{});
        try writer.writeAll("+--------------------------+\n");
       
        try writer.writeAll("--- Warm up ---\n");
        try writer.print("{s: <24}:  {f}\n", .{ "Time between post creation", self.warmup_post_inter_creation});
        
        try writer.writeAll("--- User Actions Config ---\n");
        try writer.print("{s: <24}:  {f}\n", .{ "User policy", self.user_policy});
        try writer.print("{s: <24}:  {f}\n", .{ "Time between actions", self.user_inter_action});
        try writer.print("{s: <24}:  {f}\n", .{ "Time between post creation", self.post_inter_creation});
       
        
        try writer.writeAll("--- Post Propagation Delays ---\n");
        try writer.print("{s: <24}:  {f}\n", .{ "Propagation delay", self.propagation_delay});
        try writer.print("{s: <24}:  {f}\n", .{ "Interaction delay", self.interaction_delay});
        try writer.print("{s: <24}:  {f}\n", .{ "Creation delay", self.creation_delay});
        
        try writer.writeAll("--- User Sessions (Vacations) ---\n");
        try writer.print("{s: <24}:  {d}\n", .{ "% starting offline", self.offline_startup_ratio});
        try writer.print("{s: <24}:  {f}\n", .{ "Online Duration", self.session_duration});
        try writer.print("{s: <24}:  {f}\n", .{ "Time between Vacations", self.user_inter_session});
        try writer.writeAll("---------------------------------\n");
        try writer.print("{s: <24}:  {d: <23.2}\n", .{ "Warm-up (Time)", self.warmup_time});
        try writer.print("{s: <24}:  {d: <23.2}\n", .{ "Duration", self.duration });
        try writer.print("{s: <24}:  {d: <23.2}\n", .{ "Horizon (Time)", self.horizon });
    }
};


pub const SimResults = struct {
    duration: f64,
    processed_events: u64,
    generated_events: u64,
    dropped_events: u64,

    posts_at_warmup: f64,

    total_impressions: u64,      // Every time a post is popped from a timeline
    total_likes: u64,
    total_reposts: u64,
    total_interactions: u64,     // Sum of likes, replies, reposts, quotes
    total_ignored: u64,          // Events where action was .nothing

    avg_impressions_per_user: f64,
    engagement_rate: f64,        // interactions / impressions
    avg_backlog: f64,            // How many unread posts remain in heaps at horizon
    variance_backlog: f64,
    ci_backlog: f64,
    
    total_sessions: u64,         // number of sessions for all the users
    avg_session_length: f64,     // mean length of sessionsa
    avg_post_per_session: f64,  // mean posts per sessions
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
        try writer.print("{s: <28}: {d}\n", .{ "Total Events Generated", self.generated_events});
        try writer.print("{s: <28}: {d}\n", .{ "Total Events Dropped", self.dropped_events});
        try writer.writeAll("------ Warmup -----\n");
        try writer.print("{s: <28}: {d}\n", .{ "% of posts created", self.posts_at_warmup});
        try writer.writeAll("------- Global Post Metrics -------\n");
        try writer.print("{s: <28}: {d}\n", .{ "Total Likes", self.total_likes });
        try writer.print("{s: <28}: {d}\n", .{ "Total Reposts", self.total_reposts });
        try writer.print("{s: <28}: {d}\n", .{ "Total Impressions", self.total_impressions });
        try writer.print("{s: <28}: {d}\n", .{ "Total Interactions", self.total_interactions });
        try writer.print("{s: <28}: {d}\n", .{ "Total Ignored", self.total_ignored });
        try writer.writeAll("------------- Averages ------------\n");
        try writer.print("{s: <28}: {d:.4}\n", .{ "Avg Impressions / User", self.avg_impressions_per_user });
        try writer.print("{s: <28}: {d:.2}%\n", .{ "Global Engagement Rate", self.engagement_rate * 100.0 });
        try writer.print("{s: <28}: {d:.2}\n", .{ "Avg Unread Backlog / User", self.avg_backlog });
        try writer.print("{s: <28}: {d:.2}\n", .{ "Var Unread Backlog", self.variance_backlog });
        try writer.print("{s: <28}: {d:.2}\n", .{ "CI Unread Backlog", self.ci_backlog });
        try writer.writeAll("------------- Sessions ------------\n");
        try writer.print("{s: <28}: {d}\n", .{ "Total Sessions (all users)", self.total_sessions });
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

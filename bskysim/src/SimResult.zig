const std = @import("std");

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
    self: *const @This(),
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

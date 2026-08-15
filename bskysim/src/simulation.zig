const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Random = std.Random;
const Io = std.Io;
const Order = std.math.Order;

const DaryHeap = @import("ds").DaryHeap;

const dist = @import("distributions");

const config = @import("config.zig");
const entities = @import("entities.zig");
const t = @import("traces.zig");
const topo = @import("Topology.zig");
const gen = @import("events.zig");

const Topology = topo;
const SimState = @import("SimState.zig");


const ds_pkg = @import("ds");
const SMAList = ds_pkg.SegmentedMultiArrayList;
const PagedBitSet = ds_pkg.PagedBitSet;

const SimResults = config.SimResults;
const SimConfig = config.SimConfig;

const Precision = config.Precision;

const Event = entities.Event;
const Action = entities.Action;
const Session = entities.Session;
const User = entities.User;
const Post = entities.Post;
const TraceAction = t.TraceAction;
const TraceSession = t.TraceSession;
const TraceCreate = t.TraceCreate;
const TracePropagation = t.TracePropagation;
const TraceSwap = t.TraceSwap;
const TraceWriters = t.TraceWriters;
const SimError = entities.SimError;

const TimelineEvent = entities.TimelineEvent;
const compareTimelineEvent = entities.compareTimelineEvent;

const EventQueue: type = DaryHeap(Event, 8, void, entities.compareEvent);

pub const SimMetrics = struct {
    processed_events: u64 = 0,
    generated_events: u64 = 0,
    dropped_events: u64 = 0,

    posts_at_warmup: u64 = 0,
    post_count: u32 = 0,

    impressions: u64 = 0,
    reposts: u64 = 0,
    likes: u64 = 0,
    ignored: u64 = 0,

    total_sessions: u64 = 0,
    total_online_time: f64 = 0.0,
    empty_timeline_ends: u64 = 0,
    max_duration_ends: u64 = 0,
};

const Unif = dist.Uniform(Precision);

fn propagatePost(gpa: Allocator, topology: *const Topology, state: *SimState, t_clock: f64, user_id: u32, post_id: u32, parent_id: u32) SimError!void {
    const start_idx = topology.start[user_id];
    const end_idx = if (user_id + 1 < state.users.len)
        topology.start[user_id + 1]
    else
        @as(u32, @intCast(topology.csr.len));
    const count = end_idx - start_idx;
    const followers = topology.csr[start_idx .. start_idx + count];

    const tl_event = TimelineEvent{
        .time = t_clock,
        .post_id = post_id,
        .parent_id = parent_id,
    };

    for (followers) |fid| {
        // Skip if follower already interacted with this post (liked/reposted).
        // This avoids useless heap insertions for posts that would be skipped later.
        if (state.user_interact_post.isSet(fid, post_id)) continue;
        // this is the backlog, propagation is not in the active timeline
        state.timelines[fid].getBackground().push(gpa, tl_event) catch return error.OutOfMemoryTimeline;
    }
}

fn stageOne(
    gpa: Allocator,
    arena: Allocator,
    rng: Random,
    simconf: *const SimConfig,
    topology: *const Topology,
    state: *SimState,
    queue: *EventQueue,
    metrics: *SimMetrics,
    t_clock: *f64,
    traces: TraceWriters,
) SimError!void {

    // We create an event per user to kickstart the user posts.
    state.user_seen_post.ensureItemCapacity(arena, state.users.len) catch return error.OutOfMemoryPagedBitSet;
    state.user_interact_post.ensureItemCapacity(arena, state.users.len) catch return error.OutOfMemoryPagedBitSet;
    for (0..state.users.len) |uid| {
        // we create a creation event
        const create_post = gen.eventCreateWarmup(rng, simconf, @intCast(uid), metrics.generated_events);
        queue.push(gpa, create_post) catch return error.OutOfMemoryQueue;
        metrics.generated_events += 1;
    }

    while (t_clock.* <= simconf.warmup_time and queue.items.len > 0) {
        const current_event = queue.pop();
        t_clock.* = current_event.time;

        const current_uid = current_event.user_id;
        const gen_id = current_event.id;

        switch (current_event.type) {
            .create => {
                const new_post_id = metrics.post_count;

                state.posts.append(arena, .{ .id = new_post_id, .author = current_uid }) catch return error.OutOfMemorySMAList;
                state.user_seen_post.ensureItemCapacity(arena, new_post_id) catch return error.OutOfMemoryPagedBitSet;
                state.user_interact_post.ensureItemCapacity(arena, new_post_id) catch return error.OutOfMemoryPagedBitSet;
                // creator has seen and implicitly interacted with their own post
                state.user_seen_post.set(current_uid, new_post_id);
                state.user_interact_post.set(current_uid, new_post_id);

                const propagate = gen.eventPropagate(rng, simconf, t_clock.*, current_uid, new_post_id, current_uid, metrics.generated_events);
                queue.push(gpa, propagate) catch return error.OutOfMemoryQueue;
                metrics.generated_events += 1;

                const c = TraceCreate{ .time = t_clock.*, .user_id = current_uid, .post_id = metrics.post_count, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&c);
                try traces.create.writeAll(bytes);

                metrics.post_count += 1;
                metrics.posts_at_warmup += 1;

                const new_post = gen.eventCreatePost(rng, simconf, &state.users, t_clock.*, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                queue.push(gpa, new_post) catch return error.OutOfMemoryQueue;
                metrics.generated_events += 1;
            },
            .propagate => |prop| {
                // when creating, parent_id = current_uid. Not the same when Action
                try propagatePost(gpa, topology, state, t_clock.*, current_uid, prop.post_id, prop.parent_id);
                const p = TracePropagation{ .time = t_clock.*, .post_id = prop.post_id, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&p);
                try traces.propagate.writeAll(bytes);
            },
            else => unreachable,
        }
        metrics.processed_events += 1; // an event is always processed, there is no continues
    }
}

pub fn initSessions(
    gpa: Allocator,
    rng: Random,
    simconf: *const SimConfig,
    state: *SimState,
    queue: *EventQueue,
    metrics: *SimMetrics,
    t_clock: f64,
    traces: TraceWriters,
) SimError!void {
    const unif: Unif = .init(0, 1, dist.Interval.cc);

    const user_online = state.users.items(.is_online);
    const user_session_start = state.users.items(.session_start_time);

    for (0..state.users.len) |uid| {
        // this is to avoid potential problems :)
        // graph.timelines[uid].clearRetainingCapacity();

        const r = unif.sample(rng);
        if (r < simconf.offline_startup_ratio) { // user starts offline
            user_online[uid] = false;

            const event_start = gen.eventSessionStart(rng, &state.users, t_clock, @intCast(uid), 0, metrics.generated_events);
            queue.push(gpa, event_start) catch return error.OutOfMemoryQueue;
            metrics.generated_events += 1;
        } else { // users starts online
            user_online[uid] = true;
            user_session_start[uid] = t_clock;
            metrics.total_sessions += 1;

            // as user starts online, we log this into the session trace, it's both a generation and a processed event
            const s = TraceSession{ .time = t_clock, .type = .start, .user_id = @intCast(uid), .event_id = metrics.processed_events, .gen_id = metrics.generated_events, .backlog = 0 };
            const bytes = std.mem.asBytes(&s);
            try traces.session.writeAll(bytes);
            metrics.*.generated_events += 1;
            metrics.*.processed_events += 1;

            const event_end = gen.eventSessionEnd(rng, &state.users, t_clock, @intCast(uid), 0, metrics.generated_events);
            queue.push(gpa, event_end) catch return error.OutOfMemoryQueue;
            metrics.*.generated_events += 1;
        }
    }
}

pub fn simulate(
    gpa: Allocator,
    arena: Allocator,
    rng: Random,
    simconf: *const SimConfig,
    topology: *const Topology,
    state: *SimState,
    traces: TraceWriters,
) SimError!SimResults {
    var t_clock: f64 = 0.0;

    var metrics = SimMetrics{};

    var queue: EventQueue = .empty;
    queue.ensureTotalCapacity(gpa, 4 * topology.csr.len) catch return error.OutOfMemoryQueue;
    defer queue.deinit(gpa);

    // Pgraphost generation on init
    try stageOne(gpa, arena, rng, simconf, topology, state, &queue, &metrics, &t_clock, traces);
    // queue.clearRetainingCapacity();

    // Warmup propagated all posts into getBackground(). Swap so they're
    // immediately visible when the real simulation starts.
    for (0..state.users.len) |uid| {
        state.timelines[uid].switchTl();
        const sw = TraceSwap{ .time = t_clock, .user_id = @intCast(uid), .reason = .simulation_start };
        const sw_bytes = std.mem.asBytes(&sw);
        try traces.swaps.writeAll(sw_bytes);
    }

    // decide which users start online or not
    try initSessions(gpa, rng, simconf, state, &queue, &metrics, t_clock, traces);

    // combine this with the initSessions, it's dumb to iterate twice xd
    // set online users first action
    for (0..state.users.len) |uid| {
        if (state.users.items(.is_online)[uid]) {
            const first_action = gen.eventAction(rng, simconf, t_clock, @intCast(uid), 0, metrics.generated_events);
            queue.push(gpa, first_action) catch return error.OutOfMemoryQueue;
            metrics.generated_events += 1;
        }
    }

    const t_end = @min(simconf.warmup_time + simconf.duration, simconf.horizon);

    const user_session = state.users.items(.session_gen);
    const user_online = state.users.items(.is_online);
    const user_session_start = state.users.items(.session_start_time);
    const user_num_posts = state.users.items(.num_posts);

    while (t_clock <= t_end and queue.items.len > 0) {
        const current_event = queue.pop();
        const current_uid: u32 = current_event.user_id;
        const gen_id = current_event.id;
        std.debug.assert(current_event.time >= t_clock);
        t_clock = current_event.time;

        // check staleness of the event.
        // NOTE: start is not affected by this, as whenever a session starts, the session_gen is augmented by one
        // it will be never triggered.
        // also, propagation must be excluded, as the user has already interacted.
        if (current_event.type != .propagate) {
            const is_event_stale: bool = current_event.session_gen != user_session[current_uid];
            const is_user_online: bool = user_online[current_uid];
            if (is_event_stale or !is_user_online) {
                metrics.dropped_events += 1;
                continue;
            }
        }
        switch (current_event.type) {
            .create => {
                const new_post_id = metrics.post_count;

                user_num_posts[current_uid] += 1;
                state.user_seen_post.ensureItemCapacity(arena, new_post_id) catch return error.OutOfMemoryPagedBitSet;
                state.user_interact_post.ensureItemCapacity(arena, new_post_id) catch return error.OutOfMemoryPagedBitSet;
                // creator has seen and implicitly interacted with their own post
                state.user_seen_post.set(current_uid, new_post_id);
                state.user_interact_post.set(current_uid, new_post_id);

                const propagate = gen.eventPropagate(rng, simconf, t_clock, current_uid, new_post_id, current_uid, metrics.generated_events);
                queue.push(gpa, propagate) catch return error.OutOfMemoryQueue;
                metrics.generated_events += 1;

                const c = TraceCreate{ .time = t_clock, .user_id = current_uid, .post_id = new_post_id, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&c);
                try traces.create.writeAll(bytes);
                metrics.post_count += 1;
                metrics.processed_events += 1;

                const new_post = gen.eventCreatePost(rng, simconf, &state.users, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                queue.push(gpa, new_post) catch return error.OutOfMemoryQueue;
                metrics.generated_events += 1;
            },

            .session => |ssn| {
                const user_timeline = state.timelines[current_uid].getActive();
                const background_timeline = state.timelines[current_uid].getBackground();
                // a .end_boredom check not needed as backlog is zero for sure
                const backlog: u32 = if (ssn == .end) @intCast(background_timeline.items.len) else 0;
                const s = TraceSession{ .time = t_clock, .type = ssn, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id, .backlog = backlog };
                const bytes = std.mem.asBytes(&s);
                try traces.session.writeAll(bytes);

                switch (ssn) {
                    .start => {
                        user_online[current_uid] = true;
                        user_session[current_uid] += 1;

                        user_session_start[current_uid] = t_clock; // Record start time
                        metrics.total_sessions += 1;

                        // swap to bring backlog (posts accumulated during offline + previous session) to the front
                        state.timelines[current_uid].switchTl();

                        const sw = TraceSwap{ .time = t_clock, .user_id = current_uid, .reason = .session_start };
                        const sw_bytes = std.mem.asBytes(&sw);
                        try traces.swaps.writeAll(sw_bytes);

                        const first_action = gen.eventAction(rng, simconf, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                        queue.push(gpa, first_action) catch return error.OutOfMemoryQueue;
                        metrics.generated_events += 1;

                        const new_post = gen.eventCreatePost(rng, simconf, &state.users, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                        queue.push(gpa, new_post) catch return error.OutOfMemoryQueue;
                        metrics.generated_events += 1;

                        const end_session = gen.eventSessionEnd(rng, &state.users, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                        queue.push(gpa, end_session) catch return error.OutOfMemoryQueue;
                        metrics.generated_events += 1;
                    },
                    .end, .end_boredom => {
                        // schedule users wake up time
                        user_online[current_uid] = false;
                        // metrics
                        metrics.total_online_time += (t_clock - user_session_start[current_uid]);
                        metrics.max_duration_ends += 1;

                        const start_session = gen.eventSessionStart(rng, &state.users, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                        queue.push(gpa, start_session) catch return error.OutOfMemoryQueue;
                        metrics.generated_events += 1;

                        // clear the active timeline (posts the user finished consuming).
                        // the background timeline is preserved — it holds posts that arrived
                        // during the session but weren't swapped in yet.
                        user_timeline.clearRetainingCapacity();
                    },
                }
                metrics.processed_events += 1; // both .end and .start do not skip the loop, so its okay to put it here:
            },

            .action => |act| {
                const user_timeline = state.timelines[current_uid].getActive();

                if (user_timeline.items.len != 0) {
                    // Drain already-interacted posts inline to avoid bouncing
                    // through the global event queue for each skipped post.
                    var post: ?TimelineEvent = null;
                    while (user_timeline.items.len > 0) {
                        // this is not null due to the len being > 0
                        post = user_timeline.pop();
                        if (!state.user_interact_post.isSet(current_uid, post.?.post_id)) {
                            break;
                        }
                    }

                    if (post) |p| {
                        const a = TraceAction{ .time = t_clock, .type = act, .user_id = current_uid, .post_id = p.post_id, .parent_id = p.parent_id, .event_id = metrics.processed_events, .gen_id = gen_id };
                        const bytes = std.mem.asBytes(&a);
                        try traces.action.writeAll(bytes);

                        // Always mark as seen (diagnostic: counts every exposure)
                        state.user_seen_post.set(current_uid, p.post_id);
                        metrics.impressions += 1;

                        switch (act) {
                            .repost => {
                                // desensitized: user propagated, can't interact with this post again
                                state.user_interact_post.set(current_uid, p.post_id);

                                const propagate = gen.eventPropagate(rng, simconf, t_clock, current_uid, p.post_id, current_uid, metrics.generated_events);
                                queue.push(gpa, propagate) catch return error.OutOfMemoryQueue;
                                metrics.generated_events += 1;
                                metrics.reposts += 1;
                            },
                            .like => {
                                // desensitized: user consumed and acknowledged (platform prevents double-liking)
                                state.user_interact_post.set(current_uid, p.post_id);
                                metrics.likes += 1;
                            },
                            .ignore => {
                                // NOT desensitized: user can be re-exposed to this post via another propagation
                                // (aligned with Independent Cascade model: exposure ≠ adoption)
                                metrics.ignored += 1;
                            },
                        }
                        metrics.processed_events += 1;
                    }

                    const event = gen.eventAction(rng, simconf, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                    queue.push(gpa, event) catch return error.OutOfMemoryQueue;
                    metrics.generated_events += 1;
                } else {
                    const background_timeline = state.timelines[current_uid].getBackground();

                    if (background_timeline.items.len == 0) {
                        // Boredom mechanic
                        user_online[current_uid] = false;

                        metrics.total_online_time += (t_clock - user_session_start[current_uid]);
                        metrics.empty_timeline_ends += 1;
                        user_session[current_uid] += 1;

                        const s = TraceSession{ .time = t_clock, .type = .end_boredom, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id, .backlog = 0 };
                        const bytes = std.mem.asBytes(&s);
                        try traces.session.writeAll(bytes);

                        const bored_start = gen.eventSessionStart(rng, &state.users, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                        queue.push(gpa, bored_start) catch return error.OutOfMemoryQueue;
                        metrics.generated_events += 1;
                        metrics.processed_events += 1;
                    } else {
                        // switch the timelines add a new event action which will be from the other timeline
                        state.timelines[current_uid].switchTl();

                        const sw = TraceSwap{ .time = t_clock, .user_id = current_uid, .reason = .refresh };
                        const sw_bytes = std.mem.asBytes(&sw);
                        try traces.swaps.writeAll(sw_bytes);

                        const action = gen.eventAction(rng, simconf, t_clock, current_uid, user_session[current_uid], metrics.generated_events);
                        queue.push(gpa, action) catch return error.OutOfMemoryQueue;
                        metrics.generated_events += 1;
                    }
                }
            },

            .propagate => |post| {
                try propagatePost(gpa, topology, state, t_clock, current_uid, post.post_id, post.parent_id);
                const p = TracePropagation{ .time = t_clock, .post_id = post.post_id, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&p);
                try traces.propagate.writeAll(bytes);
                metrics.processed_events += 1;
            },
        }
    }

    try traces.action.flush();
    try traces.session.flush();
    try traces.create.flush();
    try traces.propagate.flush();
    try traces.swaps.flush();

    var total_active_backlog: usize = 0;
    var total_backlog: usize = 0;
    for (state.timelines) |*timeline| {
        total_active_backlog += timeline.getActive().items.len;
        total_backlog += timeline.getActive().items.len + timeline.getBackground().items.len;
    }

    const mean_active: f64 = @as(f64, @floatFromInt(total_active_backlog)) / @as(f64, @floatFromInt(state.users.len));
    const mean_total: f64 = @as(f64, @floatFromInt(total_backlog)) / @as(f64, @floatFromInt(state.users.len));

    var sum_sq_diff: f64 = 0.0;
    for (state.timelines) |*timeline| {
        const v: f64 = @floatFromInt(timeline.getActive().items.len + timeline.getBackground().items.len);
        const diff = v - mean_total;
        sum_sq_diff += diff * diff;
    }

    const backlog_variance = sum_sq_diff / @as(f64, @floatFromInt(state.users.len - 1));
    const std_dev = std.math.sqrt(backlog_variance);

    const margin_error = 1.96 * (std_dev / std.math.sqrt(@as(f64, @floatFromInt(state.users.len))));
    const interactions = metrics.likes + metrics.reposts;

    const result = SimResults{
        .processed_events = metrics.processed_events,
        .generated_events = metrics.generated_events,
        .dropped_events = metrics.dropped_events,
        .duration = t_clock,
        .total_likes = metrics.likes,
        .total_reposts = metrics.reposts,
        .total_interactions = interactions,
        .total_ignored = metrics.ignored,
        .total_impressions = metrics.impressions,
        .avg_impressions_per_user = @as(f64, @floatFromInt(metrics.impressions)) / @as(f64, @floatFromInt(state.users.len)),
        .engagement_rate = @as(f64, @floatFromInt(interactions)) / @as(f64, @floatFromInt(metrics.impressions)),
        .avg_backlog = mean_total,
        .avg_active_backlog = mean_active,
        .total_boredom_ends = metrics.empty_timeline_ends,
        .variance_backlog = backlog_variance,
        .ci_backlog = margin_error,
        .total_sessions = metrics.total_sessions,
        .avg_session_length = metrics.total_online_time / @as(f64, @floatFromInt(metrics.total_sessions)),
        .avg_post_per_session = @as(f64, @floatFromInt(metrics.impressions)) / @as(f64, @floatFromInt(metrics.total_sessions)),
        .timeline_drain_ratio = @as(f64, @floatFromInt(metrics.empty_timeline_ends)) / @as(f64, @floatFromInt(metrics.total_sessions)),
        .posts_at_warmup = @as(f64, @floatFromInt(metrics.posts_at_warmup)) / @as(f64, @floatFromInt(metrics.post_count)),
    };

    return result;
}

fn writeToTrace(comptime T: type, writer: *Io.Writer, event: T) !void {
    switch (T) {
        TraceAction, TraceSession, TraceCreate, TracePropagation => {},
        else => @compileError("Unsupported trace type passed"),
    }

    try std.json.Stringify.value(event, .{}, writer);
    try writer.writeAll("\n");
}

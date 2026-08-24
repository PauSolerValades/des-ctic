const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Random = std.Random;
const Io = std.Io;
const Order = std.math.Order;
const assert = std.debug.assert;

const DaryHeap = @import("ds").DaryHeap;

const dist = @import("distributions");

const GlobalParams = @import("GlobalParams.zig");
const SimResults = @import("SimResult.zig");
const entities = @import("entities.zig");
const t = @import("traces.zig");
const Topology = @import("Topology.zig");
const users = @import("users.zig");
const gen = @import("events.zig");

const SimState = @import("SimState.zig");

const ds_pkg = @import("ds");
const SMAList = ds_pkg.SegmentedMultiArrayList;
const PagedBitSet = ds_pkg.PagedBitSet;

const Event = entities.Event;
const Action = entities.Action;
const Propagate = entities.Propagate;
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

const timeline = @import("timeline.zig");
const TimelineEvent = timeline.TimelineEvent;
const compareTimelineEvent = timeline.compareTimelineEvent;

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

pub const SimParams = struct {
    global: GlobalParams,
    users: std.MultiArrayList(users.UserParams),
};

const Unif = dist.Uniform(f32);

fn propagatePost(gpa: Allocator, topology: *const Topology, state: *SimState, t_clock: f64, user_id: u32, post_id: u32, parent_id: u32) SimError!void {
    assert(user_id < topology.nodes);
    assert(user_id >= 0);
    const start_idx = topology.start[user_id];
    const end_idx = if (user_id + 1 < state.users.len)
        topology.start[user_id + 1]
    else
        @as(u32, @intCast(topology.csr.len));
    const count = end_idx - start_idx;
    assert(start_idx + count <= topology.csr.len);
    const followers = topology.csr[start_idx .. start_idx + count];

    const tl_event = TimelineEvent{
        .time = t_clock,
        .post_id = post_id,
        .parent_id = parent_id,
    };

    for (followers) |fid| {
        state.users.items(.timeline)[fid].getBackground().push(gpa, tl_event) catch {
            reportTimelineOom(fid, state.users.items(.timeline)[fid].getBackground().elements.items.len);
            return error.OutOfMemoryTimeline;
        };
    }
}

/// Diagnose a timeline allocation failure: print the failing follower and the
/// timeline's current size, so the failure point is identifiable. (The VMA/RSS
/// limits were confirmed externally via /proc/self/maps — see the run notes.)
fn reportTimelineOom(fid: u32, events: usize) void {
    std.debug.print("TIMELINE-OOM fid={d} events={d} bytes={d}\n", .{ fid, events, events * @sizeOf(TimelineEvent) });
}

const SimInfo = struct {
    topology: *const Topology,
    params: *const SimParams,
    state: *SimState,
    metrics: *SimMetrics,
    traces: TraceWriters,
    now: f64,
};

const UserInfo = struct {
    session_gen: []u32,
    online: []bool,
    session_start: []f64,
    num_posts: []u32,
};

fn handleCreate(gpa: Allocator, rng: Random, queue: *EventQueue, sim: *const SimInfo, user: *const UserInfo, uid: u32, gen_id: u64) SimError!void {
    const new_post_id = sim.metrics.post_count;

    user.num_posts[uid] += 1;

    // creator has seen and implicitly interacted with their own post
    _ = sim.state.users.items(.liked_posts)[uid].add(gpa, new_post_id) catch return error.OutOfMemoryUserMap;
    _ = sim.state.users.items(.reposted_posts)[uid].add(gpa, new_post_id) catch return error.OutOfMemoryUserMap;

    const propagate = gen.eventPropagate(rng, sim.params, sim.now, uid, new_post_id, uid, sim.metrics.generated_events);
    queue.push(gpa, propagate) catch return error.OutOfMemoryQueue;
    sim.metrics.generated_events += 1;

    const c = TraceCreate{ .time = sim.now, .user_id = uid, .post_id = new_post_id, .event_id = sim.metrics.processed_events, .gen_id = gen_id };
    const bytes = std.mem.asBytes(&c);
    try sim.traces.create.writeAll(bytes);
    sim.metrics.post_count += 1;
    sim.metrics.processed_events += 1;

    const new_post = gen.eventCreatePost(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
    queue.push(gpa, new_post) catch return error.OutOfMemoryQueue;
    sim.metrics.generated_events += 1;
}

fn sessionStart(gpa: Allocator, rng: Random, queue: *EventQueue, sim: *const SimInfo, user: *const UserInfo, uid: u32) SimError!void {
    user.online[uid] = true;
    user.session_gen[uid] += 1;

    user.session_start[uid] = sim.now; // Record start time
    sim.metrics.total_sessions += 1;

    // swap to bring backlog (posts accumulated during offline + previous session) to the front
    sim.state.users.items(.timeline)[uid].switchTl();

    const sw = TraceSwap{ .time = sim.now, .user_id = uid, .reason = .session_start };
    const sw_bytes = std.mem.asBytes(&sw);
    try sim.traces.swaps.writeAll(sw_bytes);

    const first_action = gen.eventAction(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
    queue.push(gpa, first_action) catch return error.OutOfMemoryQueue;
    sim.metrics.generated_events += 1;

    const new_post = gen.eventCreateFirstPost(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
    queue.push(gpa, new_post) catch return error.OutOfMemoryQueue;
    sim.metrics.generated_events += 1;

    const end_session = gen.eventSessionEnd(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
    queue.push(gpa, end_session) catch return error.OutOfMemoryQueue;
    sim.metrics.generated_events += 1;
}

fn sessionEnd(gpa: Allocator, rng: Random, queue: *EventQueue, sim: *const SimInfo, user: *const UserInfo, uid: u32) SimError!void {
    // schedule users wake up time
    user.online[uid] = false;
    // metrics
    sim.metrics.total_online_time += (sim.now - user.session_start[uid]);
    sim.metrics.max_duration_ends += 1;

    const start_session = gen.eventSessionStart(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
    queue.push(gpa, start_session) catch return error.OutOfMemoryQueue;
    sim.metrics.generated_events += 1;

    // clear the active timeline (posts the user finished consuming).
    // the background timeline is preserved — it holds posts that arrived
    // during the session but weren't swapped in yet.
    sim.state.users.items(.timeline)[uid].getActive().elements.clearRetainingCapacity();
}

fn handleSession(gpa: Allocator, rng: Random, queue: *EventQueue, sim: *const SimInfo, user: *const UserInfo, uid: u32, gen_id: u64, ssn: Session) SimError!void {
    const background_timeline = sim.state.users.items(.timeline)[uid].getBackground();
    // backlog: on .start this is the accumulated posts the user is about to
    // consume (the "healthy timeline" the warmup must provide); on .end it is
    // the leftover unread; on .end_boredom it is zero by definition.
    const backlog: u32 = if (ssn == .end or ssn == .start) @intCast(background_timeline.elements.items.len) else 0;
    const s = TraceSession{ .time = sim.now, .type = ssn, .user_id = uid, .event_id = sim.metrics.processed_events, .gen_id = gen_id, .backlog = backlog };
    const bytes = std.mem.asBytes(&s);
    try sim.traces.session.writeAll(bytes);

    switch (ssn) {
        .start => try sessionStart(gpa, rng, queue, sim, user, uid),
        .end, .end_boredom => try sessionEnd(gpa, rng, queue, sim, user, uid),
    }
    sim.metrics.processed_events += 1; // both .end and .start do not skip the loop, so its okay to put it here:
}

fn handleAction(gpa: Allocator, rng: Random, queue: *EventQueue, sim: *const SimInfo, user: *const UserInfo, uid: u32, gen_id: u64, act: Action) SimError!void {
    const user_timeline = sim.state.users.items(.timeline)[uid].getActive();

    if (user_timeline.elements.items.len != 0) {
        // Drain already-interacted posts inline to avoid bouncing
        // through the global event queue for each skipped post.
        var post: ?TimelineEvent = null;
        while (user_timeline.elements.items.len > 0) {
            const candidate = user_timeline.pop() orelse break;
            if (!sim.state.users.items(.reposted_posts)[uid].contains(candidate.post_id)) {
                post = candidate;
                break;
            }
        }

        if (post) |p| {
            assert(sim.state.users.items(.reposted_posts)[uid].contains(p.post_id) == false);

            const a = TraceAction{ .time = sim.now, .type = act, .user_id = uid, .post_id = p.post_id, .parent_id = p.parent_id, .event_id = sim.metrics.processed_events, .gen_id = gen_id };
            const bytes = std.mem.asBytes(&a);
            try sim.traces.action.writeAll(bytes);

            sim.metrics.impressions += 1;

            switch (act) {
                .repost => {
                    // desensitized: user propagated, can't interact with this post again
                    _ = sim.state.users.items(.reposted_posts)[uid].add(gpa, p.post_id) catch return error.OutOfMemoryUserMap;

                    const propagate = gen.eventPropagate(rng, sim.params, sim.now, uid, p.post_id, uid, sim.metrics.generated_events);
                    queue.push(gpa, propagate) catch return error.OutOfMemoryQueue;
                    sim.metrics.generated_events += 1;
                    sim.metrics.reposts += 1;
                },
                .like => {
                    // desensitized: user cannot like a post twice
                    if (!sim.state.users.items(.liked_posts)[uid].contains(p.post_id)) {
                        _ = sim.state.users.items(.liked_posts)[uid].add(gpa, p.post_id) catch return error.OutOfMemoryUserMap;
                        sim.metrics.likes += 1;
                    }
                },
                .ignore => {
                    // NOT desensitized: user can be re-exposed to this post via another propagation
                    // (aligned with Independent Cascade model: exposure ≠ adoption)
                    sim.metrics.ignored += 1;
                },
            }
            sim.metrics.processed_events += 1;
        }

        const event = gen.eventAction(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
        queue.push(gpa, event) catch return error.OutOfMemoryQueue;
        sim.metrics.generated_events += 1;
    } else {
        try handleActionIdle(gpa, rng, queue, sim, user, uid, gen_id);
    }
}

fn handleActionIdle(gpa: Allocator, rng: Random, queue: *EventQueue, sim: *const SimInfo, user: *const UserInfo, uid: u32, gen_id: u64) SimError!void {
    const background_timeline = sim.state.users.items(.timeline)[uid].getBackground();

    if (background_timeline.elements.items.len == 0) {
        // Boredom mechanic
        user.online[uid] = false;

        sim.metrics.total_online_time += (sim.now - user.session_start[uid]);
        sim.metrics.empty_timeline_ends += 1;
        user.session_gen[uid] += 1;

        const s = TraceSession{ .time = sim.now, .type = .end_boredom, .user_id = uid, .event_id = sim.metrics.processed_events, .gen_id = gen_id, .backlog = 0 };
        const bytes = std.mem.asBytes(&s);
        try sim.traces.session.writeAll(bytes);

        const bored_start = gen.eventSessionStart(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
        queue.push(gpa, bored_start) catch return error.OutOfMemoryQueue;
        sim.metrics.generated_events += 1;
        sim.metrics.processed_events += 1;
    } else {
        // switch the timelines add a new event action which will be from the other timeline
        sim.state.users.items(.timeline)[uid].switchTl();

        const sw = TraceSwap{ .time = sim.now, .user_id = uid, .reason = .refresh };
        const sw_bytes = std.mem.asBytes(&sw);
        try sim.traces.swaps.writeAll(sw_bytes);

        const action = gen.eventAction(rng, sim.params, sim.now, uid, user.session_gen[uid], sim.metrics.generated_events);
        queue.push(gpa, action) catch return error.OutOfMemoryQueue;
        sim.metrics.generated_events += 1;
    }
}

fn handlePropagate(gpa: Allocator, sim: *const SimInfo, uid: u32, gen_id: u64, post: Propagate) SimError!void {
    try propagatePost(gpa, sim.topology, sim.state, sim.now, uid, post.post_id, post.parent_id);
    const p = TracePropagation{ .time = sim.now, .post_id = post.post_id, .user_id = uid, .event_id = sim.metrics.processed_events, .gen_id = gen_id };
    const bytes = std.mem.asBytes(&p);
    try sim.traces.propagate.writeAll(bytes);
    sim.metrics.processed_events += 1;
}

fn stageOne(
    gpa: Allocator,
    rng: Random,
    topology: *const Topology,
    params: *const SimParams,
    state: *SimState,
    queue: *EventQueue,
    metrics: *SimMetrics,
    t_clock: *f64,
    traces: TraceWriters,
) SimError!void {
    // We create an event per user to kickstart the user posts.
    for (0..state.users.len) |uid| {
        // we create a creation event
        const create_post = gen.eventCreateFirstPost(rng, params, t_clock.*, @intCast(uid), 0, metrics.generated_events);
        queue.push(gpa, create_post) catch return error.OutOfMemoryQueue;
        metrics.generated_events += 1;
    }

    // first-post events above must always be queued or no posts ever exist.
    while (params.global.warmup_time != 0 and t_clock.* <= params.global.warmup_time and queue.items.len > 0) {
        const current_event = queue.pop();
        t_clock.* = current_event.time;

        const current_uid = current_event.user_id;
        const gen_id = current_event.id;

        switch (current_event.type) {
            .create => {
                const new_post_id = metrics.post_count;

                // if someday we can add the contents of the post, this line here would have to come back
                // state.posts.append(arena, .{ .id = new_post_id, .author = current_uid }) catch return error.OutOfMemorySMAList;

                // creator has seen and implicitly interacted with their own post
                _ = state.users.items(.liked_posts)[current_uid].add(gpa, new_post_id) catch return error.OutOfMemoryUserMap;
                _ = state.users.items(.reposted_posts)[current_uid].add(gpa, new_post_id) catch return error.OutOfMemoryUserMap;

                const propagate = gen.eventPropagate(rng, params, t_clock.*, current_uid, new_post_id, current_uid, metrics.generated_events);
                queue.push(gpa, propagate) catch return error.OutOfMemoryQueue;
                metrics.generated_events += 1;

                const c = TraceCreate{ .time = t_clock.*, .user_id = current_uid, .post_id = metrics.post_count, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&c);
                try traces.create.writeAll(bytes);

                metrics.post_count += 1;
                metrics.posts_at_warmup += 1;

                const new_post = gen.eventCreatePost(rng, params, t_clock.*, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
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
    params: *const SimParams,
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
        const r = unif.sample(rng);
        if (r < params.global.offline_startup_ratio) { // user starts offline
            user_online[uid] = false;

            const event_start = gen.eventSessionStart(rng, params, t_clock, @intCast(uid), 0, metrics.generated_events);
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

            const event_end = gen.eventSessionEnd(rng, params, t_clock, @intCast(uid), 0, metrics.generated_events);
            queue.push(gpa, event_end) catch return error.OutOfMemoryQueue;
            metrics.*.generated_events += 1;
        }
    }
}

pub fn simulate(
    gpa: Allocator,
    rng: Random,
    topology: *const Topology,
    simctx: *const SimParams,
    state: *SimState,
    traces: TraceWriters,
) SimError!SimResults {
    var t_clock: f64 = 0.0;

    var metrics = SimMetrics{};

    var queue: EventQueue = .empty;
    queue.ensureTotalCapacity(gpa, 4 * topology.csr.len) catch return error.OutOfMemoryQueue;
    defer queue.deinit(gpa);

    // generation on init
    if (simctx.global.warmup_time != 0) {
        try stageOne(gpa, rng, topology, simctx, state, &queue, &metrics, &t_clock, traces);
    }

    // Warmup propagated all posts into getBackground(). Swap so they're
    // immediately visible when the real simulation starts.
    for (0..state.users.len) |uid| {
        state.users.items(.timeline)[uid].switchTl();
        const sw = TraceSwap{ .time = t_clock, .user_id = @intCast(uid), .reason = .simulation_start };
        const sw_bytes = std.mem.asBytes(&sw);
        try traces.swaps.writeAll(sw_bytes);
    }

    // decide which users start online or not
    try initSessions(gpa, rng, simctx, state, &queue, &metrics, t_clock, traces);

    // combine this with the initSessions, it's dumb to iterate twice xd
    // set online users first action
    for (0..state.users.len) |uid| {
        if (state.users.items(.is_online)[uid]) {
            const first_action = gen.eventAction(rng, simctx, t_clock, @intCast(uid), 0, metrics.generated_events);
            queue.push(gpa, first_action) catch return error.OutOfMemoryQueue;
            metrics.generated_events += 1;
        }
    }

    const t_end = @min(simctx.global.warmup_time + simctx.global.duration, simctx.global.horizon);

    const user_session = state.users.items(.session_gen);
    const user_online = state.users.items(.is_online);
    const user_session_start = state.users.items(.session_start_time);
    const user_num_posts = state.users.items(.num_posts);

    var sim = SimInfo{
        .topology = topology,
        .params = simctx,
        .state = state,
        .metrics = &metrics,
        .traces = traces,
        .now = 0.0,
    };
    const user = UserInfo{
        .session_gen = user_session,
        .online = user_online,
        .session_start = user_session_start,
        .num_posts = user_num_posts,
    };

    while (t_clock <= t_end and queue.items.len > 0) {
        const current_event = queue.pop();
        const current_uid: u32 = current_event.user_id;
        const gen_id = current_event.id;
        std.debug.assert(current_event.time >= t_clock);
        t_clock = current_event.time;
        sim.now = t_clock;

        // check staleness of the event.
        // NOTE: start is not affected by this, as whenever a session starts, the session_gen is augmented by one it will be never triggered.
        // also, propagation must be excluded, as the user has already interacted.
        if (current_event.type != .propagate) {
            // wake-up .start events fire while the user is offline: they must bypass the online gate or no user can ever come back online.
            const is_wakeup: bool = current_event.type == .session and current_event.type.session == .start;
            const is_event_stale: bool = current_event.session_gen != user_session[current_uid];
            const is_user_online: bool = user_online[current_uid];
            if (is_event_stale or (!is_user_online and !is_wakeup)) {
                metrics.dropped_events += 1;
                continue;
            }
        }
        switch (current_event.type) {
            .create => try handleCreate(gpa, rng, &queue, &sim, &user, current_uid, gen_id),
            .session => |ssn| try handleSession(gpa, rng, &queue, &sim, &user, current_uid, gen_id, ssn),
            .action => |act| try handleAction(gpa, rng, &queue, &sim, &user, current_uid, gen_id, act),
            .propagate => |post| try handlePropagate(gpa, &sim, current_uid, gen_id, post),
        }
    }

    try traces.action.flush();
    try traces.session.flush();
    try traces.create.flush();
    try traces.propagate.flush();
    try traces.swaps.flush();

    return computeResults(state, &metrics, t_clock);
}

fn computeResults(state: *SimState, metrics: *const SimMetrics, t_clock: f64) SimResults {
    var total_active_backlog: usize = 0;
    var total_backlog: usize = 0;
    for (state.users.items(.timeline)) |*tl| {
        total_active_backlog += tl.getActive().elements.items.len;
        total_backlog += tl.getActive().elements.items.len + tl.getBackground().elements.items.len;
    }

    const mean_active: f64 = @as(f64, @floatFromInt(total_active_backlog)) / @as(f64, @floatFromInt(state.users.len));
    const mean_total: f64 = @as(f64, @floatFromInt(total_backlog)) / @as(f64, @floatFromInt(state.users.len));

    var sum_sq_diff: f64 = 0.0;
    for (state.users.items(.timeline)) |*tl| {
        const v: f64 = @floatFromInt(tl.getActive().elements.items.len + tl.getBackground().elements.items.len);
        const diff = v - mean_total;
        sum_sq_diff += diff * diff;
    }

    const backlog_variance = sum_sq_diff / @as(f64, @floatFromInt(state.users.len - 1));
    const std_dev = std.math.sqrt(backlog_variance);

    const margin_error = 1.96 * (std_dev / std.math.sqrt(@as(f64, @floatFromInt(state.users.len))));
    const interactions = metrics.likes + metrics.reposts;

    return .{
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
}

fn writeToTrace(comptime T: type, writer: *Io.Writer, event: T) !void {
    switch (T) {
        TraceAction, TraceSession, TraceCreate, TracePropagation => {},
        else => @compileError("Unsupported trace type passed"),
    }

    try std.json.Stringify.value(event, .{}, writer);
    try writer.writeAll("\n");
}

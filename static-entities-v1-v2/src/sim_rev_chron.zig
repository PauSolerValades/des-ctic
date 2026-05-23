const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Random = std.Random;
const Io = std.Io;
const Order = std.math.Order;

const Heap = @import("heap").Heap;

const dist = @import("distributions");

const config = @import("config.zig");
const entities = @import("entities.zig");
const gn = @import("graph_network.zig");

const SimResults = config.SimResults;
const SimConfig = config.SimConfig;

const Precision = config.Precision;

const Event = entities.Event;
const Action = entities.Action;
const Session = entities.Session;
const User = entities.User;
const Post = entities.Post;
const TraceAction = entities.TraceAction;
const TraceSession = entities.TraceSession;
const TraceCreate = entities.TraceCreate;
const TimelineEvent = entities.TimelineEvent;
const compareTimelineEvent = entities.compareTimelineEvent;
const Index = entities.Index;


const EventQueue: type = Heap(Event, void, entities.compareEvent);


pub const SimMetrics = struct {
    processed_events: u64 = 0,
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


fn eventAction(rng: Random, simconf: SimConfig, t_clock: f64, user_id: Index, user_session_gen: u64, generated_events: u64) Event {
   
    const action: Action = simconf.user_policy.sample(rng);
    
    const event_time = simconf.user_inter_action.sample(rng);
    const interaction_delay = simconf.interaction_delay.sample(rng);

    const event = Event{ 
        .time = t_clock + event_time + interaction_delay, 
        .type = .{ .action = action }, 
        .user_id = user_id, 
        .id = generated_events, 
        .session_gen = user_session_gen,
    };
    
    return event;
}

fn eventSessionStart(rng: Random, simconf: SimConfig, t_clock: f64, user_id: Index, session_id: u64, generated_events: u64) Event {
    // when will the user go online 
    const offline_duration = simconf.user_inter_session.sample(rng);
    const event_start = Event{ 
        .time = t_clock + offline_duration, 
        .type = .{ .session = .start }, 
        .user_id = user_id, 
        .id = generated_events, 
        .session_gen = session_id,
    }; 
    return event_start;
}

fn eventSessionEnd(rng: Random, simconf: SimConfig, t_clock: f64, user_id: Index, session_id: u64, generated_events: u64) Event {
    // when will the user go offline
    const duration = simconf.session_duration.sample(rng);
    const event_end = Event{ 
        .time = t_clock + duration, 
        .type = .{ .session = .end }, 
        .user_id = user_id, 
        .id = generated_events, 
        .session_gen = session_id, 
    }; 
    return event_end;
}

fn eventCreateWarmup(rng: Random, simconf: SimConfig, user_id: Index, post_id: Index, generated_events: u64) Event {
    const t_creation_decision = simconf.warmup_post_inter_creation.sample(rng);

    const creation_delay = simconf.creation_delay.sample(rng);
    return Event{
        .time = t_creation_decision + creation_delay,
        .type = .{ .create = post_id },
        .user_id = user_id,
        .id = generated_events,
        .session_gen = 0,
    };
}

fn eventCreatePost(rng: Random, simconf: SimConfig, t_clock: f64, user_id: Index, post_id: Index, session_id: u64, generated_events: u64) Event {
    // Schedule the next post creation for this user
    const creation_delay = simconf.creation_delay.sample(rng);
    const duration_between_creation = simconf.warmup_post_inter_creation.sample(rng);
    
    const new_post = Event{
        .time = t_clock + duration_between_creation + creation_delay,
        .type = .{ .create = post_id },
        .user_id = user_id,
        .id = generated_events,
        .session_gen = session_id,
    };
    return new_post;
}

const Unif = dist.Uniform(Precision);

fn propagatePost(
    gpa: Allocator, 
    rng: Random, 
    graph: *gn.StaticNetworkGraph, 
    simconf: SimConfig, 
    t_clock: f64, 
    user_id: Index, 
    post_id: Index
) !void {

    const follower_start = graph.users.items(.follower_start)[user_id];
    const follower_count = graph.users.items(.follower_count)[user_id];
    const total_posts = graph.users.len * simconf.max_post_per_user;
    
    for (graph.followers[follower_start..follower_start+follower_count]) |fid| {
        //check that user_ptr has not seen this post already...
        const matrix_index = fid * total_posts + post_id; 
        if (!graph.user_seen_post.isSet(matrix_index)) {
            const propagation_delay = simconf.propagation_delay.sample(rng);
            const propagated_event = TimelineEvent{
                .time = t_clock + propagation_delay, 
                .post_id = post_id,
            };

            try graph.timelines[fid].add(gpa, propagated_event);

        } // else the post was seen_posts to do not add it
    }
}


fn stageOne(
    gpa: Allocator, 
    rng: Random, 
    simconf: SimConfig, 
    graph: *gn.StaticNetworkGraph, 
    queue: *EventQueue,
    metrics: *SimMetrics,
    t_clock: *f64, 
) !void {
    
    const total_posts = graph.users.len * simconf.max_post_per_user;
    
    for (0..graph.users.len) |uid| {
        
        const matrix_index = uid * total_posts + metrics.post_count;
        graph.user_seen_post.set(matrix_index);
       
        const create_post = eventCreateWarmup(rng, simconf, @intCast(uid), metrics.post_count, metrics.generated_events);
        try queue.add(gpa, create_post); 
        metrics.generated_events += 1;
        
        graph.users.items(.num_posts)[uid] += 1;
        
        metrics.post_count += 1;
    }

    while (t_clock.* <= simconf.warmup_time and queue.items.len > 0) {
        const current_event = queue.remove();
        t_clock.* = current_event.time;

        const current_uid = current_event.user_id;
        const gen_id = current_event.id;

        switch (current_event.type) {
            .create => |pid| {
                // Read from the dynamic user slice
                const max_posts_reached: bool = if (simconf.max_post_per_user < graph.users.items(.num_posts)[current_id]);
                    simconf.max_post_per_user <= graph.users.items(.num_posts)[current_uid]
                else false;

                if (max_posts_reached) {
                    metrics.dropped_events += 1;
                    continue;
                }

                try propagatePost(gpa, rng, graph, simconf, t_clock.*, current_uid, pid);
                // metrics.post_count += 1;
                
                // Schedule the next post creation for this user
                const creation_delay = simconf.creation_delay.sample(rng);
                const duration_between_creation = simconf.warmup_post_inter_creation.sample(rng);
                const new_post = Event{
                    .time = t_clock.* + duration_between_creation + creation_delay,
                    .type = .{ .create = metrics.post_count },
                    .user_id = current_uid,
                    .id = metrics.processed_events,
                    .session_gen = graph.users.items(.session_gen)[current_uid],
                };
                
                try queue.add(gpa, new_post);
                metrics.processed_events += 1; 
            },
            else => unreachable,
        }
    }
}

pub fn initSessions(
    gpa: Allocator, 
    rng: Random, 
    simconf: SimConfig, 
    graph: *gn.StaticNetworkGraph, 
    queue: *EventQueue,
    metrics: *SimMetrics, 
    t_clock: f64,
    session_trace: *Io.Writer,
) !void {
    const unif: Unif = .init(0, 1, dist.Interval.cc);

    for (0..graph.users.len) |uid| {
        const r = unif.sample(rng); 
        if (r < simconf.offline_startup_ratio) { // user starts offline
            graph.users.items(.is_online)[uid] = false;
            
            const offline_duration = simconf.user_inter_session.sample(rng);
            // when will the user go online 
            const event_start = Event{ 
                .time = t_clock + offline_duration, 
                .type = .{ .session = .start }, 
                .user_id = @intCast(uid), 
                .id = metrics.processed_events, 
                .session_gen = 0 
            }; 

            try queue.add(gpa, event_start);
            
        } else { // users starts online
            graph.users.items(.is_online)[uid] = true;
            graph.users.items(.session_start_time)[uid] = 0.0;
            metrics.total_sessions += 1;
            
            // when will the user go offline
            const duration = simconf.session_duration.sample(rng);
            const event_end = Event{ 
                .time = t_clock + duration, 
                .type = .{ .session = .end }, 
                .user_id = @intCast(uid), 
                .id = metrics.processed_events, 
                .session_gen = 0 
            }; 
            
            try queue.add(gpa, event_end);

            if (simconf.trace_to_file) {
                const trace_event = TraceSession {
                    .time = t_clock,
                    .type = .start,
                    .event_id = metrics.processed_events,
                    .user_id = @intCast(uid),
                };
                try std.json.Stringify.value(trace_event, .{}, session_trace);
                try session_trace.writeAll("\n");
            }
        }
        metrics.processed_events += 1;
    }
}

pub fn stagedSimulation(gpa: Allocator, rng: Random, simconf: SimConfig, graph: *gn.StaticNetworkGraph, action_trace: *Io.Writer, session_trace: *Io.Writer, create_trace: *Io.Writer) !SimResults {

    var t_clock: f64 = 0.0;
    var processed_events: u64 = 0;
    
    var metrics = SimMetrics{};
    const total_posts = simconf.max_post_per_user * graph.users.len;

    var queue: EventQueue = .empty;
    defer queue.deinit(gpa);
    
    // Post generation on init 
    try stageOne(gpa, rng, simconf, graph, &queue, &metrics, &t_clock);
    
    // decide which users start online or not
    try initSessions(gpa, rng, simconf, graph, &queue, &metrics, t_clock, session_trace);

    // set online users first action
    for (0..graph.users.len) |uid| {
        if (graph.users.items(.is_online)[uid]) {
            const first_action = try CreateRandomAction(
                rng,
                simconf,
                t_clock,
                @intCast(uid), 
                0, 
                processed_events,
            );
            try queue.add(gpa, first_action);
            metrics.processed_events += 1;
        }
    }

    const t_end = @min(simconf.warmup_time + simconf.duration, simconf.horizon);
    while (t_clock <= t_end and queue.items.len > 0) : (processed_events += 1) {
        const current_event = queue.remove();
        // if the event has become stale skip it        
        if (current_event.session_gen != graph.users.items(.session_gen)[current_event.user_id]) {
            continue;
        }
        const current_uid: Index = current_event.user_id;
        std.debug.assert(current_event.time >= t_clock);
        t_clock = current_event.time;

        switch (current_event.type) {
            .create => {
               
                const max_posts_reached = graph.users.items(.num_posts)[current_uid] > simconf.max_post_per_user;

                if (max_posts_reached) continue;
                const to_propagate_pid = metrics.post_count;
                metrics.post_count += 1;
                graph.users.items(.num_posts)[current_uid] += 1;

                if (graph.users.items(.is_online)[current_uid]) {

                    graph.users.items(.num_posts)[current_uid] += 1;
                    graph.user_seen_post.set(current_uid * total_posts + to_propagate_pid);
                    
                    try propagatePost(gpa, rng, graph, simconf, t_clock, current_uid, to_propagate_pid);
                    
                    if (simconf.trace_to_file) {
                        const trace_event = TraceCreate{
                            .time = t_clock,
                            .event_id = metrics.processed_events,
                            .post_id = to_propagate_pid,
                            .user_id = current_uid,
                        };
                        
                        try std.json.Stringify.value(trace_event, .{}, create_trace);
                        try create_trace.writeAll("\n");
                    }
                }
            
                // schedule new creation
                const creation_delay = simconf.creation_delay.sample(rng);
                const duration_between_creation = simconf.warmup_post_inter_creation.sample(rng);
                const new_post = Event{
                    .time = t_clock + creation_delay + duration_between_creation,
                    .type = .{ .create = 0 }, // dummy posts for now, will get assigned on creation
                    .user_id = current_uid,
                    .id = metrics.processed_events,
                    .session_gen = graph.users.items(.session_gen)[current_uid],
                };
                
                try queue.add(gpa, new_post);
            },

            .session => |ssn| {
                // this is to avoid the intrusive heap for the overlaping session
                if (ssn == .end and !graph.users.items(.is_online)[current_uid]) continue; 
       
                if (simconf.trace_to_file) {
                     const trace_event = TraceSession {
                        .time = t_clock,
                        .type = ssn,
                        .event_id = processed_events,
                        .user_id = current_uid,
                    };

                    // this might be very slow, it could be better to use the lower json api
                    try std.json.Stringify.value(trace_event, .{}, session_trace);
                    try session_trace.writeAll("\n");
                }

                switch (ssn) {
                    .start => {
                        graph.users.items(.is_online)[current_uid] = true;
                        graph.users.items(.session_gen)[current_uid] += 1;

                        graph.users.items(.session_start_time)[current_uid] = t_clock; // Record start time
                        metrics.total_sessions += 1;

                        const max_duration = simconf.session_duration.sample(rng);
                        const e = Event{ 
                            .time = t_clock + max_duration, 
                            .type = .{ .session = .end }, 
                            .user_id = current_uid, 
                            .id = processed_events,
                            .session_gen = graph.users.items(.session_gen)[current_uid] // every event must be stamped 
                        }; 
                        try queue.add(gpa, e);

                        const first_action = try CreateRandomAction(
                            rng,
                            simconf,
                            t_clock,
                            current_uid,
                            graph.users.items(.session_gen)[current_uid], 
                            metrics.processed_events, 
                        );
                        try queue.add(gpa, first_action);
                 
                        const new_post_time = simconf.post_inter_creation.sample(rng);
                        const new_post = Event{
                            .time = t_clock + new_post_time,
                            .type = .{ .create = 0 },
                            .user_id = current_uid,
                            .id = metrics.processed_events,
                            .session_gen = graph.users.items(.session_gen)[current_uid],
                        };
                        try queue.add(gpa, new_post);
                    },
                    .end => {
                        // schedule users wake up time
                        graph.users.items(.is_online)[current_uid] = false;
                        // metrics 
                        metrics.total_online_time += (t_clock - graph.users.items(.session_start_time)[current_uid]);
                        metrics.max_duration_ends += 1;

                        const offline_duration = simconf.user_inter_session.sample(rng);
                        const e = Event{ 
                            .time = t_clock + offline_duration, 
                            .type = .{ .session = .start }, 
                            .user_id = current_uid, 
                            .id = processed_events,
                            .session_gen = graph.users.items(.session_gen)[current_uid],
                        }; 
                        try queue.add(gpa, e);

                        // post non seen when session finished will get nuked
                        graph.timelines[current_uid].clearRetainingCapacity();
                    }
                }
            },
            .action => |act| {
                // if user is not online (this should NEVER happen due to stalenes)
                if (!graph.users.items(.is_online)[current_uid]) unreachable;

                const has_post_arrived = if (graph.timelines[current_uid].peek()) |post| post.time <= t_clock else false;

                if (has_post_arrived) {
                    // now it's safe to pop it and use it
                    const current_post = graph.timelines[current_uid].remove();
                    const post_id: Index = current_post.post_id;
                    const matrix_index = current_uid * total_posts + post_id;
                    
                    // user CANNOT see previous posts. Shouldn't happen here anyway. this is a _safeguard_
                    if (graph.user_seen_post.isSet(matrix_index)) {
                        const next_action = try CreateRandomAction(
                            rng,
                            simconf,
                            t_clock,
                            current_uid, 
                            graph.users.items(.session_gen)[current_uid], 
                            metrics.processed_events, 
                        );
                        try queue.add(gpa, next_action);
                        continue; 
                    }

                    if (simconf.trace_to_file) {
                        const trace_event = TraceAction {
                            .time = t_clock,
                            .type = act,
                            .event_id = metrics.processed_events,
                            .user_id = current_uid,
                            .post_id = post_id,
                        };

                        try std.json.Stringify.value(trace_event, .{}, action_trace);
                        try action_trace.writeAll("\n");
                    } 

                    graph.user_seen_post.set(matrix_index);
                    metrics.impressions += 1;
           
                    switch (act) {
                        .repost => {
                            try propagatePost(gpa, rng, graph, simconf, t_clock, current_uid, current_post.post_id);
                            metrics.reposts += 1;
                        },
                        .like => metrics.likes += 1,
                        .ignore => metrics.ignored += 1,
                    }

                    const event = try CreateRandomAction(
                        rng,
                        simconf,
                        t_clock,
                        current_uid, 
                        graph.users.items(.session_gen)[current_uid], 
                        metrics.processed_events
                    );
                    try queue.add(gpa, event);
   
                } else {
                    graph.users.items(.is_online)[current_uid] = false;
        
                    metrics.total_online_time += (t_clock - graph.users.items(.session_start_time)[current_uid]);
                    metrics.empty_timeline_ends += 1;
                    graph.users.items(.session_gen)[current_uid] += 1;
                    
                    if (simconf.trace_to_file) {
                        const trace_event = TraceSession {
                            .time = t_clock,
                            .type = .end,
                            .event_id = metrics.processed_events,
                            .user_id = current_uid,
                        };
                        try std.json.Stringify.value(trace_event, .{}, session_trace);
                        try session_trace.writeAll("\n");
                    }

                    const offline_duration = simconf.user_inter_session.sample(rng);
                    const e = Event{ 
                        .time = t_clock + offline_duration, 
                        .type = .{ .session = .start }, 
                        .user_id = current_uid, 
                        .id = metrics.processed_events, 
                        .session_gen = graph.users.items(.session_gen)[current_uid] 
                    }; 
                    try queue.add(gpa, e);
                    // no need to nuke the timeline, it's already empty
                }
            }
        }
    } 
   
    try action_trace.flush();
    try session_trace.flush();
    try create_trace.flush();

    var total_backlog: usize = 0;
    for (graph.timelines) |*timeline| {
        const v = timeline.items.len;
        total_backlog += v;
    }
    
    const mean: f64 = @as(f64, @floatFromInt(total_backlog)) / @as(f64, @floatFromInt(graph.users.len));

    var sum_sq_diff: f64 = 0.0;
    for (graph.timelines) |*timeline| {
        const v: f64 = @floatFromInt(timeline.items.len);
        const diff = v - mean;
        sum_sq_diff += diff * diff;
    }

    const backlog_variance = sum_sq_diff / @as(f64, @floatFromInt(graph.users.len - 1));
    const std_dev = std.math.sqrt(backlog_variance);

    const margin_error = 1.96 * (std_dev / std.math.sqrt(@as(f64, @floatFromInt(graph.users.len))));
    const interactions = metrics.likes + metrics.reposts;

    const result = SimResults {
        .processed_events = metrics.processed_events,
        .duration = t_clock,
        .total_likes = metrics.likes,
        .total_reposts = metrics.reposts,
        .total_interactions = interactions,
        .total_ignored = metrics.ignored,
        .total_impressions = metrics.impressions,
        .avg_impressions_per_user = @as(f64, @floatFromInt(metrics.impressions)) / @as(f64, @floatFromInt(graph.users.len)),
        .engagement_rate = @as(f64, @floatFromInt(interactions)) / @as(f64, @floatFromInt(metrics.impressions)),
        .avg_backlog = mean,
        .variance_backlog = backlog_variance,
        .ci_backlog = margin_error,
        .total_sessions = metrics.total_sessions,
        .avg_session_length = metrics.total_online_time / @as(f64, @floatFromInt(metrics.total_sessions)),
        .avg_post_per_session = @as(f64, @floatFromInt(metrics.impressions)) / @as(f64, @floatFromInt(metrics.total_sessions)),
        .timeline_drain_ratio = @as(f64, @floatFromInt(metrics.empty_timeline_ends)) / @as(f64, @floatFromInt(metrics.total_sessions)),
        .posts_at_warmup = @as(f64, @floatFromInt(metrics.post_count)) / @as(f64, @floatFromInt(graph.users.len * simconf.max_post_per_user)),
    };
    
    return result;
}



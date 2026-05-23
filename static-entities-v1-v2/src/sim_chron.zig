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
const User = entities.User;
const Post = entities.Post;
const TraceCreate = entities.TraceCreate;
const TraceAction = entities.TraceAction;
const TimelineEvent = entities.TimelineEvent;
const compareTimelineEvent = entities.compareTimelineEvent;
const Index = entities.Index;

fn CreateRandomAction(user_id: Index, event_id: u64, t_clock: f64, simconf: SimConfig, rng: Random) !Event {
    const action: Action = simconf.user_policy.sample(rng);
      
    const duration_between_actions = simconf.user_inter_action.sample(rng);
    const t_decision = t_clock + duration_between_actions; // Time when the user decides to post
    const interaction_delay = simconf.interaction_delay.sample(rng); // Time of the action to 
    const event = Event{ 
        .time = t_decision + interaction_delay, 
        .type = action, 
        .user_id = user_id, 
        .id = event_id, 
    };
    
    return event;
}

fn schedulePostsUserTimelines(gpa: Allocator, rng: Random, graph: *gn.StaticNetworkGraph, simconf: SimConfig, trace: *Io.Writer) !void {
    // START: post scheduling
    var post_count: u32 = 0;
    for(0..graph.users.len) |uid| {
        for (0..simconf.max_post_per_user) |_| {

            const new_post_decision = simconf.diffusion_post_schedule.sample(rng);
            const creation_delay = simconf.creation_delay.sample(rng);
            const t_new_post = new_post_decision + creation_delay;
            try propagatePost(gpa, rng, graph, simconf, t_new_post, @intCast(uid), post_count);
            
            if (simconf.trace_to_file) {
                const e = TraceCreate {
                    .time = t_new_post,
                    .user_id = @intCast(uid),
                    .post_id = post_count,
                    .event_id = post_count,
                };

                try std.json.Stringify.value(e, .{}, trace);
                try trace.writeAll("\n");
            }
            post_count += 1;
        }
    } 
}

fn propagatePost(gpa: Allocator, rng: Random, graph: *gn.StaticNetworkGraph, simconf: SimConfig, t_clock: f64, user_id: Index, post_id: Index) !void {

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

pub fn diffusionSimulation(gpa: Allocator, rng: Random, simconf: SimConfig, graph: *gn.StaticNetworkGraph, trace: *Io.Writer, create_trace: *Io.Writer) !SimResults {

    const EventQueue: type = Heap(Event, void, entities.compareEvent);

    var processed_events: u64 = 0;
    var t_clock: f64 = 0.0;
    
    var impressions: u64 = 0;
    var interactions: u64 = 0;
    var ignored: u64 = 0;
   
    const total_posts = graph.users.len * simconf.max_post_per_user;

    var starting_events = try gpa.alloc(Event, graph.users.len);
    //defer gpa.free(starting_events); <- NO!! fromOwnedSlice takes ownership of this
 
    try schedulePostsUserTimelines(gpa, rng, graph, simconf, create_trace); 

    // add a first event per every user
    for (0..graph.users.len) |i| { // users are in odrder, that i is the user id
        const event = try CreateRandomAction(@intCast(i), processed_events, 0, simconf, rng);
        starting_events[i] = event;
        processed_events += 1;
    }
    
    var queue = EventQueue.fromOwnedSlice(starting_events, {});
    defer queue.deinit(gpa);
    
    while (t_clock <= simconf.horizon and queue.items.len > 0) : (processed_events += 1) {
        const current_event = queue.remove();
        std.debug.assert(t_clock <= current_event.time);
        t_clock = current_event.time;
       
        const current_uid: Index = current_event.user_id; 
        const event = try CreateRandomAction(current_uid, processed_events, t_clock, simconf, rng);

        try queue.add(gpa, event);
    
        const poped_post: ?TimelineEvent = graph.timelines[current_uid].peek();
        const current_post = poped_post orelse continue;

        // due to propagation delay, a post time t > t_clock could be appended.
        if (current_post.time > t_clock) continue;
        std.debug.assert(current_post.time <= t_clock);
        
        _ = graph.timelines[current_uid].remove();
        // add the post reference to the historic of the current user
        const post_id: Index = current_post.post_id;
        
        graph.user_seen_post.set(current_uid * total_posts + post_id);
        impressions += 1;

        if (simconf.trace_to_file) {
            const trace_event = TraceAction{
                .time = t_clock,
                .type = current_event.type, 
                .event_id = processed_events,
                .user_id = current_uid,
                .post_id = post_id,
            };

            try std.json.Stringify.value(trace_event, .{}, trace);
            try trace.writeAll("\n");
        }
        
        switch (current_event.type) {
            .repost => {
                try propagatePost(gpa, rng, graph, simconf, t_clock, current_uid, post_id);                
                interactions += 1;
            },
            .like => interactions += 1,
            .ignore => ignored += 1,
        }
    }
    
    try trace.flush();
    
    var timeline_backlog: usize = 0;
    for (graph.timelines) |*timeline| {
        timeline_backlog += timeline.items.len;
    }

    const result = SimResults {
        .processed_events = processed_events,
        .duration = t_clock,
        .total_impressions = impressions,
        .total_ignored = ignored,
        .total_interactions = interactions,
        .avg_impressions_per_user = @as(f64, @floatFromInt(impressions)) / @as(f64, @floatFromInt(graph.users.len)),
        .engagement_rate = @as(f64, @floatFromInt(interactions)) / @as(f64, @floatFromInt(impressions)),
        .avg_timeline_backlog = @as(f64, @floatFromInt(timeline_backlog)) / @as(f64, @floatFromInt(graph.users.len)),
    };
    
    return result;
}


// This needs to be refactored, but this is not urgent
// pub fn staticOnePostScheduled(gpa: Allocator, rng: Random, simconf: SimConfig, graph: *gn.StaticNetworkGraph, trace: *Io.Writer) !SimResults {
//
//     const EventQueue: type = Heap(Event, void, entities.compareEvent);
//
//     var processed_events: u64 = 0;
//     var t_clock: f64 = 0.0;
//
//     var impressions: u64 = 0;
//     var interactions: u64 = 0;
//     var ignored: u64 = 0;
//
//     var starting_events = try gpa.alloc(Event, graph.users.len);
//     //defer gpa.free(starting_events); <- NO!! fromOwnedSlice takes ownership of this
//
//     // add a first event per every user
//     for (0..graph.users.len) |i| { // users are in odrder, that i is the user id
//         const event = try CreateRandomAction(@intCast(i), processed_events, 0, simconf, rng);
//         starting_events[i] = event;
//         processed_events += 1;
//     }
//
//     var queue = EventQueue.fromOwnedSlice(starting_events, {});
//     defer queue.deinit(gpa);
//
//     while (t_clock <= simconf.horizon and queue.items.len > 0) : (processed_events += 1) {
//         const current_event = queue.remove();
//         t_clock = current_event.time;
//
//         const current_user_id: Index = current_event.user_id; 
//         const event = try CreateRandomAction(current_user_id, processed_events, t_clock, simconf, rng);
//
//         try queue.add(gpa, event);
//
//         // pop seen post from the user associated with the event
//         const poped_post: ?TimelineEvent = graph.timelines[current_user_id].removeOrNull();
//
//
//         if (current_event.type == .create) {
//             const new_post_index = graph.users.items(.last_published_post)[current_user_id];
//
//             if (new_post_index + 1 > graph.user_post_list[current_user_id].len) { 
//                 // this user has exhausted all it's generating posts
//                 continue;
//             }
//             const new_post_id = graph.user_post_list[current_user_id][new_post_index];
//
//             const trace_event = Trace{
//                 .time = t_clock,
//                 .type = current_event.type,
//                 .event_id = processed_events,
//                 .user_id = current_user_id,
//                 .post_id = new_post_id,
//             };
//             // this might be very slow, it could be better to use the lower json api
//             try std.json.Stringify.value(trace_event, .{}, trace);
//             try trace.writeAll("\n");
//
//             // get the index of the next post
//             graph.users.items(.last_published_post)[current_user_id] += 1;
//
//             // find the post the user has created, the next one on the list
//             const follower_start = graph.users.items(.follower_start)[current_user_id];
//             const follower_count = graph.users.items(.follower_count)[current_user_id];
//
//             for (graph.followers[follower_start..follower_start+follower_count]) |follower_id| {
//                 const propagation_delay = simconf.propagation_delay.sample(rng);
//                 const pe = entities.TimelineEvent{ 
//                     .post_id = new_post_id,             // the new post id
//                     .time = t_clock + propagation_delay,  // when the other users will see it (time of creation of this post)
//                 };
//                 try graph.timelines[follower_id].add(gpa, pe);
//             }
//             continue;
//         }
//         // if a user has no remaing posts in the timeline (eg simulation is very long it could run out of posts)
//         // we CANT stop generating actions, due to potential reply, repor or quotes that could fill the timeline again
//         const current_post = poped_post orelse continue;
//
//         // add the post reference to the historic of the current user
//         const post_id: Index = current_post.post_id;
//         // Use the DynamicBitMap
//         graph.user_seen_post.set(current_user_id * graph.posts.len + post_id);
//         impressions += 1;
//
//         const trace_event = Trace{
//             .time = t_clock,
//             .type = current_event.type,
//             .event_id = processed_events,
//             .user_id = current_user_id,
//             .post_id = post_id,
//         };
//         // this might be very slow, it could be better to use the lower json api
//         try std.json.Stringify.value(trace_event, .{}, trace);
//         try trace.writeAll("\n");
//
//         switch (current_event.type) {
//             .repost => {
//
//                 const follower_start = graph.users.items(.follower_start)[current_user_id];
//                 const follower_count = graph.users.items(.follower_count)[current_user_id];
//
//                 for (graph.followers[follower_start..follower_start+follower_count]) |follower_id| {
//                     //check that user_ptr has not seen this post already...
//                     const p_id: Index = current_post.post_id;
//                     const matrix_index = follower_id * graph.posts.len + p_id; 
//                     if (!graph.user_seen_post.isSet(matrix_index)) {
//                         const propagation_delay = simconf.propagation_delay.sample(rng);
//                         const propagated_event = TimelineEvent{
//                             .time = t_clock + propagation_delay, 
//                             .post_id = p_id,
//                         };
//
//                         try graph.timelines[follower_id].add(gpa, propagated_event);
//
//                     } // else the post was seen_posts to do not add it
//                 }
//
//                 interactions += 1;
//             },
//             .like => interactions += 1,
//             .ignore => ignored += 1,
//             else => {}, // other options from v2
//         }
//     }
//
//     try trace.flush();
//
//     var timeline_backlog: usize = 0;
//     for (graph.timelines) |*timeline| {
//         timeline_backlog += timeline.items.len;
//     }
//
//     const result = SimResults {
//         .processed_events = processed_events,
//         .duration = t_clock,
//         .total_impressions = impressions,
//         .total_ignored = ignored,
//         .total_interactions = interactions,
//         .avg_impressions_per_user = @as(f64, @floatFromInt(impressions)) / @as(f64, @floatFromInt(graph.users.len)),
//         .engagement_rate = @as(f64, @floatFromInt(interactions)) / @as(f64, @floatFromInt(impressions)),
//         .avg_timeline_backlog = @as(f64, @floatFromInt(timeline_backlog)) / @as(f64, @floatFromInt(graph.users.len)),
//     };
//
//     return result;
// }
//


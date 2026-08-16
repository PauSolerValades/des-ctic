const std = @import("std");

const Allocator = std.mem.Allocator;
const Random = std.Random;

const config = @import("config.zig");
const entities = @import("entities.zig");

const SimResults = config.SimResults;
const SimConfig = config.SimConfig;

const Event = entities.Event;
const Action = entities.Action;
const Session = entities.Session;
const User = entities.User;
const Post = entities.Post;

pub fn eventAction(rng: Random, simconf: *const SimConfig, t_clock: f64, user_id: u32, user_session_gen: u32, generated_events: u64) Event {
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

pub fn eventSessionStart(rng: Random, users: *const std.MultiArrayList(User), t_clock: f64, user_id: u32, session_id: u32, generated_events: u64) Event {
    // when will the user go online
    const offline_duration = users.items(.inter_session_time)[user_id].sample(rng);
    const event_start = Event{
        .time = t_clock + offline_duration,
        .type = .{ .session = .start },
        .user_id = user_id,
        .id = generated_events,
        .session_gen = session_id,
    };
    return event_start;
}

pub fn eventSessionEnd(rng: Random, users: *const std.MultiArrayList(User), t_clock: f64, user_id: u32, session_id: u32, generated_events: u64) Event {
    // when will the user go offline
    const duration = users.items(.session_duration)[user_id].sample(rng);
    const event_end = Event{
        .time = t_clock + duration,
        .type = .{ .session = .end },
        .user_id = user_id,
        .id = generated_events,
        .session_gen = session_id,
    };
    return event_end;
}

pub fn eventCreateFirstPost(rng: Random, simconf: *const SimConfig, users: *const std.MultiArrayList(User), t_clock: f64, user_id: u32, session_id: u32, generated_events: u64) Event {
    // Schedule the next post creation for this user
    const creation_delay = simconf.creation_delay.sample(rng);
    const duration_between_creation = users.items(.offset_creation_time)[user_id].sample(rng);

    const new_post = Event{
        .time = t_clock + duration_between_creation + creation_delay,
        .type = .{ .create = {} },
        .user_id = user_id,
        .id = generated_events,
        .session_gen = session_id,
    };
    return new_post;
}

pub fn eventCreatePost(rng: Random, simconf: *const SimConfig, users: *const std.MultiArrayList(User), t_clock: f64, user_id: u32, session_id: u32, generated_events: u64) Event {
    // Schedule the next post creation for this user
    const creation_delay = simconf.creation_delay.sample(rng);
    const duration_between_creation = users.items(.inter_creation_time)[user_id].sample(rng);

    const new_post = Event{
        .time = t_clock + duration_between_creation + creation_delay,
        .type = .{ .create = {} },
        .user_id = user_id,
        .id = generated_events,
        .session_gen = session_id,
    };
    return new_post;
}

pub fn eventPropagate(rng: Random, simconf: *const SimConfig, t_clock: f64, current_uid: u32, post_id: u32, parent_id: u32, generated_events: u64) Event {
    // Sample the delay ONCE for the broadcast
    const delay = simconf.propagation_delay.sample(rng);

    return Event{
        .time = t_clock + delay,
        .type = .{ .propagate = .{ .post_id = post_id, .parent_id = parent_id } },
        .user_id = current_uid, // the author
        .id = generated_events,
        .session_gen = 0, // System event, ignores sessions
    };
}

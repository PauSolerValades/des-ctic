const std = @import("std");

const Heap = @import("heap").Heap;
const dist = @import("distributions");

const Categorical = dist.Categorical;

const config = @import("config.zig");

const Order = std.math.Order;
const ArrayList = std.ArrayList;

const Precision = config.Precision;

pub const Index: type = u32;

const is_v1 = std.mem.eql(u8, "v1", @import("build").build);

pub const User = if (is_v1) UserChron else UserRevChron;

/// User of the simulation
/// - id: identifier
/// - follower start: index of follower starts on StaticNetworkGraph 
/// - follower count: how many users does this user follow. StaticNetworkGraph[u.follower_start..u.follower_start+u.follower_count]
/// - policy: actions of the used with its probability associated
const UserChron = struct {
    id: Index,
    follower_start: Index,
    follower_count: Index, 
    policy: Categorical(Precision, Action),
    max_posts: u32,
};

const UserRevChron = struct {
    id: Index,
    follower_start: Index,
    follower_count: Index, 
    policy: Categorical(Precision, Action),
    max_posts: u32,

    is_online: bool = false,
    session_start_time: f64 = 0.0,
    session_gen: u64 = 0,
    num_posts: u32 = 0,
};


/// Post of the simulation
pub const Post = struct {
    id: Index,
    author: Index,
};


/// Actions performable over a post by a user in the simulation
/// - ignore: nothing
/// - like: adds one to interaction. No behaviour on the simu
/// - repost: propagates to the followers of the user timelines
/// - create: fetches a post from the simulation.
pub const Action = enum { ignore, like, repost };
/// Session states
/// - start: makes the user go back online, see posts and interact with them
/// - end: makes the user go offline: should nuke it's timeline
pub const Session = enum { start, end };

/// For RCAPS and RCOPS. Having this is much better for code clarity
/// and to not make weird stuff happen with the switch
pub const EventType = union(enum) {
    action: Action,
    session: Session,
    create: Index,
};

/// with comptime tricks, when importing event it will be exactly the one
/// expected. (v1=Chronological, not v1 ReverseChronological)
pub const Event = if (is_v1) EventChron else EventRevChron;

/// Simulation Event for Chronological Simulations.
const EventChron = struct {
    time: f64,          // when will the action be due
    type: Action,       // what will the user do
    user_id: Index,     // user id
    id: u64,            // which action is it
};

/// Simulation Event for Reverse-Chronological Simulations
const EventRevChron = struct {
    time: f64,          // when will the action be due
    type: EventType,    // 
    user_id: Index,     // user id
    id: u64,            // which action is it
    session_gen: u64,    // in which session from the user_id does this event belong
};

/// Heap function to compare between events. It access the .time field
/// found on both events. This is used in the global queue.
pub fn compareEvent(context: void, a: Event, b: Event) Order {
    _ = context;
    return std.math.order(a.time, b.time);
}

/// Event to contain in the user own timeline. Contains the minimum information 
/// to get it transmitted everywhere
pub const TimelineEvent = struct {
    time: f64,
    post_id: Index,
};


pub const compareTimelineEvent = if (is_v1) compareTimelineEventChron else compareTimelineEventRevChron;


/// Heap comparison function for user timelines in Chronological Order 
fn compareTimelineEventChron(context: void, a: TimelineEvent, b: TimelineEvent) Order {
    _ = context;
    return std.math.order(a.time, b.time);
}

/// Heap comparison function for user timelines in Reverse-Chronological simulations
fn compareTimelineEventRevChron(context: void, a: TimelineEvent, b: TimelineEvent) Order {
    _ = context;
    return std.math.order(b.time, a.time);
}

/// Auxiliar struct for trace writing. Contains all 
/// the entities that need to be written on the trace
pub const TraceAction = struct {
    time: f64,
    type: Action,
    event_id: u64,
    user_id: Index,
    post_id: Index,
};

pub const TraceCreate = struct {
    time: f64,
    post_id: Index,
    user_id: Index,
    event_id: u64,
};

pub const TraceSession = struct {
    time: f64,
    type: Session,
    event_id: u64,
    user_id: Index,
};

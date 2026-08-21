const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Heap = @import("ds").Heap;

const ds = @import("ds");

const Order = std.math.Order;
const ArrayList = std.ArrayList;

/// Post of the simulation
pub const Post = struct {
    id: u32,
    author: u32,
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
pub const Session = enum { start, end_boredom, end };

pub const SwapReason = enum { simulation_start, session_start, refresh };

/// For RCAPS and RCOPS. Having this is much better for code clarity
/// and to not make weird stuff happen with the switch
pub const EventType = union(enum) {
    action: Action,
    session: Session,
    create: void,
    propagate: Propagate,
};

pub const Propagate = struct {
    post_id: u32,
    parent_id: u32,
};

/// Simulation Event for Reverse-Chronological Simulations
pub const Event = struct {
    time: f64, // when will the action be due
    type: EventType, //
    user_id: u32, // user id
    session_gen: u32, // in which session from the user_id does this event belong
    id: u64, // which action is it
};

/// Heap function to compare between events. It access the .time field
/// found on both events. This is used in the global queue.
pub fn compareEvent(context: void, a: Event, b: Event) Order {
    _ = context;
    const time_order = std.math.order(a.time, b.time);
    if (time_order != .eq) return time_order;
    return std.math.order(a.id, b.id);
}

/// Error set for simulation failures, distinguishing which data structure
/// ran out of memory so the caller can report a precise diagnostic.
pub const SimError = error{
    OutOfMemoryQueue,
    OutOfMemoryTimeline,
    OutOfMemorySMAList,
    OutOfMemoryPagedBitSet,
    OutOfMemoryUserMap,
    WriteFailed,
};

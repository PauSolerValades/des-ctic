const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Heap = @import("ds").Heap;
const stats = @import("distributions");

const ECDF = stats.ECDF;
const NNContDist = stats.NonNegativeContinuousDistribution;

const config = @import("SimConfig.zig");

const ds = @import("ds");

const Order = std.math.Order;
const ArrayList = std.ArrayList;

const Precision = config.Precision;

pub const User = struct {
    id: u32,
    is_online: bool = false,
    session_gen: u32 = 0,

    session_duration: NNContDist(f32),
    inter_session_time: NNContDist(f32),
    inter_creation_time: ECDF(f32, f32),
    offset_creation_time: ECDF(f32, f32),
    num_posts: u32 = 0,
    session_start_time: f64 = 0.0,
};

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

/// Event to contain in the user own timeline. Contains the minimum information
/// to get it transmitted everywhere
pub const TimelineEvent = struct {
    time: f64,
    post_id: u32,
    parent_id: u32, // this for cascade reconstruction. Who reposted this post.
};

/// Heap comparison function for user timelines in Reverse-Chronological simulations
pub fn compareTimelineEvent(context: void, a: TimelineEvent, b: TimelineEvent) Order {
    _ = context;
    return std.math.order(b.time, a.time);
}

const Timeline = ds.DaryHeap(TimelineEvent, 8, void, compareTimelineEvent);

pub const WhichTimeline = enum { a, b };
pub const UserTimeline = struct {
    a: Timeline,
    b: Timeline,
    active: WhichTimeline,

    pub fn getActive(self: *@This()) *Timeline {
        return switch (self.active) {
            .a => &self.a,
            .b => &self.b,
        };
    }

    pub fn getBackground(self: *@This()) *Timeline {
        return switch (self.active) {
            .a => &self.b,
            .b => &self.a,
        };
    }

    pub fn switchTl(self: *@This()) void {
        switch (self.active) {
            .a => self.active = .b,
            .b => self.active = .a,
        }
    }

    pub fn create(gpa: Allocator, capacity: usize) !@This() {
        var a: Timeline = .empty;
        var b: Timeline = .empty;

        try a.ensureTotalCapacity(gpa, capacity);
        try b.ensureTotalCapacity(gpa, capacity);

        return UserTimeline{
            .a = a,
            .b = b,
            .active = .a,
        };
    }

    pub fn delete(self: @This(), gpa: Allocator) void {
        self.a.deinit(gpa);
        self.b.deinit(gpa);
    }
};

/// Error set for simulation failures, distinguishing which data structure
/// ran out of memory so the caller can report a precise diagnostic.
pub const SimError = error{
    OutOfMemoryQueue,
    OutOfMemoryTimeline,
    OutOfMemorySMAList,
    OutOfMemoryPagedBitSet,
    WriteFailed,
};

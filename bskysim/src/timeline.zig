const std = @import("std");
const Allocator = std.mem.Allocator;
// const Order = std.math.Order;

const ds = @import("ds");

/// Event to contain in the user own timeline. Contains the minimum information
/// to get it transmitted everywhere
pub const TimelineEvent = struct {
    time: f64,
    post_id: u32,
    parent_id: u32, // this for cascade reconstruction. Who reposted this post.
};

/// Heap comparison function for user timelines in Reverse-Chronological simulations
// pub fn compareTimelineEvent(context: void, a: TimelineEvent, b: TimelineEvent) Order {
//     _ = context;
//     return std.math.order(b.time, a.time);
// }

// const Timeline = ds.DaryHeap(TimelineEvent, 8, void, compareTimelineEvent);
const Timeline = ds.Stack(TimelineEvent);

pub const WhichTimeline = enum { a, b };
pub const UserTimeline = struct {
    a: Timeline,
    b: Timeline,
    active: WhichTimeline,

    pub fn create(gpa: Allocator, capacity: usize) !@This() {
        const a: Timeline = try .initCapacity(gpa, capacity);
        const b: Timeline = try .initCapacity(gpa, capacity);

        return UserTimeline{
            .a = a,
            .b = b,
            .active = .a,
        };
    }

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

    pub fn delete(self: *@This(), gpa: Allocator) void {
        self.a.deinit(gpa);
        self.b.deinit(gpa);
    }
};

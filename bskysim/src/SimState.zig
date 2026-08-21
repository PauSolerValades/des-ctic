const std = @import("std");
const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;
const AutoHashMap = std.AutoHashMapUnmanaged;

const stats = @import("distributions");
const Cat = stats.Categorical;
const DUnif = stats.DiscreteUniform;
const ECDF = stats.ECDF;

const entities = @import("entities.zig");
const Topology = @import("Topology.zig");
const timeline = @import("timeline.zig");
const UserTimeline = timeline.UserTimeline;

const ds = @import("ds");
const SegmentedMultiArrayList = ds.SegmentedMultiArrayList;
const PagedBitSet = ds.PagedBitSet;

const Post = entities.Post;

const NNContDist = stats.NonNegativeContinuousDistribution;
const DistTag = std.meta.Tag(NNContDist(f32));

pub const User = struct {
    id: u32,
    is_online: bool,
    session_gen: u32,
    num_posts: u32,
    session_start_time: f64,
    seen_posts: AutoHashMap(usize, u32),
    liked_posts: AutoHashMap(usize, u32),
    reposted_posts: AutoHashMap(usize, u32),
    timeline: UserTimeline,
};

users: MultiArrayList(User),
posts: SegmentedMultiArrayList(Post, 16),

const Self = @This();

pub fn create(arena: Allocator, gpa: Allocator, topology: *const Topology) !Self {
    var users: MultiArrayList(User) = .empty;
    try users.ensureTotalCapacity(arena, topology.nodes);

    for (0..topology.nodes) |i| {
        //TODO: what about ensuring capacity on the seen, liked, and reposted?
        // idk we can estimate it as we do with the timeline... so we have to let it grow
        // analyze better how to manage that memory, maybe with a gpa makes more sense given the
        // relation with the duration of the simulation
        const user: User = .{
            .id = @intCast(i),
            .is_online = false,
            .session_gen = 0,
            .num_posts = 0,
            .session_start_time = 0.0,
            .seen_posts = .empty,
            .liked_posts = .empty,
            .reposted_posts = .empty,
            .timeline = try .create(gpa, 1024),
        };

        users.appendAssumeCapacity(user);
    }

    return .{
        .users = users,
        .posts = .empty,
    };
}

pub fn delete(self: *Self, arena: Allocator, gpa: Allocator) void {
    for (0..self.users.len) |i| {
        self.users.items(.timeline)[i].delete(gpa);
        self.users.items(.seen_posts)[i].deinit(gpa);
        self.users.items(.liked_posts)[i].deinit(gpa);
        self.users.items(.reposted_posts)[i].deinit(gpa);
    }

    self.posts.deinit(arena);
    self.users.deinit(arena);
}

/// Per-worker copy. users is deep-copied (ECDF bins stay shared with the
/// original: immutable, owned by the main arena, which outlives all workers).
/// Everything else is fresh per-worker scratch. Pair with delete().
// pub fn clone(self: *const @This(), arena: Allocator, gpa: Allocator) !@This() {
//     var self_copy = @This(){
//         .users = try self.users.clone(arena),
//         .timelines = try gpa.alloc(UserTimeline, self.users.len),
//         .posts = .empty,
//         .user_seen_post = .empty,
//         .user_interact_post = .empty,
//     };

//     for (0..self_copy.timelines.len) |i| {
//         self_copy.timelines[i] = try .create(gpa, 1024);
//     }

//     return self_copy;
// }

pub fn reset(self: *@This()) void {
    for (0..self.users.len) |i| {
        self.users.items(.is_online)[i] = false;
        self.users.items(.session_gen)[i] = 0;
        self.users.items(.num_posts)[i] = 0;
        self.users.items(.session_start_time)[i] = 0.0;
        const tl = &self.users.items(.timeline)[i];
        tl.active = .a;
        tl.a.clearRetainingCapacity();
        tl.b.clearRetainingCapacity();
        self.users.items(.seen_posts)[i].clearRetainingCapacity();
        self.users.items(.liked_posts)[i].clearRetainingCapacity();
        self.users.items(.reposted_posts)[i].clearRetainingCapacity();
    }

    self.posts.clearRetainingCapacity();
}

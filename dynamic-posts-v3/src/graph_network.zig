const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const DynamicBitSet = std.DynamicBitSetUnmanaged;
const MultiArrayList = std.MultiArrayList;
const Random = std.Random;

const build = @import("build");

const ds = @import("ds");

const Heap = ds.Heap;
const SMAList = ds.SegmentedMultiArrayList;
const PagedBitSet = ds.PagedBitSet;

const dist = @import("distributions");
const Categorical = dist.Categorical;

const entities = @import("entities.zig");
const TimelineEvent = entities.TimelineEvent;
const User = entities.User;
const Post = entities.Post;
const Index = entities.Index;
const Action = entities.Action;

const TimelineHeap = Heap(entities.TimelineEvent, void, entities.compareTimelineEvent);

const Precision = @import("config.zig").Precision;

const NetworkJson = @import("json_loading.zig").NetworkJson;

/// Static Network Graph that means:
/// 1. No new users will be added to the network.
/// 2. No new posts will be added to the network.
/// 3. No new follows between users will be added to the network
pub const Topology = struct {
    users: MultiArrayList(User), // Contains all users of the simulations
    followers: []Index, // Compressed Sparse Row, aka Static Adjacency Array
    timelines: []TimelineHeap, // Timelines for every user. Optimaly, we should use FixedBufferAllocator
    posts: SMAList(Post, 16), // uwu
    user_seen_post: PagedBitSet(16), // N-to-M matrix: user was exposed to post (diagnostic, counts all impressions)
    user_interacted_post: PagedBitSet(16), // N-to-M matrix: user interacted with post (like/repost/own) — desensitization gate

    pub fn create(gpa: Allocator, arena: Allocator, parsed_network: NetworkJson) !Topology {
        // Converteix les coses de la network json en Static Network Graph
        var users: MultiArrayList(User) = try .initCapacity(arena, parsed_network.users.len);

        for (parsed_network.users) |user| { // ParsedUser
            const cat: Categorical(Precision, Action) = try .init(arena, user.policy, user.actions);
            const u = User{
                .id = user.id,
                .follower_start = 0,
                .max_posts = user.max_posts,
                .policy = cat,
            };
            users.appendAssumeCapacity(u);
        }

        var followers: []Index = try arena.alloc(Index, parsed_network.followers.len);

        // temporary list of arraylists to hold the followers:
        var tmp_followers: []ArrayList(Index) = try gpa.alloc(ArrayList(Index), parsed_network.users.len);
        for (0..tmp_followers.len) |i| {
            tmp_followers[i] = .empty;
        }
        defer {
            for (tmp_followers) |*f| {
                f.deinit(gpa);
            }
            gpa.free(tmp_followers);
        }

        for (parsed_network.followers) |edge| {
            const follower_id = edge.follower_id;
            const followed_id = edge.followed_id;
            try tmp_followers[followed_id].append(gpa, follower_id);
        }

        var acc: usize = 0;
        for (tmp_followers, 0..) |follow, i| {
            const follower_count = follow.items.len;
            users.items(.follower_start)[i] = @intCast(acc);
            @memcpy(followers[acc .. acc + follower_count], follow.items);
            acc += follower_count;
        }

        var timelines: []TimelineHeap = try gpa.alloc(TimelineHeap, parsed_network.users.len);

        for (0..timelines.len) |i| {
            timelines[i] = .empty;
        }

        const posts: SMAList(Post, 16) = .empty;
        // User Homogeneity, max_post is the same per every user
        const seen_matrix: PagedBitSet(16) = try .initPages(arena, parsed_network.users.len, 16);
        const interacted_matrix: PagedBitSet(16) = try .initPages(arena, parsed_network.users.len, 16);

        return .{
            .users = users,
            .followers = followers,
            .timelines = timelines,
            .posts = posts,
            .user_seen_post = seen_matrix,
            .user_interacted_post = interacted_matrix,
        };
    }

    pub fn delete(self: *Topology, gpa: Allocator, arena: Allocator) void {
        self.users.deinit(arena);
        arena.free(self.followers);

        for (self.timelines) |timeline| {
            timeline.deinit(gpa);
        }
        gpa.free(self.timelines);

        self.user_seen_post.deinit(arena);
        self.user_interacted_post.deinit(arena);
        self.posts.deinit(arena);
    }

    /// Old create, when posts where in the data generation.
    /// This will probably be good to keep arround if i implement checkpoint
    pub fn createGraphFromCheckpoint(gpa: Allocator, parsed_network: NetworkJson) !Topology {
        // Converteix les coses de la network json en Static Network Graph
        var users: MultiArrayList(User) = try .initCapacity(gpa, parsed_network.users.len);
        var posts: MultiArrayList(Post) = try .initCapacity(gpa, parsed_network.posts.len);

        for (parsed_network.users) |user| { // ParsedUser
            const cat: Categorical(Precision, Action) = try .init(gpa, user.policy, user.actions);
            const u = User{ .id = user.id, .follower_start = 0, .policy = cat };
            users.appendAssumeCapacity(u);
        }

        for (parsed_network.posts) |post| {
            const p = Post{ .id = post.id, .author = 0 };
            posts.appendAssumeCapacity(p);
        }

        var followers: []Index = try gpa.alloc(Index, parsed_network.followers.len);

        // temporary list of arraylists to hold the followers:
        var tmp_followers: []ArrayList(Index) = try gpa.alloc(ArrayList(Index), parsed_network.users.len);
        for (0..tmp_followers.len) |i| {
            tmp_followers[i] = .empty;
        }
        defer {
            for (tmp_followers) |*f| {
                f.deinit(gpa);
            }
            gpa.free(tmp_followers);
        }

        for (parsed_network.followers) |edge| {
            const follower_id = edge.follower_id;
            const followed_id = edge.followed_id;
            try tmp_followers[follower_id].append(gpa, followed_id);
        }

        var acc: usize = 0;
        for (tmp_followers, 0..) |follow, i| {
            const follower_count = follow.items.len;
            users.items(.follower_start)[i] = @intCast(acc);
            @memcpy(followers[acc .. acc + follower_count], follow.items);
            acc += follower_count;
        }

        var timelines: []TimelineHeap = try gpa.alloc(TimelineHeap, parsed_network.users.len);

        for (0..timelines.len) |i| {
            timelines[i] = .empty;
        }

        const total_bits = parsed_network.users.len * parsed_network.posts.len;
        var matrix = try DynamicBitSet.initEmpty(gpa, total_bits);

        var owned_posts: []ArrayList(Index) = try gpa.alloc(ArrayList(Index), parsed_network.users.len);
        for (0..owned_posts.len) |i| {
            owned_posts[i] = .empty;
        }
        defer {
            for (owned_posts) |*f| {
                f.deinit(gpa);
            }
        }

        for (parsed_network.user_owns_post) |relation| {
            const flat_index = (relation.user_id * parsed_network.posts.len) + relation.post_id;
            matrix.set(flat_index);

            posts.items(.author)[relation.post_id] = relation.user_id;

            try owned_posts[relation.user_id].append(gpa, relation.post_id);

            // this is now not possible, as the post time will be generated by the user
            // const pe = entities.TimelineEvent { .post_id = relation.post_id, .time = parsed_network.posts[relation.post_id].time };
            // try timelines[relation.user_id].add(gpa, pe);
        }

        var user_post_list = try gpa.alloc([]Index, owned_posts.len);
        for (0..owned_posts.len) |i| {
            const user_posts_owned = try gpa.alloc(Index, owned_posts[i].items.len);
            @memcpy(user_posts_owned[0..owned_posts[i].items.len], owned_posts[i].items);
            user_post_list[i] = user_posts_owned;
        }

        return .{
            .users = users,
            .posts = posts,
            .followers = followers,
            .timelines = timelines,
            .user_seen_post = matrix,
            .user_interacted_post = .empty,
        };
    }
};

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const DynamicBitSet = std.DynamicBitSetUnmanaged;
const MultiArrayList = std.MultiArrayList;
const Random = std.Random;

const build = @import("build");

const ds = @import("ds");

const DaryHeap = ds.DaryHeap;
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

const TimelineHeap = DaryHeap(entities.TimelineEvent, 8, void, entities.compareTimelineEvent);

const Precision = @import("config.zig").Precision;

const BinaryGraph = @import("json_loading.zig").BinaryGraph;

fn fillPareto(io: std.Io, filename: []const u8, shape_buff: []f64, scale_buff: []f64) !void {
    var buf: [32 * 10000]u8 = undefined;
    const contents = try std.Io.Dir.readFile(std.Io.Dir.cwd(), io, filename, &buf);
    var tok = std.mem.tokenizeSequence(u8, contents, "\n");
    var index: usize = 0;
    while (tok.next()) |line| {
        var values = std.mem.tokenizeAny(u8, line, " \t");

        const shape_str = values.next() orelse continue;
        const scale_str = values.next() orelse continue;

        shape_buff[index] = try std.fmt.parseFloat(f64, shape_str);
        scale_buff[index] = try std.fmt.parseFloat(f64, scale_str);
        index += 1;
    }
}

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

    pub fn create(io: std.Io, gpa: Allocator, arena: Allocator, rng: std.Random, topology: BinaryGraph) !Topology {
        // Converteix les coses de la network json en Static Network Graph
        const num_users: usize = @intCast(topology.num_nodes);
        var users: MultiArrayList(User) = try .initCapacity(arena, num_users);
        var map: std.AutoHashMapUnmanaged(u32, usize) = .{};
        defer map.deinit(gpa);

        const sample_size = 10000;
        var session_length_scale: [sample_size]f64 = undefined;
        var session_length_shape: [sample_size]f64 = undefined;
        try fillPareto(io, "params/session_duration_params.txt", &session_length_shape, &session_length_scale);

        var session_gap_scale: [sample_size]f64 = undefined;
        var session_gap_shape: [sample_size]f64 = undefined;
        try fillPareto(io, "params/inter_session_params.txt", &session_gap_shape, &session_gap_scale);

        var creation_scale: [sample_size]f64 = undefined;
        var creation_shape: [sample_size]f64 = undefined;
        try fillPareto(io, "params/inter_creation_params.txt", &creation_shape, &creation_scale);

        for (topology.user_ids) |original_id| {
            const result = map.getOrPut(gpa, original_id) catch @panic("OOM in hashmap");
            if (result.found_existing) continue;
            const local_id: Index = @intCast(users.len);
            result.value_ptr.* = local_id;

            const u_session_length = rng.uintLessThan(usize, sample_size);
            const shape_session_length = session_length_shape[u_session_length];
            const scale_session_length = session_length_scale[u_session_length];

            const u_session_gap = rng.uintLessThan(usize, sample_size);
            const shape_session_gap = session_gap_shape[u_session_gap];
            const scale_session_gap = session_gap_scale[u_session_gap];

            const u_creation = rng.uintLessThan(usize, sample_size);
            const shape_creation = creation_shape[u_creation];
            const scale_creation = creation_scale[u_creation];
            // pick a random number for all of the three lists
            const u = User{
                .id = local_id,
                .follower_start = 0,

                .session_duration = .init(shape_session_length, scale_session_length),
                .inter_session_time = .init(shape_session_gap, scale_session_gap),
                .inter_creation_time = .init(shape_creation, scale_creation),
            };
            users.appendAssumeCapacity(u);
        }

        const num_users_actual = users.len;
        const num_edges: usize = @intCast(topology.num_edges);
        var followers: []Index = try arena.alloc(Index, num_edges);

        // temporary list of arraylists to hold the followers:
        var tmp_followers: []ArrayList(Index) = try gpa.alloc(ArrayList(Index), num_users_actual);
        for (0..tmp_followers.len) |i| {
            tmp_followers[i] = .empty;
        }
        defer {
            for (tmp_followers) |*f| {
                f.deinit(gpa);
            }
            gpa.free(tmp_followers);
        }

        var ei: usize = 0;
        while (ei < topology.edges.len) : (ei += 2) {
            const actor_id = topology.edges[ei];
            const subject_id = topology.edges[ei + 1];
            const local_actor = map.get(actor_id) orelse @panic("edge references unknown actor");
            const local_subject = map.get(subject_id) orelse @panic("edge references unknown subject");
            try tmp_followers[local_subject].append(gpa, @intCast(local_actor));
        }

        var acc: usize = 0;
        for (tmp_followers, 0..) |follow, i| {
            const follower_count = follow.items.len;
            users.items(.follower_start)[i] = @intCast(acc);
            @memcpy(followers[acc .. acc + follower_count], follow.items);
            acc += follower_count;
        }

        var timelines: []TimelineHeap = try gpa.alloc(TimelineHeap, num_users_actual);

        for (0..timelines.len) |i| {
            timelines[i] = .empty;
            try timelines[i].ensureTotalCapacity(gpa, 1024);
        }

        const posts: SMAList(Post, 16) = .empty;
        const seen_matrix: PagedBitSet(16) = try .initPages(arena, num_users_actual, 16);
        const interacted_matrix: PagedBitSet(16) = try .initPages(arena, num_users_actual, 16);

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
};

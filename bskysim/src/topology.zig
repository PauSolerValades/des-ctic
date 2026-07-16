const std = @import("std");
const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;
const ArrayList = std.ArrayList;

const entities = @import("entities.zig");
const BinaryGraph = @import("load-topology.zig").BinaryGraph;

const ds = @import("ds");
const UserTimeline = entities.UserTimeline;
const SMAList = ds.SegmentedMultiArrayList;
const PagedBitSet = ds.PagedBitSet;

const User = entities.User;
const Post = entities.Post;

fn fillPareto(io: std.Io, filename: []const u8, shape_buff: []f32, scale_buff: []f32) !void {
    var buf: [32 * 10000]u8 = undefined;
    const contents = try std.Io.Dir.readFile(std.Io.Dir.cwd(), io, filename, &buf);
    var tok = std.mem.tokenizeSequence(u8, contents, "\n");
    var index: usize = 0;
    while (tok.next()) |line| {
        var values = std.mem.tokenizeAny(u8, line, " \t");

        const shape_str = values.next() orelse continue;
        const scale_str = values.next() orelse continue;

        shape_buff[index] = try std.fmt.parseFloat(f32, shape_str);
        scale_buff[index] = try std.fmt.parseFloat(f32, scale_str);
        index += 1;
    }
}

pub const Topology = struct {
    nodes: u32,
    edges: u32,
    csr: []u32,
    start: []u32,

    pub fn create(arena: Allocator, data: BinaryGraph) !@This() {
        var followers: []u32 = try arena.alloc(u32, data.num_edges);
        var followers_start: []u32 = try arena.alloc(u32, data.num_nodes);

        // as its temporal and I don't want to clutter the precious arena, lets init one in itself
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        const allocator = gpa.allocator();
        defer {
            const deinit_status = gpa.deinit();
            //fail test; can't try in defer as defer is executed after we return
            if (deinit_status == .leak) @panic("OH GOD PLEASE NO, NO");
        }
        // temporary list of arraylists to hold the followers:
        var tmp_followers: []ArrayList(u32) = try allocator.alloc(ArrayList(u32), data.num_nodes);
        for (0..tmp_followers.len) |i| {
            tmp_followers[i] = .empty;
        }
        defer {
            for (tmp_followers) |*f| {
                f.deinit(allocator);
            }
            allocator.free(tmp_followers);
        }

        var ei: usize = 0;
        while (ei < data.num_edges * 2) : (ei += 2) {
            const actor_id = data.edges[ei];
            const subject_id = data.edges[ei + 1];
            try tmp_followers[subject_id].append(allocator, @intCast(actor_id));
        }

        var acc: usize = 0;
        for (tmp_followers, 0..) |follow, i| {
            const follower_count = follow.items.len;
            followers_start[i] = @intCast(acc);
            @memcpy(followers[acc .. acc + follower_count], follow.items);
            acc += follower_count;
        }

        return Topology{
            .nodes = data.num_nodes,
            .edges = data.num_edges,
            .csr = followers,
            .start = followers_start,
        };
    }

    pub fn delete(self: *@This(), arena: Allocator) void {
        arena.free(self.csr);
        arena.free(self.start);
    }
};

pub const SimState = struct {
    users: MultiArrayList(User),
    timelines: []UserTimeline,
    posts: SMAList(Post, 16),
    user_seen_post: PagedBitSet(16),
    user_interact_post: PagedBitSet(16),

    pub fn create(io: Io, arena: Allocator, gpa: Allocator, rng: Random, topology: *const Topology, paramsdir: []const u8) !@This() {
        var users: std.MultiArrayList(User) = try .initCapacity(arena, topology.nodes);
        try wireUsers(io, rng, topology, &users, paramsdir);

        var timelines: []UserTimeline = try gpa.alloc(UserTimeline, users.len);

        for (0..timelines.len) |i| {
            timelines[i] = try .create(gpa, 1024);
        }

        const posts: SMAList(Post, 16) = .empty;
        const seen_matrix: PagedBitSet(16) = try .initPages(arena, users.len, 16);
        const interacted_matrix: PagedBitSet(16) = try .initPages(arena, users.len, 16);

        return SimState{
            .users = users,
            .timelines = timelines,
            .posts = posts,
            .user_seen_post = seen_matrix,
            .user_interact_post = interacted_matrix,
        };
    }

    /// every user in Size_monotonic.bin is in id order, that's perfect for us.
    fn wireUsers(io: Io, rng: Random, topology: *const Topology, users: *MultiArrayList(User), paramsdir: []const u8) !void {
        const sample_size = 10000;

        var session_duration_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const session_duration_path = try std.fmt.bufPrint(&session_duration_path_buf, "{s}/session_duration_params.txt", .{paramsdir});

        var inter_session_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const inter_session_path = try std.fmt.bufPrint(&inter_session_path_buf, "{s}/inter_session_params.txt", .{paramsdir});

        var inter_creation_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const inter_creation_path = try std.fmt.bufPrint(&inter_creation_path_buf, "{s}/inter_creation_params.txt", .{paramsdir});

        var session_length_scale: [sample_size]f32 = undefined;
        var session_length_shape: [sample_size]f32 = undefined;
        try fillPareto(io, session_duration_path, &session_length_shape, &session_length_scale);

        var session_gap_scale: [sample_size]f32 = undefined;
        var session_gap_shape: [sample_size]f32 = undefined;
        try fillPareto(io, inter_session_path, &session_gap_shape, &session_gap_scale);

        var creation_scale: [sample_size]f32 = undefined;
        var creation_shape: [sample_size]f32 = undefined;
        try fillPareto(io, inter_creation_path, &creation_shape, &creation_scale);

        // iterate over the user_ids. As they are monotonically increasing its fine
        for (0..topology.nodes) |id| {
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
                .id = @intCast(id),
                .session_duration = .init(shape_session_length, scale_session_length),
                .inter_session_time = .init(shape_session_gap, scale_session_gap),
                .inter_creation_time = .init(shape_creation, scale_creation),
            };
            users.appendAssumeCapacity(u);
        }
    }

    pub fn dumpUsers(self: *const @This(), io: Io, path: []const u8) !void {
        const session_duration_slice = self.users.items(.session_duration);
        const inter_session_slice = self.users.items(.inter_session_time);
        const inter_creation_slice = self.users.items(.inter_creation_time);

        const dist_file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer dist_file.close(io);

        var buf: [4096]u8 = undefined;
        var userdist_writer = dist_file.writerStreaming(io, &buf);
        const userdist = &userdist_writer.interface;

        try userdist.writeAll("session_duration_xmin session_duration_alpha inter_session_time_xmin inter_session_time_alpha inter_creation_time_xmin inter_creation_time_alpha\n");

        for (0..self.users.len) |i| {
            try userdist.print("{d} {d} {d} {d} {d} {d}\n", .{
                session_duration_slice[i].scale,
                session_duration_slice[i].shape,
                inter_session_slice[i].scale,
                inter_session_slice[i].shape,
                inter_creation_slice[i].scale,
                inter_creation_slice[i].shape,
            });
        }
        try userdist.flush();
    }

    pub fn delete(self: *@This(), arena: Allocator, gpa: Allocator) void {
        self.users.deinit(arena);

        for (self.timelines) |timeline| {
            timeline.delete(gpa);
        }
        gpa.free(self.timelines);

        self.user_seen_post.deinit(arena);
        self.user_interact_post.deinit(arena);
        self.posts.deinit(arena);
    }

    pub fn reset(self: *@This()) void {
        for (0..self.users.len) |i| {
            self.users.items(.is_online)[i] = false;
            self.users.items(.session_gen)[i] = 0;
            self.users.items(.num_posts)[i] = 0;
            self.users.items(.session_start_time)[i] = 0.0;
            self.timelines[i].active = .a;
            self.timelines[i].a.clearRetainingCapacity();
            self.timelines[i].b.clearRetainingCapacity();
        }

        self.posts.clearRetainingCapacity();
        self.user_seen_post.clearRetainingCapacity();
        self.user_interact_post.clearRetainingCapacity();
    }
};

pub const UserSampled = struct {
    session_duration_xmin: f32,
    session_duration_alpha: f32,
    inter_session_time_xmin: f32,
    inter_session_time_alpha: f32,
    inter_creation_time_xmin: f32,
    inter_creation_time_alpha: f32,
};

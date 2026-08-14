const std = @import("std");
const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const build_options = @import("build_options");
const pool = @import("pool.zig");

const entities = @import("entities.zig");
const Topology = @import("Topology.zig");

const ds = @import("ds");
const UserTimeline = entities.UserTimeline;
const SMAList = ds.SegmentedMultiArrayList;
const PagedBitSet = ds.PagedBitSet;

const User = entities.User;
const Post = entities.Post;

const TimelinePool = pool.TimelinePool;

const UserConf = @import("config.zig").UserConf;

users: MultiArrayList(User),
timelines: []UserTimeline,
posts: SMAList(Post, 16),
user_seen_post: PagedBitSet(16),
user_interact_post: PagedBitSet(16),
timeline_pool: if (build_options.use_pool) TimelinePool else void = if (build_options.use_pool) undefined else {},

pub fn create(io: Io, arena: Allocator, gpa: Allocator, rng: Random, topology: *const Topology, user_conf: []UserConf) !@This() {
    var users: std.MultiArrayList(User) = try .initCapacity(arena, topology.nodes);
    try wireUsers(io, rng, topology, &users, user_conf);

    var timelines: []UserTimeline = try gpa.alloc(UserTimeline, users.len);

    // ponytail: slot_capacity 1024 matches original .create(gpa, 1024).
    // Increase if stress test shows gpa_fallbacks > 0.
    var self = @This(){
        .users = users,
        .timelines = timelines,
        .posts = .empty,
        .user_seen_post = undefined,
        .user_interact_post = undefined,
        .timeline_pool = if (build_options.use_pool) try TimelinePool.init(gpa, users.len, 1024) else {},
    };

    const tl_alloc = if (build_options.use_pool) self.timeline_pool.allocator() else gpa;
    for (0..timelines.len) |i| {
        timelines[i] = try .create(tl_alloc, 1024);
    }

    self.user_seen_post = try .initPages(arena, users.len, 16);
    self.user_interact_post = try .initPages(arena, users.len, 16);

    return self;
}

/// every user in Size_monotonic.bin is in id order, that's perfect for us.
fn wireUsers(io: Io, rng: Random, topology: *const Topology, users: *MultiArrayList(User), user_conf: []UserConf) !void {
    // figure out how many distinct pairs are going to be in the

    const sample_size = 1;
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

    const tl_alloc = if (build_options.use_pool) self.timeline_pool.allocator() else gpa;
    for (self.timelines) |timeline| {
        timeline.delete(tl_alloc);
    }
    gpa.free(self.timelines);

    if (build_options.use_pool) self.timeline_pool.deinit();

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

    if (build_options.use_pool) self.timeline_pool.reset();
}

pub fn poolFallbacks(self: *const @This()) usize {
    if (build_options.use_pool) return self.timeline_pool.gpa_fallbacks;
    return 0;
}

pub const UserSampled = struct {
    session_duration_xmin: f32,
    session_duration_alpha: f32,
    inter_session_time_xmin: f32,
    inter_session_time_alpha: f32,
    inter_creation_time_xmin: f32,
    inter_creation_time_alpha: f32,
};

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

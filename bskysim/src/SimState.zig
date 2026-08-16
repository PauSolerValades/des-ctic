const std = @import("std");
const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const stats = @import("distributions");
const Cat = stats.Categorical;
const DUnif = stats.DiscreteUniform;
const ECDF = stats.ECDF;

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

const UserConf = @import("SimConfig.zig").UserConf;
const NNContDist = stats.NonNegativeContinuousDistribution;
const DistTag = std.meta.Tag(NNContDist(f32));

users: MultiArrayList(User),
timelines: []UserTimeline,
posts: SMAList(Post, 16),
user_seen_post: PagedBitSet(16),
user_interact_post: PagedBitSet(16),
timeline_pool: if (build_options.use_pool) TimelinePool else void = if (build_options.use_pool) undefined else {},

pub fn create(io: Io, arena: Allocator, gpa: Allocator, rng: Random, topology: *const Topology, user_conf: []UserConf) !@This() {
    var users: std.MultiArrayList(User) = try .initCapacity(arena, topology.nodes);
    try wireUsers(io, arena, rng, topology, &users, user_conf);

    var timelines: []UserTimeline = try gpa.alloc(UserTimeline, users.len);

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

/// Per-worker copy. users is deep-copied (ECDF bins stay shared with the
/// original: immutable, owned by the main arena, which outlives all workers).
/// Everything else is fresh per-worker scratch. Pair with delete().
pub fn clone(self: *const @This(), arena: Allocator, gpa: Allocator) !@This() {
    var self_copy = @This(){
        .users = try self.users.clone(arena),
        .timelines = try gpa.alloc(UserTimeline, self.users.len),
        .posts = .empty,
        .user_seen_post = try .initPages(arena, self.users.len, 16),
        .user_interact_post = try .initPages(arena, self.users.len, 16),
        .timeline_pool = if (build_options.use_pool) try TimelinePool.init(gpa, self.users.len, 1024) else {},
    };

    const tl_alloc = if (build_options.use_pool) self_copy.timeline_pool.allocator() else gpa;
    for (0..self_copy.timelines.len) |i| {
        self_copy.timelines[i] = try .create(tl_alloc, 1024);
    }

    return self_copy;
}

const tabular = @import("tabular");

/// Builds a distribution from a row of a params table.
/// Both the fit pipeline and the distributions package use R conventions:
/// gamma (shape, rate), lognormal (meanlog, sdlog), weibull (shape, scale),
/// pareto (shape, scale) — pass-through. Only gpd differs: the fit pipeline
/// emits (xi, sigma, mu) while the package takes (location, scale, shape).
fn distFromRow(tag: DistTag, params: []const f32) NNContDist(f32) {
    return switch (tag) {
        .constant => .{ .constant = .init(params[0]) },
        .exponential => .{ .exponential = .init(params[0]) },
        .uniform => .{ .uniform = .init(params[0], params[1], .cc) },
        .lognormal => .{ .lognormal = .init(params[0], params[1]) },
        .weibull => .{ .weibull = .init(params[0], params[1]) },
        .gamma => .{ .gamma = .init(params[0], params[1]) },
        .pareto => .{ .pareto = .init(params[0], params[1]) },
        .gpareto => .{ .gpareto = .init(params[2], params[1], params[0]) },
    };
}

/// every user in Size_monotonic.bin is in id order, that's perfect for us.
fn wireUsers(io: Io, arena: Allocator, rng: Random, topology: *const Topology, users: *MultiArrayList(User), user_conf: []UserConf) !void {
    // scratch: everything that dies when this function returns
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const arloc = scratch.allocator();

    var weights = try arloc.alloc(f32, user_conf.len);
    var data = try arloc.alloc(usize, user_conf.len);
    var ecdf_posts = try arloc.alloc(ECDF(f32, f32), user_conf.len);
    var ecdf_offset = try arloc.alloc(ECDF(f32, f32), user_conf.len);
    var session_params = try arloc.alloc(tabular.Table, user_conf.len);
    var gap_params = try arloc.alloc(tabular.Table, user_conf.len);

    for (0..user_conf.len) |i| {
        const uconf = user_conf[i];

        data[i] = i;
        weights[i] = uconf.probability;

        const posts_content = try Io.Dir.cwd().readFileAlloc(io, uconf.ecdf_post_creation_path, arloc, .unlimited);
        const posts_tsv = try tabular.parse(arloc, posts_content, .{ .separator = '\t', .header = false });
        // bins are shared by every User -> must outlive wireUsers -> outer arena
        const ecdf_data = try posts_tsv.sliceRowAs(f32, 0, arloc);
        ecdf_posts[i] = try ECDF(f32, f32).init(arena, ecdf_data);

        const offset_content = try Io.Dir.cwd().readFileAlloc(io, uconf.ecdf_offset_creation_path, arloc, .unlimited);
        const offset_tsv = try tabular.parse(arloc, offset_content, .{ .separator = '\t', .header = false });
        ecdf_offset[i] = try ECDF(f32, f32).init(arena, try offset_tsv.sliceRowAs(f32, 0, arloc));

        const session_content = try Io.Dir.cwd().readFileAlloc(io, uconf.session_params_path, arloc, .unlimited);
        session_params[i] = try tabular.parse(arloc, session_content, .tsv);

        const gap_content = try Io.Dir.cwd().readFileAlloc(io, uconf.gap_params_path, arloc, .unlimited);
        gap_params[i] = try tabular.parse(arloc, gap_content, .tsv);
    }

    const cat: Cat(f32, usize) = try .init(arloc, weights, data);

    // iterate over the user_ids. As they are monotonically increasing its fine
    for (0..topology.nodes) |id| {
        const pair_idx = cat.sample(rng);
        const uconf = user_conf[pair_idx];

        const sd = session_params[pair_idx];
        const gp = gap_params[pair_idx];

        const sd_row = DUnif(usize).init(0, sd.n_rows, .co).sample(rng);
        const gp_row = DUnif(usize).init(0, gp.n_rows, .co).sample(rng);

        // [1..] skips the did column — only the distribution params are floats.
        const session_params_parsed = try tabular.fieldsAs(f32, sd.rows[sd_row][1..], arloc);
        const gap_params_parsed = try tabular.fieldsAs(f32, gp.rows[gp_row][1..], arloc);

        users.appendAssumeCapacity(.{
            .id = @intCast(id),
            .session_duration = distFromRow(uconf.session_duration, session_params_parsed),
            .inter_session_time = distFromRow(uconf.inter_session_time, gap_params_parsed),
            .inter_creation_time = ecdf_posts[pair_idx],
            .offset_creation_time = ecdf_offset[pair_idx],
        });
    }
}

pub fn dumpUsers(self: *const @This(), io: Io, path: []const u8) !void {
    const session_duration_slice = self.users.items(.session_duration);
    const inter_session_slice = self.users.items(.inter_session_time);

    const dist_file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer dist_file.close(io);

    var buf: [4096]u8 = undefined;
    var userdist_writer = dist_file.writerStreaming(io, &buf);
    const userdist = &userdist_writer.interface;

    try userdist.writeAll("session_duration inter_session_time\n");

    for (0..self.users.len) |i| {
        try session_duration_slice[i].format(userdist);
        try userdist.writeByte(' ');
        try inter_session_slice[i].format(userdist);
        try userdist.writeByte('\n');
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

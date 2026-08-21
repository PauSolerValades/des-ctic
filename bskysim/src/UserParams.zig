const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Random = std.Random;
const MultiArrayList = std.MultiArrayList;

const Topology = @import("Topology.zig");

const stats = @import("distributions");
const ECDF = stats.ECDF;
const NNContDist = stats.NonNegativeContinuousDistribution;
const Cat = stats.Categorical;
const DUnif = stats.DiscreteUniform;
const DistTag = std.meta.Tag(NNContDist(f32));

pub const UserParams = struct {
    id: u32,
    session_duration: NNContDist(f32),
    inter_session_time: NNContDist(f32),
    inter_creation_time: ECDF(f32, f32),
    offset_creation_time: ECDF(f32, f32),
};

users: MultiArrayList(UserParams),

const Self = @This();

/// Initializes all immutable state (which distributions the user follows)
/// every user in Size_monotonic.bin is in id order, that's perfect for us.
fn create(io: Io, arena: Allocator, rng: Random, topology: *const Topology) !Self {
    var users: MultiArrayList(UserParams) = try .initCapactiy(arena, topology.nodes);
    // scratch: everything that dies when this function returns
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const arloc = scratch.allocator();

    var weights = try arloc.alloc(f32, users.len);
    var data = try arloc.alloc(usize, users.len);
    var ecdf_posts = try arloc.alloc(ECDF(f32, f32), users.len);
    var ecdf_offset = try arloc.alloc(ECDF(f32, f32), users.len);
    var session_params = try arloc.alloc(tabular.Table, users.len);
    var gap_params = try arloc.alloc(tabular.Table, users.len);

    for (0..users.len) |i| {
        const uconf = users[i];

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
        const uconf = users[pair_idx];

        const sd = session_params[pair_idx];
        const gp = gap_params[pair_idx];

        const sd_row = DUnif(usize).init(0, sd.n_rows, .co).sample(rng);
        const gp_row = DUnif(usize).init(0, gp.n_rows, .co).sample(rng);

        // TODO: this is sketchy as FUCK we should make it better
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

    return .{ .users = users };
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

pub fn dump(self: *const Self, io: Io, path: []const u8) !void {
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

pub fn delete(self: *Self, arena: Allocator) void {
    self.users.deinit(arena);
}

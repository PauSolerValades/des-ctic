const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Random = std.Random;
const MultiArrayList = std.MultiArrayList;
const ArrayList = std.ArrayList;

const Topology = @import("Topology.zig");

const stats = @import("distributions");
const ECDF = stats.ECDF;
const NNContDist = stats.NonNegativeContinuousDistribution;
const Cat = stats.Categorical;
const DUnif = stats.DiscreteUniform;
const DistTag = std.meta.Tag(NNContDist(f32));

const json = std.json;
const Scanner = std.json.Scanner;
const Token = std.json.Token;

const parse = @import("dist-json-parse/parse.zig");
const ParseError = parse.ParseError;
const JsonScannerError = parse.JsonScannerError;
const ReadFileError = std.Io.Dir.ReadFileAllocError;
const readKeyNumber = parse.readKeyNumber;
const readKeyBool = parse.readKeyBool;
const readKeyString = parse.readKeyString;

pub const UserParams = struct {
    id: u32,
    session_duration: NNContDist(f32),
    inter_session_time: NNContDist(f32),
    inter_creation_time: ECDF(f32, f32),
    offset_creation_time: ECDF(f32, f32),
};

/// Struct analogous to the user JSON provided information
pub const UserConf = struct {
    session_duration: DistTag,
    inter_session_time: DistTag,
    session_params_path: []const u8,
    gap_params_path: []const u8,
    ecdf_post_creation_path: []const u8,
    ecdf_offset_creation_path: []const u8,
    probability: f32,
};

const Field = blk: {
    const fields = @typeInfo(UserConf).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var vals: [fields.len]u8 = undefined;
    for (fields, 0..) |f, i| {
        names[i] = f.name;
        vals[i] = i;
    }
    break :blk @Enum(u8, .exhaustive, &names, &vals);
};

pub fn create(io: Io, gpa: Allocator, rng: Random, num_users: usize, userparams_file: []const u8, stderr: *Io.Writer) !MultiArrayList(UserParams) {
    var load_data_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const tmpalloc = load_data_arena.allocator();
    defer load_data_arena.deinit();

    const content = try Io.Dir.cwd().readFileAlloc(io, userparams_file, tmpalloc, .unlimited);
    defer gpa.free(content);

    const params_pair: []UserConf = try parseUsers(tmpalloc, content, stderr);

    try checkValidity(params_pair, io, stderr);

    return configToParams(io, gpa, rng, num_users, params_pair);
}

pub fn parseUsers(gpa: Allocator, content: []const u8, stderr: *Io.Writer) (ParseError || JsonScannerError || error{ InvalidCharacter, WriteFailed })![]UserConf {
    var scanner = Scanner.initCompleteInput(gpa, content);
    defer scanner.deinit();

    if (try scanner.next() != Token.array_begin) return error.UnexpectedToken;

    var users: ArrayList(UserConf) = .empty;
    defer users.deinit(gpa);

    var index: usize = 1;
    while (true) {
        const tok = try scanner.next();
        if (tok == Token.array_end) break;
        if (tok != Token.object_begin) return error.UnexpectedToken;

        var user: UserConf = undefined;
        const num_fields: usize = @typeInfo(Field).@"enum".fields.len;
        var have: std.StaticBitSet(num_fields) = .empty;

        while (true) {
            const key = try scanner.next();
            if (key == Token.object_end) break;
            if (key != Token.string) return error.UnexpectedToken;

            const field = std.meta.stringToEnum(Field, key.string) orelse {
                try stderr.print("Parameter '{s}' is not an valid user parameter\n", .{key.string});
                return error.UnknownParameter;
            };
            have.set(@intFromEnum(field));

            switch (field) {
                .session_duration => user.session_duration = try parse.readDistTag(&scanner, stderr),
                .inter_session_time => user.inter_session_time = try parse.readDistTag(&scanner, stderr),
                .session_params_path => user.session_params_path = try readKeyString(gpa, &scanner),
                .gap_params_path => user.gap_params_path = try readKeyString(gpa, &scanner),
                .ecdf_post_creation_path => user.ecdf_post_creation_path = try readKeyString(gpa, &scanner),
                .ecdf_offset_creation_path => user.ecdf_offset_creation_path = try readKeyString(gpa, &scanner),
                .probability => user.probability = try readKeyNumber(&scanner, f32),
            }
        }

        if (have.count() != num_fields) {
            inline for (@typeInfo(Field).@"enum".fields) |f| {
                if (!have.isSet(f.value)) try stderr.print("missing field '{s}' in item {d}\n", .{ f.name, index });
            }
            return error.MissingField;
        }
        try users.append(gpa, user);
        index += 1;
    }

    return users.toOwnedSlice(gpa);
}

/// Initializes all immutable state (which distributions the user follows)
/// every user in Size_monotonic.bin is in id order, that's perfect for us.
fn configToParams(io: Io, arena: Allocator, rng: Random, num_nodes: usize, param_pair: []UserConf) !MultiArrayList(UserParams) {
    // scratch: everything that dies when this function returns
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const arloc = scratch.allocator();

    var users: MultiArrayList(UserParams) = .empty;
    try users.ensureTotalCapacity(arena, num_nodes);

    var weights = try arloc.alloc(f32, param_pair.len);
    var data = try arloc.alloc(usize, param_pair.len);
    var ecdf_posts = try arloc.alloc(ECDF(f32, f32), param_pair.len);
    var ecdf_offset = try arloc.alloc(ECDF(f32, f32), param_pair.len);
    var session_params = try arloc.alloc(tabular.Table, param_pair.len);
    var gap_params = try arloc.alloc(tabular.Table, param_pair.len);

    for (0..param_pair.len) |i| {
        const uconf = param_pair[i];

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
    for (0..num_nodes) |id| {
        const pair_idx = cat.sample(rng);
        const uconf = param_pair[pair_idx];

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

    return users;
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

pub const UserConfigError = error{
    RepeatedUserPair,
    ProbabilityNotOne,
    EcdfPostFileError,
    EcdfOffsetFileError,
    SampleParamsFileError,
};

pub fn checkValidity(confs: []const UserConf, io: Io, stderr: *Io.Writer) (error{OutOfMemory} || UserConfigError || error{WriteFailed})!void {
    const Pair = struct {
        first: DistTag,
        second: DistTag,
    };

    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();

    var pairs: ArrayList(Pair) = .empty;
    defer pairs.deinit(allocator);

    var acc_prob: f32 = 0.0;
    for (confs, 0..) |u, i| {
        const pair = .{ @tagName(u.session_duration), @tagName(u.inter_session_time) };

        std.Io.Dir.cwd().access(io, u.ecdf_post_creation_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): ecdf_post_creation_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.ecdf_post_creation_path, @errorName(err) });
            return error.EcdfPostFileError;
        };
        std.Io.Dir.cwd().access(io, u.session_params_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): session_params_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.session_params_path, @errorName(err) });
            return error.SampleParamsFileError;
        };
        std.Io.Dir.cwd().access(io, u.gap_params_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): gap_params_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.gap_params_path, @errorName(err) });
            return error.SampleParamsFileError;
        };
        std.Io.Dir.cwd().access(io, u.ecdf_offset_creation_path, .{ .read = true }) catch |err| {
            try stderr.print("users[{d}] pair ({s}, {s}): ecdf_offset_creation_path '{s}' not readable: {s}\n", .{ i, pair[0], pair[1], u.ecdf_offset_creation_path, @errorName(err) });
            return error.EcdfOffsetFileError;
        };
        acc_prob += u.probability;

        // this should be not very big, a small linear search won't hurt anyone
        for (pairs.items) |p| {
            if (p.first == u.session_duration and p.second == u.inter_session_time) return error.RepeatedUserPair;
        }
        // terrorism
        try pairs.append(allocator, .{ .first = u.session_duration, .second = u.inter_session_time });
    }

    // TODO: check that the Distribution picked to generate the posts is not able to
    // generate a post later than warmup_time. that is:
    // warmup_inter_post_time.sample(rng) <= conf.warmup_time <==> P(x > conf.warmup_time) = 0 <==> 1 - F(x) = 0
    // warmup_inter_post_time.cdf(conf.warmup_time) = 1
    // the problem is that not all the distributions implemented have cdf, and they are not even tested lolol
    // therefore, we will ---for now--- trust the user

    // TODO: make a reasonable tolerance, not just made up
    if (!std.math.approxEqRel(f32, acc_prob, 1.0, 0.001)) return error.ProbabilityNotOne;
}

pub fn dump(users: *const MultiArrayList(UserParams), io: Io, path: []const u8) !void {
    const session_duration_slice = users.items(.session_duration);
    const inter_session_slice = users.items(.inter_session_time);

    const dist_file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer dist_file.close(io);

    var buf: [4096]u8 = undefined;
    var userdist_writer = dist_file.writerStreaming(io, &buf);
    const userdist = &userdist_writer.interface;

    try userdist.writeAll("session_duration inter_session_time\n");

    for (0..users.len) |i| {
        try session_duration_slice[i].format(userdist);
        try userdist.writeByte(' ');
        try inter_session_slice[i].format(userdist);
        try userdist.writeByte('\n');
    }
    try userdist.flush();
}

pub fn format(
    users: *const MultiArrayList(UserParams),
    writer: *std.Io.Writer,
) !void {
    _ = users;
    try writer.writeAll("\n");
    try writer.writeAll("+--------------------------+\n");
    try writer.print("| USER SAMPLING STRATEGY  |\n", .{});
    try writer.writeAll("+--------------------------+\n");

    try writer.writeAll("TODO: OWO UWU OWO :ODOT");
}

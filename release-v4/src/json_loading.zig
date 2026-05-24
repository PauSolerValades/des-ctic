const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;

const Heap = @import("heap").Heap;
const dist = @import("distributions");

const DiscDist = dist.DiscreteDistribution;

const Categorical = dist.Categorical;

const structs = @import("config.zig");
const entities = @import("entities.zig");
const Precision = structs.Precision;

const User = entities.User;
const Post = entities.Post;
const TimelineEvent = entities.TimelineEvent;
const Index = entities.Index;

const compareTimelineEvent = entities.compareTimelineEvent;

pub const NetworkJson = struct {
    users: []ParsedUser,
    followers: []ParsedFollow,
};

const ParsedUser = struct {
    id: Index,
    actions: []entities.Action,
    policy: []Precision,
};

const ParsedPost = struct {
    id: Index,
    //time: f64,
};

const ParsedFollow = struct {
    follower_id: Index,
    followed_id: Index,
};

const ParsedOwns = struct {
    user_id: Index,
    post_id: Index,
};

pub fn loadJson(gpa: Allocator, io: Io, path: []const u8, comptime T: type) !json.Parsed(T) {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);
    // We use .ignore_unknown_fields = true so comments or extra metadata in JSON don't crash it
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true };

    // parsed_result holds the data AND the arena allocator used for strings/slices in the JSON
    const parsed_result = try std.json.parseFromSlice(T, gpa, content, options);

    return parsed_result;
}

pub const BinaryGraph = struct {
    num_nodes: u32,
    user_ids: []u32,
    num_edges: u32,
    edges: []u32, // flat array, every edge is two consecutive u32s: (actor_id, subject_id)

    pub fn create(io: Io, gpa: Allocator, path: []const u8) !@This() {
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var buf: [64]u8 = undefined;
        var reader: Io.File.Reader = file.reader(io, &buf);
        const ri = &reader.interface;

        const num_nodes = try ri.takeInt(u32, .little);
        // std.debug.print("There are: {d}\n", .{num_nodes});

        const users: []u32 = try gpa.alloc(u32, num_nodes);

        for (0..num_nodes) |i| {
            const user_id = try ri.takeInt(u32, .little);
            // std.debug.print("user: {}\n", .{user_id});
            users[i] = user_id;
        }

        const num_edges = try ri.takeInt(u32, .little);
        // std.debug.print("There are {d} edges\n", .{num_edges});

        const edges = try gpa.alloc(u32, num_edges * 2);

        for (0..num_edges * 2) |j| {
            const user = try ri.takeInt(u32, .little);
            edges[j] = user;
        }

        return BinaryGraph{
            .num_nodes = num_nodes,
            .user_ids = users,
            .num_edges = num_edges,
            .edges = edges,
        };
    }

    pub fn delete(self: *@This(), gpa: Allocator) void {
        gpa.free(self.edges);
        gpa.free(self.user_ids);
    }
};



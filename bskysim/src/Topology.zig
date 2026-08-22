const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const BinaryGraph = @import("load-topology.zig").BinaryGraph;

nodes: u32,
edges: u32,
csr: []u32,
start: []u32,

pub fn create(arena: Allocator, scratch: Allocator, data: BinaryGraph) !@This() {
    var followers: []u32 = try arena.alloc(u32, data.num_edges);
    var followers_start: []u32 = try arena.alloc(u32, data.num_nodes);

    // temporary list of arraylists to hold the followers; freed at the end,
    // not part of the long-lived arena.
    var tmp_followers: []ArrayList(u32) = try scratch.alloc(ArrayList(u32), data.num_nodes);
    for (0..tmp_followers.len) |i| {
        tmp_followers[i] = .empty;
    }
    defer {
        for (tmp_followers) |*f| {
            f.deinit(scratch);
        }
        scratch.free(tmp_followers);
    }

    var ei: usize = 0;
    while (ei < data.num_edges * 2) : (ei += 2) {
        const actor_id = data.edges[ei];
        const subject_id = data.edges[ei + 1];
        try tmp_followers[subject_id].append(scratch, @intCast(actor_id));
    }

    var acc: usize = 0;
    for (tmp_followers, 0..) |follow, i| {
        const follower_count = follow.items.len;
        followers_start[i] = @intCast(acc);
        @memcpy(followers[acc .. acc + follower_count], follow.items);
        acc += follower_count;
    }

    return @This(){
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

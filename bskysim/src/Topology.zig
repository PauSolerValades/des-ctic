const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const BinaryGraph = @import("load-topology.zig").BinaryGraph;

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

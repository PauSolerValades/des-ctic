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
    max_posts: ?u32,
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



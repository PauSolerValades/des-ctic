const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const argz = @import("eazy_args");
const traces = @import("traces");

const Arg = argz.Argument;
const Opt = argz.Option;
const Flag = argz.Flag;

const ParseErrors = argz.ParseErrors;

const to_buckets = @import("bin_to_tsv.zig");

const def = .{
    .name = "specific",
    .description = "Parses the .bin traces into a usable dataset",
    .required = .{
        Arg([]const u8, "traces", "Folder were all traces are located."),
    },
    .options = .{
        Opt(usize, "buckets", "b", 256, "How many bucket the program hashed the info."),
        Opt([]const u8, "bucketdir", "p", "/tmp/cascade-building/", "Where the temporal buckets should be processed."),
        Opt([]const u8, "outputfile", "o", "cascade.tsv", "Path to store the cascade.tsv"),
    },
    .flags = .{},
};

pub const header = "run_id\tpost_id\tuser_id\tparent_id\ttype\ttime";

pub fn parseAndValidateCmdArgs(iter: *std.process.Args.Iterator, stdout: *Io.Writer, stderr: *Io.Writer) error{WriteFailed}!argz.Reify(def) {
    const args = argz.parseArgsPosix(def, iter, stdout, stderr) catch |err| {
        switch (err) {
            ParseErrors.HelpShown => try stdout.flush(),
            else => try stderr.flush(),
        }
        std.process.exit(0);
    };

    if (!std.mem.eql(u8, std.fs.path.extension(args.outputfile), ".tsv")) {
        try stderr.writeAll("The output file must be a path to an .tsv file");
        try stderr.flush();
        std.process.exit(1);
    }

    return args;
}

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &bufferr);
    const stderr = &stderr_writer.interface;

    const io = init.io;
    const gpa = init.gpa;

    var iter = init.minimal.args.iterate();
    const args = try parseAndValidateCmdArgs(&iter, stdout, stderr);
    try stdout.print("Creating cascades of '{s}' with {d} buckets\n", .{ args.traces, args.buckets });
    try stdout.flush();

    const tracesDir = Io.Dir.cwd().openDir(io, args.traces, .{ .access_sub_paths = false, .iterate = true }) catch |err| {
        try stderr.print("Failed to open traces dir '{s}': {}\n", .{ args.traces, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer tracesDir.close(io);

    var ids: std.ArrayList(usize) = .empty;
    defer ids.deinit(gpa);

    obtainRunIds(io, gpa, tracesDir, &ids) catch |err| {
        try stderr.print("Failed to read traces dir '{s}': {}\n", .{ args.traces, err });
        try stderr.flush();
        std.process.exit(1);
    };

    const num_buckets = args.buckets;

    const bucket_ifaces = try gpa.alloc(*Io.Writer, num_buckets);
    defer gpa.free(bucket_ifaces);

    const bucketsDir = createOrClearBucketsDir(io, args.bucketdir) catch |err| {
        try stderr.print("Oof cannot init buckets dir: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    const bucket_writers = try gpa.alloc(BucketWriter, num_buckets);
    defer {
        for (bucket_writers) |*bw| bw.deinit(io);
        gpa.free(bucket_writers);
    }
    for (bucket_writers, bucket_ifaces, 0..) |*bw, *iface, i| {
        try bw.init(io, bucketsDir, i);
        iface.* = bw.iface();
    }

    for (ids.items) |id| {
        try to_buckets.processCreation(io, id, bucket_ifaces, &tracesDir);
        try to_buckets.processPropagation(io, id, bucket_ifaces, &tracesDir);
        try to_buckets.processRepost(io, id, bucket_ifaces, &tracesDir);
    }

    for (bucket_ifaces) |b| try b.flush();

    try stdout.writeAll("Traces processed into buckets! Merging buckets...\n");
    try stdout.flush();

    const mergeBuckets = @import("merge_buckets.zig").mergeBuckets;
    mergeBuckets(io, gpa, num_buckets, args.bucketdir, args.outputfile, stderr) catch |err| {
        try stderr.print("Probelm opening the buckets directory :(. Error: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.print("Buckets Merged in {s}", .{args.outputfile});
    try stdout.flush();
}

const BucketWriter = struct {
    file: Io.File,
    writer: Io.File.Writer,
    buffer: [16 * 1024]u8,

    fn init(self: *@This(), io_: Io, dir: Io.Dir, index: usize) !void {
        var name_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "{d}_bucket.tsv", .{index});
        self.file = try dir.createFile(io_, path, .{ .truncate = true });
        self.writer = self.file.writer(io_, &self.buffer);
    }

    fn deinit(self: *@This(), io_: Io) void {
        self.file.close(io_);
    }

    fn iface(self: *@This()) *Io.Writer {
        return &self.writer.interface;
    }
};

fn createOrClearBucketsDir(io: Io, bucket_path: []const u8) !Io.Dir {
    _ = try Io.Dir.cwd().createDirPathStatus(io, bucket_path, .default_dir);

    const bucketsDir = try Io.Dir.cwd().openDir(io, bucket_path, .{ .access_sub_paths = false, .iterate = true });

    var dir_iter = bucketsDir.iterate();
    while (try dir_iter.next(io)) |entry| {
        try bucketsDir.deleteFile(io, entry.name);
    }

    return bucketsDir;
}

fn obtainRunIds(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    list: *std.ArrayList(usize),
) (error{ NoRunId, OutOfMemory } || std.fmt.ParseIntError || Io.Dir.Iterator.Error)!void {
    const Set = @import("set").Set;

    var iterator = dir.iterate();
    var run_ids: Set(usize) = .empty;
    defer run_ids.deinit(gpa);
    while (true) {
        const element = try iterator.next(io);

        if (element) |entry| {
            const len = entry.name.len;
            if (!std.mem.eql(u8, entry.name[len - 4 .. len], ".bin")) continue;

            const id = getRunId(entry.name) catch continue;
            _ = try run_ids.add(gpa, id);
        } else {
            break;
        }
    }

    // Copy the set into an array list for easy iteration
    var set_iter = run_ids.iterator();
    while (set_iter.next()) |id| {
        try list.append(gpa, id.*);
    }

    return;
}

fn getRunId(filename: []const u8) (error{NoRunId} || std.fmt.ParseIntError)!usize {
    const marker = "-";
    const index = std.mem.indexOf(u8, filename, marker);
    if (index) |i| {
        return try std.fmt.parseInt(usize, filename[0..i], 10);
    } else {
        return error.NoRunId;
    }
}

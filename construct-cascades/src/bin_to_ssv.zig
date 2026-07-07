const std = @import("std");
const Io = std.Io;
const traces = @import("traces");

pub const line_fmt = "{d} {d} {d} {d} {s} {d}\n";

fn nextTrace(comptime T: type, reader: *Io.Reader) !?T {
    const bytes = reader.take(@sizeOf(T)) catch |err| {
        switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return err,
        }
    };
    return std.mem.bytesAsValue(T, bytes).*;
}

pub fn processRepost(io: Io, id: usize, bucket_writers: []*Io.Writer, traceDir: *const Io.Dir) !void {

    // open the creation file
    var rt_trace_buf: [32]u8 = undefined;
    const rt_trace_name = try std.fmt.bufPrint(&rt_trace_buf, "{d}-action_trace.bin", .{id});

    const rt_file = try traceDir.openFile(io, rt_trace_name, .{ .mode = .read_only });
    defer rt_file.close(io);
    var buffer: [4 * 1024]u8 = undefined;
    var trace_reader = rt_file.reader(io, &buffer);
    const trace = &trace_reader.interface;

    while (try nextTrace(traces.TraceAction, trace)) |pc| {
        if (pc.type == .ignore) continue;

        const hashed_id = std.hash.Wyhash.hash(0, std.mem.asBytes(&pc.post_id));
        const bucket_id = hashed_id % bucket_writers.len;

        // run_id post_id user_id type timestamp
        try bucket_writers[bucket_id].print(line_fmt, .{ id, pc.post_id, pc.user_id, pc.parent_id, @tagName(pc.type), pc.time });
    }

    return;
}

pub fn processPropagation(io: Io, id: usize, bucket_writers: []*Io.Writer, traceDir: *const Io.Dir) !void {

    // open the creation file
    var prop_trace_buf: [32]u8 = undefined;
    const prop_trace_name = try std.fmt.bufPrint(&prop_trace_buf, "{d}-propagation_trace.bin", .{id});

    const prop_file = try traceDir.openFile(io, prop_trace_name, .{ .mode = .read_only });
    defer prop_file.close(io);
    var buffer: [4 * 1024]u8 = undefined;
    var trace_reader = prop_file.reader(io, &buffer);
    const trace = &trace_reader.interface;

    while (try nextTrace(traces.TracePropagation, trace)) |pc| {
        const hashed_id = std.hash.Wyhash.hash(0, std.mem.asBytes(&pc.post_id));
        const bucket_id = hashed_id % bucket_writers.len;

        // run_id post_id user_id type timestamp
        try bucket_writers[bucket_id].print(line_fmt, .{ id, pc.post_id, pc.user_id, -1, "propagation", pc.time });
    }

    return;
}

pub fn processCreation(io: Io, id: usize, bucket_writers: []*Io.Writer, traceDir: *const Io.Dir) !void {

    // open the creation file
    var creation_trace_buf: [32]u8 = undefined;
    const creation_trace_name = try std.fmt.bufPrint(&creation_trace_buf, "{d}-create_trace.bin", .{id});

    const creation_file = try traceDir.openFile(io, creation_trace_name, .{ .mode = .read_only });
    defer creation_file.close(io);

    var buffer: [4 * 1024]u8 = undefined;
    var trace_reader = creation_file.reader(io, &buffer);
    const trace = &trace_reader.interface;

    while (try nextTrace(traces.TraceCreate, trace)) |pc| {
        const hashed_id = std.hash.Wyhash.hash(0, std.mem.asBytes(&pc.post_id));
        const bucket_id = hashed_id % bucket_writers.len;

        // run_id post_id user_id type timestamp
        try bucket_writers[bucket_id].print(line_fmt, .{ id, pc.post_id, pc.user_id, pc.user_id, "creation", pc.time });
    }

    return;
}

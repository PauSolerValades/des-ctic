const std = @import("std");
const Io = std.Io;

const e = @import("entities.zig");

/// Auxiliar struct for trace writing. Contains all
/// the entities that need to be written on the trace
pub const TraceAction = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    post_id: u32,
    parent_id: u32,
    type: e.Action,
};

pub const TraceCreate = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    post_id: u32,
};

pub const TraceSession = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    type: e.Session,
    backlog: u32,
};

pub const TracePropagation = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    post_id: u32,
};

pub const TraceSwap = struct {
    time: f64,
    user_id: u32,
    reason: e.SwapReason,
};

/// Bundles the four trace writers into a single struct so they can be passed
/// as one parameter instead of four. Each field is a pointer to an Io.Writer.
pub const TraceWriters = struct {
    action: *Io.Writer,
    session: *Io.Writer,
    create: *Io.Writer,
    propagate: *Io.Writer,
    swaps: *Io.Writer,
};

/// The five files a run produces, as suffixes appended to "<run_id>".
pub const trace_suffixes = [_][]const u8{
    "-action_trace.bin",
    "-session_trace.bin",
    "-create_trace.bin",
    "-propagation_trace.bin",
    "-swap_trace.bin",
};

/// A run is only usable when all five trace files exist and are non-empty.
/// Interrupted simulations leave zero-byte files behind; if cascade and dataset
/// disagree on which runs exist, their outputs disagree too.
pub fn isCompleteRun(dir: Io.Dir, io: Io, id: usize) !bool {
    var name_buf: [64]u8 = undefined;
    for (trace_suffixes) |suffix| {
        const name = try std.fmt.bufPrint(&name_buf, "{d}{s}", .{ id, suffix });
        const st = dir.statFile(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (st.size == 0) return false;
    }
    return true;
}

/// converts an arbitrary type trace struct into a jsonl file (struct per line)
pub fn bytesToJsonl(io: Io, comptime T: type, read_file: []const u8, write_file: []const u8) !void {
    const n = @sizeOf(T);

    var jsonl_buffer: [4 * 1024]u8 = undefined;
    const jsonl_file = try Io.Dir.cwd().createFile(io, write_file, .{ .read = false });
    defer jsonl_file.close(io);
    var jsonl_file_writer = jsonl_file.writer(io, &jsonl_buffer);
    const writer = &jsonl_file_writer.interface;

    if (Io.Dir.cwd().openFile(io, read_file, .{})) |file| {
        defer file.close(io);

        var buf: [4 * 1024]u8 = undefined;
        var reader: Io.File.Reader = file.reader(io, &buf);
        const ri = &reader.interface;

        // The binary records are preceded by a text header terminated by '\n'.
        try skipHeader(ri);

        while (true) {
            const bytes = ri.take(n) catch |err| {
                switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return reader.err.?,
                }
            };

            const event = std.mem.bytesAsValue(T, bytes);
            try std.json.Stringify.value(event, .{}, writer);
            try writer.writeAll("\n");
        }
    } else |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            std.debug.print("unable to open file: {}\n", .{err});
        },
        else => return err,
    }

    try writer.flush();
}

/// Writes a self-describing text header, terminated by '\n', at the start of a
/// trace file. `:` separates key from value, `,` separates entries.
///
///   type:<name>,record_size:<n>,endian:little,
///   name:<field>,offset:<byte>,kind:<tag>[,variants:<v0>|<v1>|...],
///   name:<field>,...
///
/// Offsets/sizes come from @offsetOf/@sizeOf at comptime: the compiler is free
/// to reorder or pad fields however it wants, and the reader trusts this header
/// rather than assuming declaration order.
///
/// NOTE: this is inlines to be compiletime in order to adapt to potenital reorganizations
/// the compiler might do to the structs adequately.
pub fn writeHeader(writer: *Io.Writer, comptime T: type) !void {
    try writer.print("type:{s},record_size:{d},endian:little", .{ shortName(T), @sizeOf(T) });
    inline for (@typeInfo(T).@"struct".fields) |f| {
        try writer.print(",name:{s},offset:{d},kind:{s}", .{ f.name, @offsetOf(T, f.name), kindTag(f.type) });
        switch (@typeInfo(f.type)) {
            .@"enum" => |en| {
                try writer.writeAll(",variants:");
                inline for (en.fields, 0..) |v, i| {
                    if (i != 0) try writer.writeAll("|");
                    try writer.writeAll(v.name);
                }
            },
            else => {}, // NOTE: this is ommited on puropose as the traces just have enums
        }
    }
    try writer.writeAll("\n");
}

/// Consumes the leading text header (through the first '\n'). Binary records
/// follow immediately after. A truncated/empty file leaves the reader at EOF.
pub fn skipHeader(reader: *Io.Reader) !void {
    while (true) {
        const byte = reader.take(1) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
        if (byte[0] == '\n') return;
    }
}

fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |i| return full[i + 1 ..];
    return full;
}

// NOTE: I think there must be a far better way to print a type that it's not this in compiletime lol
fn kindTag(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .float => |f| std.fmt.comptimePrint("f{d}", .{f.bits}),
        .int => |i| std.fmt.comptimePrint("{s}{d}", .{ if (i.signedness == .signed) "i" else "u", i.bits }),
        .bool => "bool",
        .@"enum" => std.fmt.comptimePrint("u{d}", .{@sizeOf(T) * 8}),
        else => @compileError("unsupported trace field type: " ++ @typeName(T)),
    };
}

test "writeHeader reflects layout, skipHeader lands on the records" {
    const Kind = enum { alpha, beta };
    const Rec = struct { a: f64, b: u32, k: Kind };

    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeHeader(&w, Rec);
    const text = w.buffered();

    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
    try std.testing.expect(std.mem.startsWith(u8, text, "type:Rec,record_size:"));
    try std.testing.expect(std.mem.indexOf(u8, text, ",name:a,offset:0,kind:f64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kind:u8,variants:alpha|beta") != null);

    // header + one record, then confirm the skip lands exactly on the record.
    var data: [512]u8 = undefined;
    @memcpy(data[0..text.len], text);
    const rec = Rec{ .a = 1.5, .b = 7, .k = .beta };
    @memcpy(data[text.len..][0..@sizeOf(Rec)], std.mem.asBytes(&rec));

    var r: Io.Reader = .fixed(data[0 .. text.len + @sizeOf(Rec)]);
    try skipHeader(&r);
    try std.testing.expectEqual(@as(usize, @sizeOf(Rec)), (try r.take(@sizeOf(Rec))).len);
}

//! Tabular: zero-copy TSV/CSV/SSV reader for Zig 0.16.0.
//!
//! Fields borrow from the input; only the outer slice-of-slices is
//! allocated — plus copies of escaped-quote fields, the one case that
//! cannot borrow. Designed for an arena (free once), but leak-free under
//! any allocator: `Table.deinit` and the error paths free everything
//! `parse` allocated. Arena allocators ignore `free`, so the cleanup costs
//! nothing there.
//!
//! Credits (design lifted wholesale, thank you):
//! - Quoted-field scanner and `""` unescaping: zarko
//!   <https://github.com/TynK-M/zarko>
//! - BOM skip, `strict_field_count` and `trim_whitespace` dialect flags:
//!   serde.zig <https://github.com/OrlovEvgeny/serde.zig>
//! - zig_csv <https://github.com/matthewtolman/zig_csv> was surveyed and
//!   deliberately *not* copied (SWAR bitmask parser; overkill here).

const std = @import("std");

/// How the input is formatted.
pub const Dialect = struct {
    separator: u8,
    header: bool,
    /// RFC 4180 compliance knobs. Defaults are the sane RFC behavior;
    /// you'll almost never touch these.
    options: Options = .{},

    pub const tsv: @This() = .{ .separator = '\t', .header = true };
    pub const csv: @This() = .{ .separator = ',', .header = true };
    pub const ssv: @This() = .{ .separator = ';', .header = true };
};

/// RFC 4180 compliance knobs. Every field has a sane default; you'll
/// almost never set these.
pub const Options = struct {
    /// Quote character used to delimit fields containing special
    /// characters (RFC 4180).
    quote: u8 = '"',

    /// When true, a row whose field count differs from the header (or from
    /// the first row, when headerless) is an error.
    strict_field_count: bool = false,

    /// When true, unquoted fields are whitespace-trimmed at scan time.
    /// Defaults to false: RFC space semantics, spaces are part of a field.
    trim_whitespace: bool = false,
};

/// A parsed table. Borrows all field data from the parser input, except
/// escaped-quote fields, which are allocated and tracked in `owned`.
pub const Table = struct {
    header: []const []const u8,
    rows: []const []const []const u8,
    owned: []const []const u8,
    /// Number of data rows (`rows.len`).
    n_rows: usize,
    /// Column count: header width, or first row's when headerless.
    /// Ragged rows (lenient mode) may deviate from this.
    n_cols: usize,

    // TODO: linear scan — hashmap if column lookups ever become a hot path.
    pub fn columnIndex(self: Table, name: []const u8) ?usize {
        for (self.header, 0..) |h, i| {
            if (std.mem.eql(u8, h, name)) return i;
        }
        return null;
    }

    pub fn getAs(self: Table, comptime T: type, row: usize, col: usize) error{ RowOutOfBounds, ColumnOutOfBounds, InvalidCharacter, Overflow }!T {
        if (row >= self.rows.len) return error.RowOutOfBounds;
        if (col >= self.rows[row].len) return error.ColumnOutOfBounds;
        return parseAs(T, self.rows[row][col]);
    }

    pub fn rowAs(self: Table, comptime T: type, row: usize, arena: Allocator) error{ RowOutOfBounds, OutOfMemory, InvalidCharacter, Overflow }![]T {
        if (row >= self.rows.len) return error.RowOutOfBounds;
        const fields = self.rows[row];
        const out = try arena.alloc(T, fields.len);
        errdefer arena.free(out);
        for (fields, 0..) |f, i| out[i] = try parseAs(T, f);
        return out;
    }

    /// Frees everything `parse` allocated: header, rows, and escaped-quote
    /// field copies. No-op in practice when parsed with an arena.
    pub fn deinit(self: Table, arena: Allocator) void {
        arena.free(self.header);
        for (self.rows) |r| arena.free(r);
        arena.free(self.rows);
        for (self.owned) |f| arena.free(f);
        arena.free(self.owned);
    }
};

/// Parses a single field as `T`: any float, any int (signed or
/// unsigned), or `[]const u8` (returns the field verbatim). Strings at
/// rest, types bind at the call site — no schema, no typed column
/// storage.
///
/// Does NOT trim. RFC space semantics: spaces are part of a field. Set
/// `Dialect.trim_whitespace` if your input pads fields.
pub fn parseAs(comptime T: type, field: []const u8) error{ InvalidCharacter, Overflow }!T {
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, field),
        .int => std.fmt.parseInt(T, field, 10),
        .pointer => |p| if (p.size == .slice and p.child == u8) field else @compileError("parseAs: only []const u8 pointer types"),
        else => @compileError("parseAs supports float, int, and []const u8"),
    };
}

const Allocator = std.mem.Allocator;

/// Parses `input` into a table. Fields borrow from `input`, so it must
/// outlive the returned table. All allocations use `arena` — free once
/// with `Table.deinit` or by deiniting the arena.
pub fn parse(arena: Allocator, input: []const u8, dialect: Dialect) error{ EmptyInput, OutOfMemory, UnterminatedQuote, InvalidFile, FieldCountMismatch }!Table {
    // Skip UTF-8 BOM.
    const data = if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) input[3..] else input;
    if (data.len == 0) return error.EmptyInput;

    // Escaped-quote field copies; freed on error below or by Table.deinit.
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |f| arena.free(f);
        if (owned.capacity > 0) owned.deinit(arena);
    }

    var pos: usize = 0;

    var header: []const []const u8 = &.{};
    var header_allocated = false;
    if (dialect.header) {
        header = try readRow(arena, &owned, data, &pos, dialect);
        header_allocated = true;
    }
    errdefer if (header_allocated) arena.free(header);

    var rows: std.ArrayList([]const []const u8) = .empty;
    errdefer {
        for (rows.items) |r| arena.free(r);
        if (rows.capacity > 0) rows.deinit(arena);
    }

    while (pos < data.len) {
        try rows.append(arena, try readRow(arena, &owned, data, &pos, dialect));
    }

    // Drop trailing empty rows: they're line-terminator artifacts, not
    // data rows (a lone `\n` after the last record).
    while (rows.items.len > 0) {
        const last = rows.items[rows.items.len - 1];
        if (last.len == 1 and last[0].len == 0) {
            _ = rows.pop();
            arena.free(last);
        } else break;
    }

    const width: usize = if (header.len > 0) header.len else if (rows.items.len > 0) rows.items[0].len else 0;
    if (dialect.options.strict_field_count) {
        for (rows.items) |row| {
            if (row.len != width) return error.FieldCountMismatch;
        }
    }

    const slice = try rows.toOwnedSlice(arena);
    return .{
        .header = header,
        .rows = slice,
        .owned = try owned.toOwnedSlice(arena),
        .n_rows = slice.len,
        .n_cols = width,
    };
}

/// Reads one row starting at `pos.*`, advancing past its terminator.
/// Handles CRLF, LF, and lone CR.
fn readRow(arena: Allocator, owned: *std.ArrayList([]const u8), data: []const u8, pos: *usize, dialect: Dialect) error{ OutOfMemory, UnterminatedQuote, InvalidFile }![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer if (fields.capacity > 0) fields.deinit(arena);

    while (true) {
        try fields.append(arena, try readField(arena, owned, data, pos, dialect));

        if (pos.* >= data.len) break; // EOF ends the row

        const c = data[pos.*];
        if (c == dialect.separator) {
            pos.* += 1;
            continue;
        }
        if (c == '\n' or c == '\r') {
            pos.* += 1;
            if (c == '\r' and pos.* < data.len and data[pos.*] == '\n') pos.* += 1;
            break;
        }
        // zarko: a field may only be followed by a separator or a line ending.
        return error.InvalidFile;
    }
    return fields.toOwnedSlice(arena);
}

/// Reads one field starting at `pos.*`, advancing to the separator, line
/// ending, or EOF. Quoted-field scanning adapted from zarko's
/// `parseField`/`parseQuotedField`.
fn readField(arena: Allocator, owned: *std.ArrayList([]const u8), data: []const u8, pos: *usize, dialect: Dialect) error{ OutOfMemory, UnterminatedQuote }![]const u8 {
    if (pos.* >= data.len) return "";

    if (data[pos.*] == dialect.options.quote) return readQuotedField(arena, owned, data, pos, dialect.options.quote);

    const start = pos.*;
    while (pos.* < data.len) {
        const c = data[pos.*];
        if (c == dialect.separator or c == '\n' or c == '\r') break;
        pos.* += 1;
    }
    const raw = data[start..pos.*];
    return if (dialect.options.trim_whitespace) std.mem.trim(u8, raw, " \t") else raw;
}

/// Reads a quoted field. Borrows from `data` when no escapes are present;
/// allocates an unescaped copy (tracked in `owned`) only when `""` pairs
/// are found. Adapted from zarko's `parseQuotedField`.
fn readQuotedField(arena: Allocator, owned: *std.ArrayList([]const u8), data: []const u8, pos: *usize, quote: u8) error{ OutOfMemory, UnterminatedQuote }![]const u8 {
    pos.* += 1; // opening quote
    const start = pos.*;
    var escaped = false;

    while (pos.* < data.len) {
        if (data[pos.*] == quote) {
            if (pos.* + 1 < data.len and data[pos.* + 1] == quote) {
                escaped = true;
                pos.* += 2;
                continue;
            }
            const end = pos.*;
            pos.* += 1; // closing quote
            const raw = data[start..end];
            if (!escaped) return raw;
            const s = try unescape(arena, raw, quote);
            errdefer arena.free(s);
            try owned.append(arena, s);
            return s;
        }
        pos.* += 1;
    }
    return error.UnterminatedQuote;
}

/// Replaces `""` with `"`.
fn unescape(arena: Allocator, raw: []const u8, quote: u8) error{OutOfMemory}![]const u8 {
    return std.mem.replaceOwned(u8, arena, raw, &[_]u8{ quote, quote }, &[_]u8{quote});
}

fn parseTest(input: []const u8, dialect: Dialect) !Table {
    return parse(std.testing.allocator, input, dialect);
}

test "basic tsv with header" {
    const t = try parseTest("name\tage\nAda\t36\nLinus\t56\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("name", t.header[0]);
    try std.testing.expectEqualStrings("age", t.header[1]);
    try std.testing.expectEqual(@as(usize, 2), t.rows.len);
    try std.testing.expectEqualStrings("Ada", t.rows[0][0]);
    try std.testing.expectEqualStrings("56", t.rows[1][1]);
}

test "column lookup" {
    const t = try parseTest("did\trate\nx\t1\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 1), t.columnIndex("rate"));
    try std.testing.expectEqual(@as(?usize, null), t.columnIndex("nope"));
}

test "no trailing newline" {
    const t = try parseTest("a\tb\n1\t2", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), t.rows.len);
    try std.testing.expectEqualStrings("2", t.rows[0][1]);
}

test "crlf line endings" {
    const t = try parseTest("a\tb\r\n1\t2\r\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("b", t.header[1]);
    try std.testing.expectEqualStrings("2", t.rows[0][1]);
}

test "utf-8 bom is skipped" {
    const t = try parseTest("\xEF\xBB\xBFa\tb\n1\t2\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a", t.header[0]);
}

test "empty fields are preserved" {
    const t = try parseTest("a\tb\tc\n\t2\t\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), t.rows[0].len);
    try std.testing.expectEqualStrings("", t.rows[0][0]);
    try std.testing.expectEqualStrings("2", t.rows[0][1]);
    try std.testing.expectEqualStrings("", t.rows[0][2]);
}

test "custom separator" {
    const t = try parseTest("a,b\n1,2\n", .csv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("2", t.rows[0][1]);
}

test "ssv idiom" {
    const t = try parseTest("a;b\n1;2\n", .ssv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("2", t.rows[0][1]);
}

test "headerless: every line is a data row" {
    const t = try parseTest("1\t2\n3\t4\n", .{ .separator = '\t', .header = false });
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), t.header.len);
    try std.testing.expectEqual(@as(usize, 2), t.rows.len);
    try std.testing.expectEqualStrings("1", t.rows[0][0]);
    try std.testing.expectEqual(@as(?usize, null), t.columnIndex("did"));
}

test "header only, no data rows" {
    const t = try parseTest("a\tb\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), t.header.len);
    try std.testing.expectEqual(@as(usize, 0), t.rows.len);
}

test "n_rows and n_cols" {
    const t = try parseTest("a\tb\n1\t2\n3\t4\n", .tsv);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), t.n_rows);
    try std.testing.expectEqual(@as(usize, 2), t.n_cols);

    // Headerless: first row gives the width.
    const h = try parseTest("1\t2\t3\n4\t5\t6\n", .{ .separator = '\t', .header = false });
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), h.n_rows);
    try std.testing.expectEqual(@as(usize, 3), h.n_cols);

    // Header only.
    const o = try parseTest("a\tb\n", .tsv);
    defer o.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), o.n_rows);
    try std.testing.expectEqual(@as(usize, 2), o.n_cols);
}

test "empty input is an error" {
    try std.testing.expectError(error.EmptyInput, parseTest("", .tsv));
}

test "blank line in the middle yields a one-field row" {
    // Default dialect is lenient: ragged rows pass through. Flip
    // `strict_field_count` for validation.
    const t = try parseTest("a\tb\n1\t2\n\n3\t4\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), t.rows.len);
    try std.testing.expectEqual(@as(usize, 1), t.rows[1].len);
}

test "getAs and rowAs error on out-of-bounds instead of panicking" {
    const t = try parseTest("a\tb\n1\t2\n3\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectError(error.RowOutOfBounds, t.getAs([]const u8, 9, 0));
    try std.testing.expectError(error.ColumnOutOfBounds, t.getAs([]const u8, 1, 1));
    try std.testing.expectError(error.RowOutOfBounds, t.rowAs([]const u8, 9, std.testing.allocator));
}

test "trailing blank lines are dropped" {
    const t1 = try parseTest("a\tb\n1\t2\n\n", .tsv);
    defer t1.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), t1.rows.len);

    const t2 = try parseTest("a\tb\n1\t2\n\n\n", .tsv);
    defer t2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), t2.rows.len);
}

test "rowAs frees its buffer when a field fails to parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a\tb\n1\tx\n", .tsv);

    var gpa = std.heap.DebugAllocator(.{}){};
    const out = t.rowAs(u32, 0, gpa.allocator());
    try std.testing.expectError(error.InvalidCharacter, out);
    try std.testing.expect(gpa.deinit() == .ok);
}

test "getAs parses floats and ints on demand" {
    const t = try parseTest("did\trate\tn\na\t0.5\t3\n", .tsv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try t.getAs(f32, 0, 1), 1e-7);
    try std.testing.expectEqual(@as(f64, 0.5), try t.getAs(f64, 0, 1)); // precision is the caller's choice
    try std.testing.expectEqual(@as(u32, 3), try t.getAs(u32, 0, 2));
    try std.testing.expectError(error.InvalidCharacter, t.getAs(f32, 0, 0)); // dids are not numbers
}

test "parseAs: strings pass through verbatim, unsigned ints work" {
    // RFC space semantics: spaces are part of a field, parseAs does not trim.
    try std.testing.expectEqualStrings(" did:plc:abc ", try parseAs([]const u8, " did:plc:abc "));
    try std.testing.expectEqual(@as(u8, 65), try parseAs(u8, "65")); // numeric, not 'A'
    try std.testing.expectEqual(@as(usize, 250_001), try parseAs(usize, "250001"));
}

test "quoted field can contain the separator" {
    const t = try parseTest("\"a,b\",c\n", .csv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a,b", t.header[0]);
    try std.testing.expectEqualStrings("c", t.header[1]);
}

test "quoted fields: separator, escaped quotes, embedded newline" {
    const input =
        \\name,msg
        \\"a,b","he said ""hi"""
        \\"x","line1
        \\line2"
    ;
    const t = try parseTest(input, .csv);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), t.rows.len);
    try std.testing.expectEqualStrings("a,b", t.rows[0][0]);
    try std.testing.expectEqualStrings("he said \"hi\"", t.rows[0][1]);
    try std.testing.expectEqualStrings("x", t.rows[1][0]);
    try std.testing.expectEqualStrings("line1\nline2", t.rows[1][1]);
}

test "unterminated quote is an error" {
    try std.testing.expectError(error.UnterminatedQuote, parseTest("a,b\n\"x,y\n", .csv));
}

test "garbage after a closing quote is an error" {
    try std.testing.expectError(error.InvalidFile, parseTest("a,b\n\"x\"y,2\n", .csv));
}

test "strict_field_count rejects ragged rows" {
    try std.testing.expectError(error.FieldCountMismatch, parseTest("a\tb\n1\t2\n3\n", .{ .separator = '\t', .header = true, .options = .{ .strict_field_count = true } }));

    // Default remains lenient.
    const t = try parseTest("a\tb\n1\t2\n3\n", .tsv);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), t.rows.len);
}

test "trim_whitespace trims unquoted fields at scan time" {
    const t = try parseTest(" name , age \n Alice , 36 \n", .{ .separator = ',', .header = true, .options = .{ .trim_whitespace = true } });
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("name", t.header[0]);
    try std.testing.expectEqualStrings("age", t.header[1]);
    try std.testing.expectEqualStrings("Alice", t.rows[0][0]);
    try std.testing.expectEqual(@as(u32, 36), try t.getAs(u32, 0, 1));
}

test "headerless one-row float file parses into a flat array" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dir = std.Io.Dir.cwd().openDir(io, "../des-ctic/bskysim/ecdfs/inter_creation_time", .{}) catch |err| switch (err) {
        error.FileNotFound => return, // dataset not checked out next to this package
        else => return err,
    };
    defer dir.close(io);

    // gaps: one tab-separated row of 250k samples. The generator leaves
    // a trailing separator (file ends "...\t"), which correctly parses as
    // an empty final field — trim it off for a clean numeric row.
    const raw = try dir.readFileAlloc(io, "gaps/within_ecdf__expon__lognorm.tsv", a, .unlimited);
    const input = std.mem.trimEnd(u8, raw, " \t\r\n");
    const t = try parse(a, input, .{ .separator = '\t', .header = false });
    try std.testing.expectEqual(@as(usize, 1), t.rows.len);

    const gaps = try t.rowAs(f32, 0, a);
    try std.testing.expect(gaps.len >= 250_000);
    try std.testing.expectEqual(@as(f32, 28.0), gaps[0]);
    try std.testing.expectEqual(@as(f32, 53.0), gaps[1]);
}

test "parse all bskysim ecdfs tsv files" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dir = std.Io.Dir.cwd().openDir(io, "../des-ctic/bskysim/ecdfs", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // dataset not checked out next to this package
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(a);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".tsv")) continue;

        // parameters/*/*.tsv have a `did ...` header; gaps/offsets are headerless.
        const has_header = std.mem.indexOf(u8, entry.path, "parameters") != null;
        const input = try entry.dir.readFileAlloc(io, entry.basename, a, .unlimited);
        const table = try parse(a, input, .{ .separator = '\t', .header = has_header });

        if (has_header) {
            try std.testing.expectEqualStrings("did", table.header[0]);
            for (table.rows, 0..) |row, i| {
                try std.testing.expect(std.mem.startsWith(u8, row[0], "did:"));
                _ = try table.getAs(f32, i, 1); // first param column parses
            }
        }
        try std.testing.expect(table.rows.len > 0);
        const width = if (has_header) table.header.len else table.rows[0].len;
        for (table.rows) |row| try std.testing.expectEqual(width, row.len);
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 63), count);
}

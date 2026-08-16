
# Tabular

Zero-copy TSV/SSV/CSV reader for Zig 0.16.0. Fields borrow from the input; only the outer slice-of-slices is allocated (plus copies of escaped-quote fields, the one case that can't borrow). Designed to be parsed with an `arena` and freed once, but leak-free under any allocator.

RFC 4180 compliant: quoted fields, `""` escapes, embedded newlines, CRLF/LF/CR line endings. Ragged-row validation and whitespace trimming are opt-in via dialect flags.

## Example

```zig
const tabular = @import("tabular");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const input = try dir.readFileAlloc(io, "params.tsv", arena.allocator(), .unlimited);
const t = try tabular.parse(arena.allocator(), input, .tsv); // TSV with header

const rate = t.columnIndex("rate").?;
for (t.rows, 0..) |row, i| {
    std.debug.print("{s}\t{d}\n", .{ row[0], try t.getAs(f32, i, rate) });
}
```

If the table has no header, specify both `header = false` and the separator,
then convert the row you want.

```zig
const t = try tabular.parse(arena.allocator(), input, .{ .separator = '\t', .header = false });
const samples = try t.rowAs(f32, 0, arena.allocator()); // []f32
```

## Dialect & Options

Dialect are the main way to tell the library which input are we expecting.

There are three predefined dialects ---they assume header=true--- called `.tsv` (`\t` ), `.csv` (`,`), `.ssv` (`;`), but any can be specified with the following option:


```zig
.{ .separator = '!', .header = false}
```

## Options

This default to the RFC4180 standard. the options are

```zig
.{
  .quote = '"',
  .strict_field_count = false,
  .trim_whitespace = false,
,} 
```
- Quote: which characters delimitate strings.
- strict field count: if a line with less columns than previously found is detected error out.
- trim_whitespace: strip padding (spaced/tabs) infront of and behind the field.

## Credits

- Quoted-field scanner: [zarko](https://github.com/TynK-M/zarko)
- BOM skip, `strict_field_count`, `trim_whitespace` as variables: [serde.zig](https://github.com/OrlovEvgeny/serde.zig)
- [zig_csv](https://github.com/matthewtolman/zig_csv) was surveyed and deliberately not copied (SWAR bitmask parser; overkill here).


## TODO:

1. Streaming API — `Io.Reader`-backed iterator with per-record buffers, reusing current functions. Zero-copy can't survive a stream, so this is a parallel API, not an overload of `parse`.

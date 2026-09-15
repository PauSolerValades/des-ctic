package tracebin

import (
	"encoding/binary"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, contents []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "trace.bin")
	if err := os.WriteFile(path, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

const actionHeader = "type:TraceAction,record_size:40,endian:little," +
	"name:time,offset:0,kind:f64," +
	"name:event_id,offset:8,kind:u64," +
	"name:gen_id,offset:16,kind:u64," +
	"name:user_id,offset:24,kind:u32," +
	"name:post_id,offset:28,kind:u32," +
	"name:parent_id,offset:32,kind:u32," +
	"name:type,offset:36,kind:u8,variants:ignore|like|repost\n"

func actionRecord(time float64, event, gen, user, post, parent uint32, kind ActionType) []byte {
	rec := make([]byte, 40)
	binary.LittleEndian.PutUint64(rec[0:], math.Float64bits(time))
	binary.LittleEndian.PutUint64(rec[8:], uint64(event))
	binary.LittleEndian.PutUint64(rec[16:], uint64(gen))
	binary.LittleEndian.PutUint32(rec[24:], user)
	binary.LittleEndian.PutUint32(rec[28:], post)
	binary.LittleEndian.PutUint32(rec[32:], parent)
	rec[36] = byte(kind)
	return rec
}

func TestParseHeader(t *testing.T) {
	h, err := ParseHeader([]byte(actionHeader))
	if err != nil {
		t.Fatal(err)
	}
	if h.Type != "TraceAction" || h.RecordSize != 40 || h.Endian != binary.LittleEndian {
		t.Fatalf("header = %+v", h)
	}
	if len(h.Fields) != 7 {
		t.Fatalf("fields = %d, want 7", len(h.Fields))
	}
	if got := h.Fields[6]; got.Name != "type" || got.Offset != 36 || got.Kind != "u8" ||
		len(got.Variants) != 3 || got.Variants[2] != "repost" {
		t.Fatalf("last field = %+v", got)
	}
}

func TestActionCodec(t *testing.T) {
	body := append([]byte{}, actionRecord(1.5, 10, 100, 2, 7, 3, ActionRepost)...)
	body = append(body, actionRecord(2.5, 11, 101, 4, 8, 5, ActionIgnore)...)

	c, err := OpenAction(write(t, append([]byte(actionHeader), body...)))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var got []Action
	if err := c.ForEach(func(a Action) error {
		got = append(got, a)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("records = %d, want 2", len(got))
	}
	want := Action{Time: 1.5, EventID: 10, GenID: 100, UserID: 2, PostID: 7, ParentID: 3, Type: ActionRepost}
	if got[0] != want {
		t.Fatalf("record 0 = %+v, want %+v", got[0], want)
	}
	if got[1].Type != ActionIgnore || got[1].Type.String() != "ignore" {
		t.Fatalf("record 1 type = %v", got[1].Type)
	}
}

// TraceSession is the case where the Zig compiler stores backlog before type,
// so a reader that trusted declaration order would read the wrong fields.
func TestSessionCodecHonoursOffsets(t *testing.T) {
	header := "type:TraceSession,record_size:40,endian:little," +
		"name:time,offset:0,kind:f64," +
		"name:event_id,offset:8,kind:u64," +
		"name:gen_id,offset:16,kind:u64," +
		"name:user_id,offset:24,kind:u32," +
		"name:type,offset:32,kind:u8,variants:start|end_boredom|end," +
		"name:backlog,offset:28,kind:u32\n"

	rec := make([]byte, 40)
	binary.LittleEndian.PutUint64(rec[0:], math.Float64bits(9.25))
	binary.LittleEndian.PutUint64(rec[8:], 77)
	binary.LittleEndian.PutUint64(rec[16:], 88)
	binary.LittleEndian.PutUint32(rec[24:], 42)
	binary.LittleEndian.PutUint32(rec[28:], 1234) // backlog
	rec[32] = byte(SessionEndBoredom)             // type

	c, err := OpenSession(write(t, append([]byte(header), rec...)))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	got, err := c.Next()
	if err != nil {
		t.Fatal(err)
	}
	want := Session{Time: 9.25, EventID: 77, GenID: 88, UserID: 42, Type: SessionEndBoredom, Backlog: 1234}
	if got != want {
		t.Fatalf("session = %+v, want %+v", got, want)
	}
	if _, err := c.Next(); err != io.EOF {
		t.Fatalf("second Next err = %v, want io.EOF", err)
	}
}

func TestVariantMismatchIsRejected(t *testing.T) {
	header := "type:TraceAction,record_size:40,endian:little," +
		"name:time,offset:0,kind:f64," +
		"name:event_id,offset:8,kind:u64," +
		"name:gen_id,offset:16,kind:u64," +
		"name:user_id,offset:24,kind:u32," +
		"name:post_id,offset:28,kind:u32," +
		"name:parent_id,offset:32,kind:u32," +
		"name:type,offset:36,kind:u8,variants:repost|like|ignore\n"

	if _, err := OpenAction(write(t, []byte(header))); err == nil {
		t.Fatal("expected variant mismatch error")
	}
}

func TestTruncatedRecord(t *testing.T) {
	body := actionRecord(1, 1, 1, 1, 1, 1, ActionLike)
	path := write(t, append([]byte(actionHeader), body[:len(body)-3]...))

	c, err := OpenAction(path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	if _, err := c.Next(); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("err = %v, want io.ErrUnexpectedEOF", err)
	}
}

func TestMissingFieldIsRejected(t *testing.T) {
	header := "type:TraceAction,record_size:8,endian:little,name:time,offset:0,kind:f64\n"
	if _, err := OpenAction(write(t, []byte(header))); err == nil {
		t.Fatal("expected missing field error")
	}
}

func TestFieldOverflowsRecord(t *testing.T) {
	header := "type:TraceAction,record_size:4,endian:little,name:time,offset:0,kind:f64\n"
	if _, err := Open(write(t, []byte(header))); err == nil {
		t.Fatal("expected overflow error")
	}
}

func TestEmptyTraceFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "0-action_trace.bin")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("err = %v, want empty-file error", err)
	}
}

func TestCompleteRun(t *testing.T) {
	prefix := filepath.Join(t.TempDir(), "0-")
	for _, suffix := range FileSuffixes {
		if err := os.WriteFile(prefix+suffix, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if !CompleteRun(prefix) {
		t.Fatal("expected run to be complete")
	}

	if err := os.WriteFile(prefix+FileSuffixes[2], nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if CompleteRun(prefix) {
		t.Fatal("zero-byte file should make the run incomplete")
	}

	if err := os.Remove(prefix + FileSuffixes[2]); err != nil {
		t.Fatal(err)
	}
	if CompleteRun(prefix) {
		t.Fatal("missing file should make the run incomplete")
	}
}

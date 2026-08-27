// bin-to-parquet: convert the simulation's fixed-size .bin traces into
// .parquet files with the same schema the jsonl had, so the duckdb dataset
// stage can read them (read_parquet) instead of the 3x-larger jsonl.
//
// Usage: bin-to-parquet -type <action|session|create|propagate|swap> -dir <traces_dir>
//
// Reads every `N-<name>_trace.bin` and writes `N-<name>_trace.parquet` next to it.
package main

import (
	"bufio"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"

	"github.com/parquet-go/parquet-go"
)

// --- binary record layouts (little-endian, matching bskysim/src/traces.zig) ---
// Action:   time f64, event_id u64, gen_id u64, user_id u32, post_id u32, parent_id u32, type u32  (40)
// Create/Propagate: time f64, event_id u64, gen_id u64, user_id u32, post_id u32                  (32)
// Session:  time f64, event_id u64, gen_id u64, user_id u32, [pad 4], type u32, backlog u32       (40)
// Swap:     time f64, user_id u32, reason u32                                                     (16)

// --- parquet row types (schema == what duckdb inferred from the jsonl) ---

type ActionRow struct {
	Time     float64 `parquet:"time"`
	EventID  int64   `parquet:"event_id"`
	GenID    int64   `parquet:"gen_id"`
	UserID   int32   `parquet:"user_id"`
	PostID   int32   `parquet:"post_id"`
	ParentID int32   `parquet:"parent_id"`
	Type     string  `parquet:"type"`
}

type CreateRow struct {
	Time    float64 `parquet:"time"`
	EventID int64   `parquet:"event_id"`
	GenID   int64   `parquet:"gen_id"`
	UserID  int32   `parquet:"user_id"`
	PostID  int32   `parquet:"post_id"`
}

type SessionRow struct {
	Time    float64 `parquet:"time"`
	EventID int64   `parquet:"event_id"`
	GenID   int64   `parquet:"gen_id"`
	UserID  int32   `parquet:"user_id"`
	Type    string  `parquet:"type"`
	Backlog int32   `parquet:"backlog"`
}

type SwapRow struct {
	Time   float64 `parquet:"time"`
	UserID int32   `parquet:"user_id"`
	Reason string  `parquet:"reason"`
}

var (
	actionNames  = [3]string{"ignore", "like", "repost"}
	sessionNames = [3]string{"start", "end_boredom", "end"}
	swapNames    = [3]string{"simulation_start", "session_start", "refresh"}
)

func parseAction(b []byte) ActionRow {
	return ActionRow{
		Time:     math.Float64frombits(binary.LittleEndian.Uint64(b[0:])),
		EventID:  int64(binary.LittleEndian.Uint64(b[8:])),
		GenID:    int64(binary.LittleEndian.Uint64(b[16:])),
		UserID:   int32(binary.LittleEndian.Uint32(b[24:])),
		PostID:   int32(binary.LittleEndian.Uint32(b[28:])),
		ParentID: int32(binary.LittleEndian.Uint32(b[32:])),
		Type:     actionNames[b[36]],
	}
}

func parseCreate(b []byte) CreateRow {
	return CreateRow{
		Time:    math.Float64frombits(binary.LittleEndian.Uint64(b[0:])),
		EventID: int64(binary.LittleEndian.Uint64(b[8:])),
		GenID:   int64(binary.LittleEndian.Uint64(b[16:])),
		UserID:  int32(binary.LittleEndian.Uint32(b[24:])),
		PostID:  int32(binary.LittleEndian.Uint32(b[28:])),
	}
}

func parseSession(b []byte) SessionRow {
	return SessionRow{
		Time:    math.Float64frombits(binary.LittleEndian.Uint64(b[0:])),
		EventID: int64(binary.LittleEndian.Uint64(b[8:])),
		GenID:   int64(binary.LittleEndian.Uint64(b[16:])),
		UserID:  int32(binary.LittleEndian.Uint32(b[24:])),
		Backlog: int32(binary.LittleEndian.Uint32(b[28:])),
		Type:    sessionNames[b[32]],
	}
}

func parseSwap(b []byte) SwapRow {
	return SwapRow{
		Time:   math.Float64frombits(binary.LittleEndian.Uint64(b[0:])),
		UserID: int32(binary.LittleEndian.Uint32(b[8:])),
		Reason: swapNames[b[12]],
	}
}

// convert streams a .bin file into a .parquet file, parsing `size`-byte records.
func convert[T any](in, out string, size int, parse func([]byte) T) error {
	f, err := os.Open(in)
	if err != nil {
		return err
	}
	defer f.Close()

	outFile, err := os.Create(out)
	if err != nil {
		return err
	}
	defer outFile.Close()

	w := parquet.NewGenericWriter[T](outFile)
	defer w.Close()

	reader := bufio.NewReaderSize(f, 16*1024*1024)
	buf := make([]byte, size*65536) // 64K records per chunk
	rows := make([]T, 0, 65536)

	for {
		n, err := io.ReadFull(reader, buf)
		count := n / size
		for i := 0; i < count; i++ {
			rows = append(rows, parse(buf[i*size:(i+1)*size]))
		}
		if len(rows) >= 65536 {
			if _, err := w.Write(rows); err != nil {
				return err
			}
			rows = rows[:0]
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			return err
		}
	}
	if len(rows) > 0 {
		if _, err := w.Write(rows); err != nil {
			return err
		}
	}
	return nil
}

type kind struct {
	binSuffix  string
	outSuffix  string
	size       int
	convertOne func(in, out string) error
}

func main() {
	typ := flag.String("type", "", "trace type: action|session|create|propagate|swap")
	dir := flag.String("dir", "", "traces directory")
	flag.Parse()

	if *typ == "" || *dir == "" {
		fmt.Fprintln(os.Stderr, "usage: bin-to-parquet -type <type> -dir <dir>")
		os.Exit(1)
	}

	kinds := map[string]kind{
		"action":    {"action_trace", "action_trace", 40, func(in, out string) error { return convert(in, out, 40, parseAction) }},
		"session":   {"session_trace", "session_trace", 40, func(in, out string) error { return convert(in, out, 40, parseSession) }},
		"create":    {"create_trace", "create_trace", 32, func(in, out string) error { return convert(in, out, 32, parseCreate) }},
		"propagate": {"propagation_trace", "propagate_trace", 32, func(in, out string) error { return convert(in, out, 32, parseCreate) }},
		"swap":      {"swap_trace", "swap_trace", 16, func(in, out string) error { return convert(in, out, 16, parseSwap) }},
	}

	k, ok := kinds[*typ]
	if !ok {
		fmt.Fprintf(os.Stderr, "unknown type %q\n", *typ)
		os.Exit(1)
	}

	pattern := filepath.Join(*dir, "*-"+k.binSuffix+".bin")
	files, err := filepath.Glob(pattern)
	if err != nil || len(files) == 0 {
		fmt.Fprintf(os.Stderr, "no files match %s\n", pattern)
		os.Exit(1)
	}

	for _, in := range files {
		base := strings.TrimSuffix(filepath.Base(in), "-"+k.binSuffix+".bin")
		out := filepath.Join(*dir, base+"-"+k.outSuffix+".parquet")
		if err := k.convertOne(in, out); err != nil {
			fmt.Fprintf(os.Stderr, "convert %s: %v\n", in, err)
			os.Exit(1)
		}
		fmt.Printf("%s -> %s\n", in, out)
	}
}

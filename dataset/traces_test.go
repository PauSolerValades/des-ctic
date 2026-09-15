package main

import (
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/parquet-go/parquet-go"

	"github.com/PauSolerValades/des-ctic/dataset-creation/tracebin"
)

// TestConvertTraces converts a real bskysim trace directory and checks the
// parquet row counts match the bins. Opt-in:
//
//	TRACEBIN_DIR=/abs/traces go test . -run TestConvertTraces -v
func TestConvertTraces(t *testing.T) {
	dir := os.Getenv("TRACEBIN_DIR")
	if dir == "" {
		t.Skip("set TRACEBIN_DIR to a bskysim trace directory")
	}

	out := t.TempDir()
	if err := convertTraces(dir, out, kindSet("action", "session", "swap", "propagation")); err != nil {
		t.Fatal(err)
	}

	actions := readParquet[actionRow](t, filepath.Join(out, "action.parquet"))
	sessions := readParquet[sessionRow](t, filepath.Join(out, "session.parquet"))
	swaps := readParquet[swapRow](t, filepath.Join(out, "swap.parquet"))
	props := readParquet[propagationRow](t, filepath.Join(out, "propagation.parquet"))

	if want := countBin(t, dir, "action_trace.bin", tracebin.OpenAction); len(actions) != want {
		t.Fatalf("action rows = %d, want %d", len(actions), want)
	}
	if want := countBin(t, dir, "session_trace.bin", tracebin.OpenSession); len(sessions) != want {
		t.Fatalf("session rows = %d, want %d", len(sessions), want)
	}
	if want := countBin(t, dir, "swap_trace.bin", tracebin.OpenSwap); len(swaps) != want {
		t.Fatalf("swap rows = %d, want %d", len(swaps), want)
	}
	if want := countBin(t, dir, "propagation_trace.bin", tracebin.OpenPropagation); len(props) != want {
		t.Fatalf("propagation rows = %d, want %d", len(props), want)
	}

	actionTypes := map[string]int{}
	for _, a := range actions {
		actionTypes[a.Type]++
		if a.RunID != actions[0].RunID {
			t.Fatalf("mixed run ids: %d vs %d", a.RunID, actions[0].RunID)
		}
	}
	for _, want := range []string{"ignore", "like", "repost"} {
		if actionTypes[want] == 0 {
			t.Fatalf("no %q actions in parquet (got %v)", want, actionTypes)
		}
	}

	sessionTypes := map[string]int{}
	for _, s := range sessions {
		sessionTypes[s.Type]++
	}
	if sessionTypes["start"] == 0 || sessionTypes["end"] == 0 || sessionTypes["end_boredom"] == 0 {
		t.Fatalf("session types lost in conversion: %v", sessionTypes)
	}

	t.Logf("action=%d (types %v) session=%d (types %v) swap=%d propagation=%d",
		len(actions), actionTypes, len(sessions), sessionTypes, len(swaps), len(props))
}

func readParquet[R any](t *testing.T, path string) []R {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	r := parquet.NewGenericReader[R](f)
	defer r.Close()

	var out []R
	buf := make([]R, 4096)
	for {
		n, err := r.Read(buf)
		out = append(out, buf[:n]...)
		if err == io.EOF {
			return out
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}

func countBin[T any](t *testing.T, dir, suffix string, open func(string) (*tracebin.Codec[T], error)) int {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(dir, "*-"+suffix))
	total := 0
	for _, path := range files {
		c, err := open(path)
		if err != nil {
			t.Fatal(err)
		}
		err = c.ForEach(func(T) error { total++; return nil })
		c.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
	return total
}

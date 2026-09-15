package tracebin

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestReadRealTraceDir reads actual bskysim output. It is opt-in because it
// needs a directory produced by a simulation run:
//
//	TRACEBIN_DIR=steps/foo go test ./tracebin/ -run TestReadRealTraceDir -v
func TestReadRealTraceDir(t *testing.T) {
	dir := os.Getenv("TRACEBIN_DIR")
	if dir == "" {
		t.Skip("set TRACEBIN_DIR to a bskysim trace directory")
	}

	actionFiles, _ := filepath.Glob(filepath.Join(dir, "*-action_trace.bin"))
	if len(actionFiles) == 0 {
		t.Fatalf("no *-action_trace.bin under %s", dir)
	}

	for _, actionPath := range actionFiles {
		prefix := strings.TrimSuffix(filepath.Base(actionPath), "action_trace.bin")
		if !CompleteRun(strings.TrimSuffix(actionPath, "action_trace.bin")) {
			t.Logf("skipping incomplete run %s", prefix)
			continue
		}

		var lastAction float64
		nAction := readAll(t, prefix+"action_trace.bin", OpenAction, dir, prefix,
			func(a Action) error {
				if a.Type > ActionRepost {
					return fmt.Errorf("bad action type %d", a.Type)
				}
				if a.Time < lastAction {
					return fmt.Errorf("time went backwards: %v -> %v", lastAction, a.Time)
				}
				lastAction = a.Time
				return nil
			})

		var lastSession float64
		nSession := readAll(t, prefix+"session_trace.bin", OpenSession, dir, prefix,
			func(s Session) error {
				if s.Type > SessionEnd {
					return fmt.Errorf("bad session type %d", s.Type)
				}
				if s.Time < lastSession {
					return fmt.Errorf("time went backwards: %v -> %v", lastSession, s.Time)
				}
				lastSession = s.Time
				return nil
			})

		var lastCreate float64
		nCreate := readAll(t, prefix+"create_trace.bin", OpenCreate, dir, prefix,
			func(c Create) error {
				if c.Time < lastCreate {
					return fmt.Errorf("time went backwards: %v -> %v", lastCreate, c.Time)
				}
				lastCreate = c.Time
				return nil
			})

		var lastProp float64
		nProp := readAll(t, prefix+"propagation_trace.bin", OpenPropagation, dir, prefix,
			func(p Propagation) error {
				if p.Time < lastProp {
					return fmt.Errorf("time went backwards: %v -> %v", lastProp, p.Time)
				}
				lastProp = p.Time
				return nil
			})

		var lastSwap float64
		nSwap := readAll(t, prefix+"swap_trace.bin", OpenSwap, dir, prefix,
			func(s Swap) error {
				if s.Reason > SwapRefresh {
					return fmt.Errorf("bad swap reason %d", s.Reason)
				}
				if s.Time < lastSwap {
					return fmt.Errorf("time went backwards: %v -> %v", lastSwap, s.Time)
				}
				lastSwap = s.Time
				return nil
			})

		t.Logf("%s: action=%d session=%d create=%d propagation=%d swap=%d",
			prefix, nAction, nSession, nCreate, nProp, nSwap)
	}
}

// readAll streams every record through open, applies check, and verifies the
// count matches the file size minus the header.
func readAll[T any](t *testing.T, name string, open func(string) (*Codec[T], error), dir, prefix string, check func(T) error) int {
	t.Helper()
	path := filepath.Join(dir, name)

	c, err := open(path)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	defer c.Close()

	n := 0
	err = c.ForEach(func(v T) error {
		if check != nil {
			if err := check(v); err != nil {
				return fmt.Errorf("record %d: %w", n, err)
			}
		}
		n++
		return nil
	})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}

	headerLen, size := headerAndSize(t, path)
	body := size - int64(headerLen)
	if body%int64(c.Header().RecordSize) != 0 {
		t.Fatalf("%s: body %d is not a multiple of record_size %d", name, body, c.Header().RecordSize)
	}
	if want := int(body / int64(c.Header().RecordSize)); want != n {
		t.Fatalf("%s: read %d records, file size implies %d", name, n, want)
	}
	return n
}

func headerAndSize(t *testing.T, path string) (int, int64) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadBytes('\n')
	if err != nil {
		t.Fatal(err)
	}
	st, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	return len(line), st.Size()
}

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/parquet-go/parquet-go"

	"github.com/PauSolerValades/des-ctic/dataset-creation/tracebin"
)

// This file turns the bskysim .bin traces into parquet so DuckDB never has to
// read the (large, slow) jsonl files.

type traceKind struct {
	stem   string // parquet stem, e.g. "action"
	suffix string // bin filename suffix after "<run>-"
}

var allTraceKinds = []traceKind{
	{"action", "action_trace.bin"},
	{"session", "session_trace.bin"},
	{"swap", "swap_trace.bin"},
	{"propagation", "propagation_trace.bin"},
}

type runFile struct {
	runID  uint32
	prefix string // e.g. "/traces/0-"
}

// neededTraceKinds returns the trace kinds a dataset actually reads.
func neededTraceKinds(dataset string) map[string]bool {
	switch dataset {
	case "run-metrics":
		return kindSet("action", "session", "swap")
	case "post-metrics":
		return kindSet("action")
	case "sessions":
		return kindSet("action", "session")
	case "users":
		return kindSet("action", "session", "swap")
	case "raw-post-lifetime", "post-lifetime":
		return kindSet("action", "propagation")
	case "all":
		return kindSet("action", "session", "swap", "propagation")
	default: // "cascades" does not read traces
		return nil
	}
}

func kindSet(names ...string) map[string]bool {
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

// convertTraces writes one parquet per needed trace kind into outDir.
func convertTraces(tracesDir, outDir string, needed map[string]bool) error {
	runs, err := discoverRuns(tracesDir)
	if err != nil {
		return err
	}
	runs, skipped := keepCompleteRuns(runs)
	if len(skipped) > 0 {
		fmt.Fprintf(os.Stderr, "warning: skipping %d incomplete run(s): %v\n", len(skipped), skipped)
	}
	if len(runs) == 0 {
		return fmt.Errorf("no complete runs in %s", tracesDir)
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	for _, kind := range allTraceKinds {
		if !needed[kind.stem] {
			continue
		}
		out := filepath.Join(outDir, kind.stem+".parquet")
		if err := convertKind(kind, runs, out); err != nil {
			return fmt.Errorf("convert %s: %w", kind.stem, err)
		}
	}
	return nil
}

// keepCompleteRuns drops runs missing any of the five trace files, which are
// typically left behind by an interrupted simulation.
func keepCompleteRuns(runs []runFile) (kept []runFile, skipped []uint32) {
	for _, run := range runs {
		if tracebin.CompleteRun(run.prefix) {
			kept = append(kept, run)
		} else {
			skipped = append(skipped, run.runID)
		}
	}
	return kept, skipped
}

func discoverRuns(dir string) ([]runFile, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*-action_trace.bin"))
	if err != nil {
		return nil, err
	}
	runs := make([]runFile, 0, len(matches))
	for _, path := range matches {
		base := filepath.Base(path)
		dash := strings.IndexByte(base, '-')
		if dash <= 0 {
			continue
		}
		id, err := strconv.ParseUint(base[:dash], 10, 32)
		if err != nil {
			continue
		}
		runs = append(runs, runFile{runID: uint32(id), prefix: strings.TrimSuffix(path, "action_trace.bin")})
	}
	return runs, nil
}

func convertKind(kind traceKind, runs []runFile, outPath string) error {
	switch kind.stem {
	case "action":
		return streamTrace(runs, kind, outPath, tracebin.OpenAction,
			func(runID uint32, a tracebin.Action) actionRow {
				return actionRow{
					RunID: runID, Time: a.Time, EventID: a.EventID, GenID: a.GenID,
					UserID: a.UserID, PostID: a.PostID, ParentID: a.ParentID, Type: a.Type.String(),
				}
			})
	case "session":
		return streamTrace(runs, kind, outPath, tracebin.OpenSession,
			func(runID uint32, s tracebin.Session) sessionRow {
				return sessionRow{
					RunID: runID, Time: s.Time, EventID: s.EventID, GenID: s.GenID,
					UserID: s.UserID, Type: s.Type.String(), Backlog: s.Backlog,
				}
			})
	case "swap":
		return streamTrace(runs, kind, outPath, tracebin.OpenSwap,
			func(runID uint32, s tracebin.Swap) swapRow {
				return swapRow{RunID: runID, Time: s.Time, UserID: s.UserID, Reason: s.Reason.String()}
			})
	case "propagation":
		return streamTrace(runs, kind, outPath, tracebin.OpenPropagation,
			func(runID uint32, p tracebin.Propagation) propagationRow {
				return propagationRow{
					RunID: runID, Time: p.Time, EventID: p.EventID, GenID: p.GenID,
					UserID: p.UserID, PostID: p.PostID,
				}
			})
	}
	return fmt.Errorf("unknown trace kind %q", kind.stem)
}

// streamTrace reads every run's bin for one kind and writes one parquet.
func streamTrace[T any, R any](
	runs []runFile,
	kind traceKind,
	outPath string,
	open func(string) (*tracebin.Codec[T], error),
	mapRow func(uint32, T) R,
) error {
	f, err := os.Create(outPath)
	if err != nil {
		return err
	}
	w := parquet.NewGenericWriter[R](f)

	const batch = 8192
	rows := make([]R, 0, batch)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		if _, err := w.Write(rows); err != nil {
			return err
		}
		rows = rows[:0]
		return nil
	}

	for _, run := range runs {
		c, err := open(run.prefix + kind.suffix)
		if err != nil {
			f.Close()
			return err
		}
		err = c.ForEach(func(v T) error {
			rows = append(rows, mapRow(run.runID, v))
			if len(rows) >= batch {
				return flush()
			}
			return nil
		})
		c.Close()
		if err != nil {
			f.Close()
			return err
		}
	}

	if err := flush(); err != nil {
		f.Close()
		return err
	}
	if err := w.Close(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// Row types. Tags pin the duckdb column names; the session "end_boredom" is
// kept verbatim so the queries can distinguish it.

type actionRow struct {
	RunID    uint32  `parquet:"run_id"`
	Time     float64 `parquet:"time"`
	EventID  uint64  `parquet:"event_id"`
	GenID    uint64  `parquet:"gen_id"`
	UserID   uint32  `parquet:"user_id"`
	PostID   uint32  `parquet:"post_id"`
	ParentID uint32  `parquet:"parent_id"`
	Type     string  `parquet:"type"`
}

type sessionRow struct {
	RunID   uint32  `parquet:"run_id"`
	Time    float64 `parquet:"time"`
	EventID uint64  `parquet:"event_id"`
	GenID   uint64  `parquet:"gen_id"`
	UserID  uint32  `parquet:"user_id"`
	Type    string  `parquet:"type"`
	Backlog uint32  `parquet:"backlog"`
}

type swapRow struct {
	RunID  uint32  `parquet:"run_id"`
	Time   float64 `parquet:"time"`
	UserID uint32  `parquet:"user_id"`
	Reason string  `parquet:"reason"`
}

type propagationRow struct {
	RunID   uint32  `parquet:"run_id"`
	Time    float64 `parquet:"time"`
	EventID uint64  `parquet:"event_id"`
	GenID   uint64  `parquet:"gen_id"`
	UserID  uint32  `parquet:"user_id"`
	PostID  uint32  `parquet:"post_id"`
}

package main

import (
	"bytes"
	"embed"
	"encoding/csv"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"text/template"

	"github.com/PauSolerValades/des-ctic/dataset-creation/cascade"
)

//go:embed queries/*.sql.tmpl
var queryTemplates embed.FS

type TemplateData struct {
	CascadesSSV string
	LikesSSV    string
	TracesDir   string
	OutputDir   string
}

func main() {
	outputDir := flag.String("output", "data", "Output directory for parquet files")
	flag.Parse()

	args := flag.Args()
	if len(args) < 4 {
		printUsage()
		os.Exit(1)
	}

	cascadesSSV := args[0]
	likesSSV := args[1]
	tracesDir := args[2]
	dataset := args[3]

	if err := os.MkdirAll(*outputDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "cannot create output dir: %v\n", err)
		os.Exit(1)
	}

	data := TemplateData{
		CascadesSSV: cascadesSSV,
		LikesSSV:    likesSSV,
		TracesDir:   tracesDir,
		OutputDir:   *outputDir,
	}

	switch dataset {
	case "run-metrics":
		runSQL("queries/run_metrics.sql.tmpl", data)

	case "post-metrics":
		runSQL("queries/post_metrics.sql.tmpl", data)

	case "sessions":
		runSQL("queries/sessions.sql.tmpl", data)

	case "users":
		runSQL("queries/users.sql.tmpl", data)

	case "raw-post-lifetime":
		runSQL("queries/raw_post_lifetime.sql.tmpl", data)

	case "post-lifetime":
		runSQL("queries/post_lifetime.sql.tmpl", data)

	case "cascades":
		runCascades(cascadesSSV, *outputDir)

	case "all":
		runSQL("queries/run_metrics.sql.tmpl", data)
		runSQL("queries/post_metrics.sql.tmpl", data)
		runSQL("queries/sessions.sql.tmpl", data)
		runSQL("queries/users.sql.tmpl", data)
		runSQL("queries/raw_post_lifetime.sql.tmpl", data)
		runSQL("queries/post_lifetime.sql.tmpl", data)
		runCascades(cascadesSSV, *outputDir)

	default:
		fmt.Fprintf(os.Stderr, "Unknown dataset: %s\n", dataset)
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "Usage: dataset-creation [-output dir] <cascades.ssv> <likes.ssv> <traces-dir> <dataset>")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Datasets:")
	fmt.Fprintln(os.Stderr, "  run-metrics        Global per-run metrics")
	fmt.Fprintln(os.Stderr, "  post-metrics       Per-post metrics (reposts, likes, conversion)")
	fmt.Fprintln(os.Stderr, "  sessions           Per-session start/end/duration")
	fmt.Fprintln(os.Stderr, "  users              Per-user session and action aggregates")
	fmt.Fprintln(os.Stderr, "  raw-post-lifetime  Per-repost events with gaps (feeds post-lifetime)")
	fmt.Fprintln(os.Stderr, "  post-lifetime      Per-post T_50, T_95, T_99, time_to_peak")
	fmt.Fprintln(os.Stderr, "  cascades           Cascade tree metrics (depth, virality, broadcast, paths)")
	fmt.Fprintln(os.Stderr, "  all                Generate all datasets")
}

func runSQL(tmplName string, data TemplateData) {
	tmpl, err := template.ParseFS(queryTemplates, tmplName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "template parse error: %v\n", err)
		os.Exit(1)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		fmt.Fprintf(os.Stderr, "template execute error: %v\n", err)
		os.Exit(1)
	}

	tmp, err := os.CreateTemp("", "dataset-creation-*.sql")
	if err != nil {
		fmt.Fprintf(os.Stderr, "temp file error: %v\n", err)
		os.Exit(1)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(buf.Bytes()); err != nil {
		fmt.Fprintf(os.Stderr, "temp file write error: %v\n", err)
		os.Exit(1)
	}
	tmp.Close()

	cmd := exec.Command("duckdb", "-f", tmp.Name())
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "duckdb failed: %v\n", err)
		os.Exit(1)
	}
}

func runCascades(cascadesSSV, outputDir string) {
	// reads the _whole_ file, if too big we can do chunks reading (just some cascades in memroy)
	roots, reposts, err := readSSV(cascadesSSV)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read SSV: %v\n", err)
		os.Exit(1)
	}

	rootsByKey := make(map[cascade.Key]cascade.Root, len(roots))
	for _, r := range roots {
		rootsByKey[cascade.Key{RunID: r.RunID, PostID: r.PostID}] = r
	}
	repostsByKey := make(map[cascade.Key][]cascade.Repost)
	for _, r := range reposts {
		key := cascade.Key{RunID: r.RunID, PostID: r.PostID}
		repostsByKey[key] = append(repostsByKey[key], r)
	}

	cw, err := newCascadeWriter(outputDir + "/cascades.parquet")
	if err != nil {
		fmt.Fprintf(os.Stderr, "open cascades writer: %v\n", err)
		os.Exit(1)
	}
	bw, err := newBroadcastWriter(outputDir + "/broadcast_groups.parquet")
	if err != nil {
		fmt.Fprintf(os.Stderr, "open broadcast writer: %v\n", err)
		os.Exit(1)
	}
	pw, err := newPathWriter(outputDir + "/root_to_leaf.parquet")
	if err != nil {
		fmt.Fprintf(os.Stderr, "open paths writer: %v\n", err)
		os.Exit(1)
	}
	defer cw.close()
	defer bw.close()
	defer pw.close()

	count := 0
	for key, root := range rootsByKey {
		c := cascade.Init(key, root, repostsByKey[key])

		cw.write([]CascadeRow{{
			RunID:              c.Key.RunID,
			PostID:             c.Key.PostID,
			AuthorID:           c.AuthorID(),
			CreationTime:       c.CreationTime(),
			CascadeDepth:       c.Depth(),
			CascadeSize:        c.Size(),
			MaxOutDegree:       c.MaxOutDegree(),
			StructuralVirality: c.StructuralVirality(),
		}})

		for _, g := range c.BroadcastGroups() {
			bw.write([]BroadcastRow{toBroadcastRow(g)})
		}
		for _, p := range c.RootToLeafPaths() {
			pw.write([]PathRow{toPathRow(p)})
		}
		count++
	}

	fmt.Printf("Cascades: %d trees built\n", count)
}

func readSSV(path string) ([]cascade.Root, []cascade.Repost, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.Comma = '\t'
	r.FieldsPerRecord = 6
	r.ReuseRecord = true

	header, err := r.Read()
	if err != nil {
		return nil, nil, fmt.Errorf("read header: %w", err)
	}
	_ = header

	var roots []cascade.Root
	var reposts []cascade.Repost

	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, nil, err
		}

		runID, _ := strconv.ParseUint(rec[0], 10, 32)
		postID, _ := strconv.ParseUint(rec[1], 10, 32)
		userID, _ := strconv.ParseUint(rec[2], 10, 32)
		parentID, _ := strconv.ParseUint(rec[3], 10, 32)
		typ := rec[4]
		t, _ := strconv.ParseFloat(rec[5], 64)

		switch typ {
		case "creation":
			roots = append(roots, cascade.Root{uint32(runID), uint32(postID), uint32(userID), t})
		case "repost":
			reposts = append(reposts, cascade.Repost{uint32(runID), uint32(postID), uint32(userID), uint32(parentID), t})
		}
	}
	return roots, reposts, nil
}

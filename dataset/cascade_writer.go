package main

import (
	"os"

	"github.com/parquet-go/parquet-go"

	"github.com/PauSolerValades/des-ctic/dataset-creation/cascade"
)

// ----- Row types for parquet files -----

// CascadeRow is one row in cascades.parquet.
type CascadeRow struct {
	RunID              uint32
	PostID             uint32
	AuthorID           uint32
	CreationTime       float64
	CascadeDepth       int
	CascadeSize        int
	MaxOutDegree       int
	StructuralVirality float64
}

// BroadcastRow is one row in broadcast_groups.parquet.
type BroadcastRow struct {
	RunID          uint32
	PostID         uint32
	ParentID       uint32
	BroadcastSize  int
	MeanGap        float64
	MedianGap      float64
	GapTrend       float64
	FirstChildTime float64
	LastChildTime  float64
}

// PathRow is one row in root_to_leaf.parquet.
type PathRow struct {
	RunID          uint32
	PostID         uint32
	LeafUserID     uint32
	PathDepth      int
	PathTotalTime  float64
	TraversalSpeed float64
	GapTrend       float64
}

// ----- Writers -----

type cascadeWriter struct {
	w *parquet.GenericWriter[CascadeRow]
	f *os.File
}

func newCascadeWriter(path string) (*cascadeWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &cascadeWriter{w: parquet.NewGenericWriter[CascadeRow](f), f: f}, nil
}

func (w *cascadeWriter) write(rows []CascadeRow) error {
	_, err := w.w.Write(rows)
	return err
}

func (w *cascadeWriter) close() error {
	if err := w.w.Close(); err != nil {
		return err
	}
	return w.f.Close()
}

type broadcastWriter struct {
	w *parquet.GenericWriter[BroadcastRow]
	f *os.File
}

func newBroadcastWriter(path string) (*broadcastWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &broadcastWriter{w: parquet.NewGenericWriter[BroadcastRow](f), f: f}, nil
}

func (w *broadcastWriter) write(rows []BroadcastRow) error {
	_, err := w.w.Write(rows)
	return err
}

func (w *broadcastWriter) close() error {
	if err := w.w.Close(); err != nil {
		return err
	}
	return w.f.Close()
}

type pathWriter struct {
	w *parquet.GenericWriter[PathRow]
	f *os.File
}

func newPathWriter(path string) (*pathWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &pathWriter{w: parquet.NewGenericWriter[PathRow](f), f: f}, nil
}

func (w *pathWriter) write(rows []PathRow) error {
	_, err := w.w.Write(rows)
	return err
}

func (w *pathWriter) close() error {
	if err := w.w.Close(); err != nil {
		return err
	}
	return w.f.Close()
}

// ----- Conversion helpers -----

func toBroadcastRow(g cascade.BroadcastGroup) BroadcastRow {
	return BroadcastRow{
		RunID:          g.RunID,
		PostID:         g.PostID,
		ParentID:       g.ParentID,
		BroadcastSize:  g.BroadcastSize,
		MeanGap:        g.MeanGap,
		MedianGap:      g.MedianGap,
		GapTrend:       g.GapTrend,
		FirstChildTime: g.FirstChildTime,
		LastChildTime:  g.LastChildTime,
	}
}

func toPathRow(p cascade.RootToLeafPath) PathRow {
	return PathRow{
		RunID:          p.RunID,
		PostID:         p.PostID,
		LeafUserID:     p.LeafUserID,
		PathDepth:      p.PathDepth,
		PathTotalTime:  p.PathTotalTime,
		TraversalSpeed: p.TraversalSpeed,
		GapTrend:       p.GapTrend,
	}
}

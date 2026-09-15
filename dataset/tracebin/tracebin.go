// Package tracebin reads the self-describing .bin trace files written by
// bskysim.
//
// Each file starts with one text header line terminated by '\n':
//
//	type:<name>,record_size:<n>,endian:little,
//	name:<field>,offset:<byte>,kind:<tag>[,variants:<v0>|<v1>|...],...
//
// followed by fixed-size records. Field offsets come from the header, so the
// reader is immune to the Zig compiler reordering or padding struct fields.
//
// Files are independent of one another: a caller may read one file per run
// concurrently without any coordination.
package tracebin

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
)

// Header is the parsed description of a trace file.
type Header struct {
	Type       string
	RecordSize int
	Endian     binary.ByteOrder
	Fields     []Field
}

// Field describes one record field.
type Field struct {
	Name     string
	Offset   int
	Kind     string
	Variants []string // only for enums
}

// ParseHeader parses a single header line (the trailing '\n' is optional).
func ParseHeader(line []byte) (*Header, error) {
	h := &Header{Endian: binary.LittleEndian}
	for _, tok := range strings.Split(strings.TrimRight(string(line), "\r\n"), ",") {
		key, value, ok := strings.Cut(tok, ":")
		if !ok {
			return nil, fmt.Errorf("tracebin: malformed header token %q", tok)
		}
		switch key {
		case "type":
			h.Type = value
		case "record_size":
			n, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("tracebin: bad record_size %q", value)
			}
			h.RecordSize = n
		case "endian":
			switch value {
			case "little":
				h.Endian = binary.LittleEndian
			case "big":
				h.Endian = binary.BigEndian
			default:
				return nil, fmt.Errorf("tracebin: unknown endian %q", value)
			}
		case "name":
			h.Fields = append(h.Fields, Field{Name: value})
		case "offset":
			f, err := h.lastField(key)
			if err != nil {
				return nil, err
			}
			n, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("tracebin: bad offset %q", value)
			}
			f.Offset = n
		case "kind":
			f, err := h.lastField(key)
			if err != nil {
				return nil, err
			}
			f.Kind = value
		case "variants":
			f, err := h.lastField(key)
			if err != nil {
				return nil, err
			}
			f.Variants = strings.Split(value, "|")
		}
	}
	if h.Type == "" || h.RecordSize <= 0 || len(h.Fields) == 0 {
		return nil, fmt.Errorf("tracebin: incomplete header %q", strings.TrimSpace(string(line)))
	}
	return h, nil
}

func (h *Header) lastField(key string) (*Field, error) {
	if len(h.Fields) == 0 {
		return nil, fmt.Errorf("tracebin: header key %q before any field", key)
	}
	return &h.Fields[len(h.Fields)-1], nil
}

func (h *Header) field(name string) (*Field, error) {
	for i := range h.Fields {
		if h.Fields[i].Name == name {
			return &h.Fields[i], nil
		}
	}
	return nil, fmt.Errorf("tracebin %s: missing field %q", h.Type, name)
}

// at resolves a scalar field offset, checking the recorded kind.
func (h *Header) at(name, kind string) (int, error) {
	f, err := h.field(name)
	if err != nil {
		return 0, err
	}
	if f.Kind != kind {
		return 0, fmt.Errorf("tracebin %s: field %q has kind %q, want %q", h.Type, name, f.Kind, kind)
	}
	return f.Offset, nil
}

// enumAt resolves an enum field offset. The variant names are validated when
// present so a Zig-side enum reorder cannot silently mislabel values.
func (h *Header) enumAt(name string, variants []string) (int, error) {
	f, err := h.field(name)
	if err != nil {
		return 0, err
	}
	if f.Kind != "u8" {
		return 0, fmt.Errorf("tracebin %s: enum field %q has kind %q, want u8", h.Type, name, f.Kind)
	}
	if len(f.Variants) > 0 && !slices.Equal(f.Variants, variants) {
		return 0, fmt.Errorf("tracebin %s: field %q has variants %v, want %v", h.Type, name, f.Variants, variants)
	}
	return f.Offset, nil
}

func kindSize(kind string) (int, error) {
	switch kind {
	case "f64", "u64", "i64":
		return 8, nil
	case "f32", "u32", "i32":
		return 4, nil
	case "f16", "u16", "i16":
		return 2, nil
	case "u8", "i8", "bool":
		return 1, nil
	}
	return 0, fmt.Errorf("tracebin: unknown kind %q", kind)
}

// Reader streams the raw records of a single trace file.
type Reader struct {
	f   *os.File
	br  *bufio.Reader
	h   *Header
	buf []byte
}

// Open parses the header of a trace file and prepares to stream its records.
func Open(path string) (*Reader, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	br := bufio.NewReaderSize(f, 1<<16)
	line, err := br.ReadBytes('\n')
	if err != nil && err != io.EOF {
		f.Close()
		return nil, err
	}
	if len(line) == 0 {
		f.Close()
		return nil, fmt.Errorf("tracebin: empty trace file %q", path)
	}
	h, err := ParseHeader(line)
	if err != nil {
		f.Close()
		return nil, err
	}
	for _, fd := range h.Fields {
		size, err := kindSize(fd.Kind)
		if err != nil {
			f.Close()
			return nil, err
		}
		if fd.Offset < 0 || fd.Offset+size > h.RecordSize {
			f.Close()
			return nil, fmt.Errorf("tracebin %s: field %q at %d overflows record_size %d", h.Type, fd.Name, fd.Offset, h.RecordSize)
		}
	}
	return &Reader{f: f, br: br, h: h, buf: make([]byte, h.RecordSize)}, nil
}

// FileSuffixes lists the five trace files a complete run produces, as suffixes
// appended to "<run_id>-" (e.g. "0-").
var FileSuffixes = []string{
	"action_trace.bin",
	"session_trace.bin",
	"create_trace.bin",
	"propagation_trace.bin",
	"swap_trace.bin",
}

// CompleteRun reports whether every trace file for a run prefix exists and is
// non-empty. Interrupted simulations leave zero-byte files behind; such a run
// must be excluded entirely, or cascade and dataset disagree on the run set.
func CompleteRun(prefix string) bool {
	for _, suffix := range FileSuffixes {
		st, err := os.Stat(prefix + suffix)
		if err != nil || st.Size() == 0 {
			return false
		}
	}
	return true
}

func (r *Reader) Header() *Header { return r.h }

// Next returns the next raw record. The slice is reused, so copy it if kept.
// It returns io.EOF at a clean end of file and io.ErrUnexpectedEOF if the
// final record is truncated.
func (r *Reader) Next() ([]byte, error) {
	if _, err := io.ReadFull(r.br, r.buf); err != nil {
		return nil, err
	}
	return r.buf, nil
}

func (r *Reader) Close() error { return r.f.Close() }

// Codec streams decoded records of type T from one trace file.
type Codec[T any] struct {
	r      *Reader
	decode func([]byte) T
}

func (c *Codec[T]) Header() *Header { return c.r.Header() }
func (c *Codec[T]) Close() error    { return c.r.Close() }

func (c *Codec[T]) Next() (T, error) {
	var zero T
	rec, err := c.r.Next()
	if err != nil {
		return zero, err
	}
	return c.decode(rec), nil
}

// ForEach calls fn for every record until fn errors or the file ends.
func (c *Codec[T]) ForEach(fn func(T) error) error {
	for {
		v, err := c.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := fn(v); err != nil {
			return err
		}
	}
}

// resolver accumulates the first field-resolution error so typed Open
// functions can resolve all offsets before checking once.
type resolver struct {
	h   *Header
	err error
}

func (r *resolver) off(name, kind string) int {
	if r.err != nil {
		return 0
	}
	o, err := r.h.at(name, kind)
	if err != nil {
		r.err = err
	}
	return o
}

func (r *resolver) enum(name string, variants []string) int {
	if r.err != nil {
		return 0
	}
	o, err := r.h.enumAt(name, variants)
	if err != nil {
		r.err = err
	}
	return o
}

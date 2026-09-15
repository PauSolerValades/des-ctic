package tracebin

import (
	"fmt"
	"math"
)

// ActionType is the kind of user action in the action trace.
type ActionType uint8

const (
	ActionIgnore ActionType = iota
	ActionLike
	ActionRepost
)

var actionVariants = []string{"ignore", "like", "repost"}

func (a ActionType) String() string { return variantName(actionVariants, uint8(a)) }

// SessionType is the kind of session event in the session trace.
type SessionType uint8

const (
	SessionStart SessionType = iota
	SessionEndBoredom
	SessionEnd
)

var sessionVariants = []string{"start", "end_boredom", "end"}

func (s SessionType) String() string { return variantName(sessionVariants, uint8(s)) }

// SwapReason is why a user's timeline was swapped in the swap trace.
type SwapReason uint8

const (
	SwapSimulationStart SwapReason = iota
	SwapSessionStart
	SwapRefresh
)

var swapVariants = []string{"simulation_start", "session_start", "refresh"}

func (s SwapReason) String() string { return variantName(swapVariants, uint8(s)) }

func variantName(variants []string, v uint8) string {
	if int(v) < len(variants) {
		return variants[int(v)]
	}
	return fmt.Sprintf("unknown(%d)", v)
}

// Action is one TraceAction record.
type Action struct {
	Time     float64
	EventID  uint64
	GenID    uint64
	UserID   uint32
	PostID   uint32
	ParentID uint32
	Type     ActionType
}

// Session is one TraceSession record.
type Session struct {
	Time    float64
	EventID uint64
	GenID   uint64
	UserID  uint32
	Type    SessionType
	Backlog uint32
}

// Create is one TraceCreate record.
type Create struct {
	Time    float64
	EventID uint64
	GenID   uint64
	UserID  uint32
	PostID  uint32
}

// Propagation is one TracePropagation record.
type Propagation struct {
	Time    float64
	EventID uint64
	GenID   uint64
	UserID  uint32
	PostID  uint32
}

// Swap is one TraceSwap record.
type Swap struct {
	Time   float64
	UserID uint32
	Reason SwapReason
}

// OpenAction opens an *-action_trace.bin file.
func OpenAction(path string) (*Codec[Action], error) {
	r, err := Open(path)
	if err != nil {
		return nil, err
	}
	h := r.Header()
	res := &resolver{h: h}
	oTime := res.off("time", "f64")
	oEvent := res.off("event_id", "u64")
	oGen := res.off("gen_id", "u64")
	oUser := res.off("user_id", "u32")
	oPost := res.off("post_id", "u32")
	oParent := res.off("parent_id", "u32")
	oType := res.enum("type", actionVariants)
	if res.err != nil {
		r.Close()
		return nil, res.err
	}
	e := h.Endian
	return &Codec[Action]{r: r, decode: func(rec []byte) Action {
		return Action{
			Time:     math.Float64frombits(e.Uint64(rec[oTime:])),
			EventID:  e.Uint64(rec[oEvent:]),
			GenID:    e.Uint64(rec[oGen:]),
			UserID:   e.Uint32(rec[oUser:]),
			PostID:   e.Uint32(rec[oPost:]),
			ParentID: e.Uint32(rec[oParent:]),
			Type:     ActionType(rec[oType]),
		}
	}}, nil
}

// OpenSession opens a *-session_trace.bin file. Note the header may place
// Type and Backlog in either order; offsets are read from the header.
func OpenSession(path string) (*Codec[Session], error) {
	r, err := Open(path)
	if err != nil {
		return nil, err
	}
	h := r.Header()
	res := &resolver{h: h}
	oTime := res.off("time", "f64")
	oEvent := res.off("event_id", "u64")
	oGen := res.off("gen_id", "u64")
	oUser := res.off("user_id", "u32")
	oType := res.enum("type", sessionVariants)
	oBacklog := res.off("backlog", "u32")
	if res.err != nil {
		r.Close()
		return nil, res.err
	}
	e := h.Endian
	return &Codec[Session]{r: r, decode: func(rec []byte) Session {
		return Session{
			Time:    math.Float64frombits(e.Uint64(rec[oTime:])),
			EventID: e.Uint64(rec[oEvent:]),
			GenID:   e.Uint64(rec[oGen:]),
			UserID:  e.Uint32(rec[oUser:]),
			Type:    SessionType(rec[oType]),
			Backlog: e.Uint32(rec[oBacklog:]),
		}
	}}, nil
}

// OpenCreate opens a *-create_trace.bin file.
func OpenCreate(path string) (*Codec[Create], error) {
	r, err := Open(path)
	if err != nil {
		return nil, err
	}
	h := r.Header()
	res := &resolver{h: h}
	oTime := res.off("time", "f64")
	oEvent := res.off("event_id", "u64")
	oGen := res.off("gen_id", "u64")
	oUser := res.off("user_id", "u32")
	oPost := res.off("post_id", "u32")
	if res.err != nil {
		r.Close()
		return nil, res.err
	}
	e := h.Endian
	return &Codec[Create]{r: r, decode: func(rec []byte) Create {
		return Create{
			Time:    math.Float64frombits(e.Uint64(rec[oTime:])),
			EventID: e.Uint64(rec[oEvent:]),
			GenID:   e.Uint64(rec[oGen:]),
			UserID:  e.Uint32(rec[oUser:]),
			PostID:  e.Uint32(rec[oPost:]),
		}
	}}, nil
}

// OpenPropagation opens a *-propagation_trace.bin file.
func OpenPropagation(path string) (*Codec[Propagation], error) {
	r, err := Open(path)
	if err != nil {
		return nil, err
	}
	h := r.Header()
	res := &resolver{h: h}
	oTime := res.off("time", "f64")
	oEvent := res.off("event_id", "u64")
	oGen := res.off("gen_id", "u64")
	oUser := res.off("user_id", "u32")
	oPost := res.off("post_id", "u32")
	if res.err != nil {
		r.Close()
		return nil, res.err
	}
	e := h.Endian
	return &Codec[Propagation]{r: r, decode: func(rec []byte) Propagation {
		return Propagation{
			Time:    math.Float64frombits(e.Uint64(rec[oTime:])),
			EventID: e.Uint64(rec[oEvent:]),
			GenID:   e.Uint64(rec[oGen:]),
			UserID:  e.Uint32(rec[oUser:]),
			PostID:  e.Uint32(rec[oPost:]),
		}
	}}, nil
}

// OpenSwap opens a *-swap_trace.bin file.
func OpenSwap(path string) (*Codec[Swap], error) {
	r, err := Open(path)
	if err != nil {
		return nil, err
	}
	h := r.Header()
	res := &resolver{h: h}
	oTime := res.off("time", "f64")
	oUser := res.off("user_id", "u32")
	oReason := res.enum("reason", swapVariants)
	if res.err != nil {
		r.Close()
		return nil, res.err
	}
	e := h.Endian
	return &Codec[Swap]{r: r, decode: func(rec []byte) Swap {
		return Swap{
			Time:   math.Float64frombits(e.Uint64(rec[oTime:])),
			UserID: e.Uint32(rec[oUser:]),
			Reason: SwapReason(rec[oReason]),
		}
	}}, nil
}

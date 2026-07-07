package cascade

// Repost is a single repost event needed to build a cascade.
type Repost struct {
	RunID    uint32
	PostID   uint32
	UserID   uint32
	ParentID uint32
	Time     float64
}

// Root is the creation event that starts a cascade.
type Root struct {
	RunID    uint32
	PostID   uint32
	AuthorID uint32
	Time     float64
}

// ----- Cascade type -----

// Key uniquely identifies a cascade.
type Key struct {
	RunID  uint32
	PostID uint32
}

// Node is a single node in the cascade tree.
type Node struct {
	UserID uint32
	Time   float64
}

// Cascade is a repost tree for one post, stored in CSR format.
// ChildStart[i] .. ChildStart[i+1] indexes into Children to get the children of node i.
type Cascade struct {
	Key        Key
	Nodes      []Node
	ChildStart []int
	Children   []int
	idxByUser  map[uint32]int
}

// NumNodes returns the total number of nodes including root.
func (c *Cascade) NumNodes() int { return len(c.Nodes) }

// Root returns the root node.
func (c *Cascade) Root() (Node, bool) {
	if len(c.Nodes) == 0 {
		return Node{}, false
	}
	return c.Nodes[0], true
}

// ChildrenOf returns the child indices of node i.
func (c *Cascade) ChildrenOf(i int) []int {
	if i < 0 || i >= len(c.ChildStart)-1 {
		return nil
	}
	return c.Children[c.ChildStart[i]:c.ChildStart[i+1]]
}

// Init builds a Cascade from a root and its reposts using CSR layout.
func Init(key Key, root Root, reposts []Repost) *Cascade {
	n := 1 + len(reposts)

	c := &Cascade{
		Key:        key,
		Nodes:      make([]Node, n),
		ChildStart: make([]int, n+1),
		Children:   make([]int, len(reposts)),
		idxByUser:  make(map[uint32]int, n),
	}

	// Root is index 0
	c.Nodes[0] = Node{UserID: root.AuthorID, Time: root.Time}
	c.idxByUser[root.AuthorID] = 0

	// Pre-pass: build idxByUser for all users first so passes 1 & 2 agree
	for i, r := range reposts {
		c.Nodes[i+1] = Node{UserID: r.UserID, Time: r.Time}
		c.idxByUser[r.UserID] = i + 1
	}

	// Pass 1: count children per parent
	childCount := make([]int, n)
	for _, r := range reposts {
		parentIdx, ok := c.idxByUser[r.ParentID]
		if !ok {
			parentIdx = 0
		}
		childCount[parentIdx]++
	}

	// Build CSR: ChildStart = prefix sum of childCount
	acc := 0
	for i := 0; i < n; i++ {
		c.ChildStart[i] = acc
		acc += childCount[i]
	}
	c.ChildStart[n] = acc

	// Pass 2: fill Children array
	writePos := make([]int, n)
	for i, r := range reposts {
		idx := i + 1
		parentIdx, ok := c.idxByUser[r.ParentID]
		if !ok {
			parentIdx = 0
		}
		pos := c.ChildStart[parentIdx] + writePos[parentIdx]
		c.Children[pos] = idx
		writePos[parentIdx]++
	}

	return c
}

// ----- Cascade-level metrics -----

// AuthorID returns the user who created the post.
func (c *Cascade) AuthorID() uint32 { return c.Nodes[0].UserID }

// CreationTime returns the post creation timestamp.
func (c *Cascade) CreationTime() float64 { return c.Nodes[0].Time }

// Depth returns the maximum depth from root (root = 0).
func (c *Cascade) Depth() int { return c.depth(0, 0) }

// Size returns the total number of nodes (including root).
func (c *Cascade) Size() int { return c.NumNodes() }

// MaxOutDegree returns the maximum children count of any node.
func (c *Cascade) MaxOutDegree() int { return c.maxOutDegree(0) }

// StructuralVirality returns the Wiener-index-based structural virality.
func (c *Cascade) StructuralVirality() float64 {
	n := c.NumNodes()
	if n <= 1 {
		return 0
	}
	var crossings float64
	subtreeSizes(c, 0, n, &crossings)
	return (2.0 * crossings) / float64(n*(n-1))
}

// ----- Broadcast group analysis -----

// BroadcastGroup holds metrics for a single parent's children.
type BroadcastGroup struct {
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

// BroadcastGroups computes broadcast group metrics for every node with children.
func (c *Cascade) BroadcastGroups() []BroadcastGroup {
	var groups []BroadcastGroup
	c.collectBroadcasts(0, &groups)
	return groups
}

func (c *Cascade) collectBroadcasts(n int, groups *[]BroadcastGroup) {
	children := c.ChildrenOf(n)
	if len(children) > 0 {
		*groups = append(*groups, c.broadcastGroup(n))
	}
	for _, child := range children {
		c.collectBroadcasts(child, groups)
	}
}

func (c *Cascade) broadcastGroup(n int) BroadcastGroup {
	children := c.ChildrenOf(n)
	k := len(children)

	times := make([]float64, k)
	for i, child := range children {
		times[i] = c.Nodes[child].Time
	}

	bg := BroadcastGroup{
		RunID:          c.Key.RunID,
		PostID:         c.Key.PostID,
		ParentID:       c.Nodes[n].UserID,
		BroadcastSize:  k,
		FirstChildTime: times[0],
		LastChildTime:  times[k-1],
	}

	if k >= 2 {
		sum := 0.0
		for i := 1; i < k; i++ {
			sum += times[i] - times[i-1]
		}
		bg.MeanGap = sum / float64(k-1)

		gaps := make([]float64, k-1)
		for i := 1; i < k; i++ {
			gaps[i-1] = times[i] - times[i-1]
		}
		m := len(gaps)
		if m%2 == 0 {
			bg.MedianGap = (gaps[m/2-1] + gaps[m/2]) / 2
		} else {
			bg.MedianGap = gaps[m/2]
		}

		bg.GapTrend = computeGapTrend(times)
	}

	return bg
}

// ----- Root-to-leaf path analysis -----

// RootToLeafPath holds metrics for one path from root to a leaf.
type RootToLeafPath struct {
	RunID          uint32
	PostID         uint32
	LeafUserID     uint32
	PathDepth      int
	PathTotalTime  float64
	TraversalSpeed float64
	GapTrend       float64
}

// RootToLeafPaths computes all root-to-leaf path metrics.
func (c *Cascade) RootToLeafPaths() []RootToLeafPath {
	var paths []RootToLeafPath
	c.collectPaths(0, nil, &paths)
	return paths
}

func (c *Cascade) collectPaths(n int, times []float64, paths *[]RootToLeafPath) {
	children := c.ChildrenOf(n)
	if len(children) == 0 {
		p := RootToLeafPath{
			RunID:      c.Key.RunID,
			PostID:     c.Key.PostID,
			LeafUserID: c.Nodes[n].UserID,
			PathDepth:  len(times),
		}
		if len(times) > 0 {
			p.PathTotalTime = c.Nodes[n].Time - times[0]
		}
		if p.PathDepth > 0 {
			p.TraversalSpeed = p.PathTotalTime / float64(p.PathDepth)
		}
		if len(times) >= 3 {
			p.GapTrend = computeGapTrend(times)
		}
		*paths = append(*paths, p)
		return
	}
	for _, child := range children {
		c.collectPaths(child, append(times, c.Nodes[child].Time), paths)
	}
}

// ----- Private helpers -----

func (c *Cascade) depth(n int, d int) int {
	maxD := d
	for _, child := range c.ChildrenOf(n) {
		cd := c.depth(child, d+1)
		if cd > maxD {
			maxD = cd
		}
	}
	return maxD
}

func (c *Cascade) maxOutDegree(n int) int {
	m := len(c.ChildrenOf(n))
	for _, child := range c.ChildrenOf(n) {
		cm := c.maxOutDegree(child)
		if cm > m {
			m = cm
		}
	}
	return m
}

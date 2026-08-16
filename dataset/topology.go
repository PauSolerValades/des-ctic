package main

import (
	"encoding/binary"
	"fmt"
	"os"
)

// Topology holds the social graph in CSR (Compressed Sparse Row) format.
// csr[start[u] : start[u+1]] gives the list of followers of user u.
type Topology struct {
	NumNodes uint32
	userIDs  []uint32
	NumEdges uint32
	csr      []uint32 // flattened follower arrays
	start    []uint32 // start[u] is the offset into csr for user u's followers
	// outDegree[u] = how many users u follows (reverse lookup)
	outDegree []uint32
}

// LoadTopology reads a binary topology file as written by the simulation.
// Format: num_nodes(u32), user_ids([num_nodes]u32), num_edges(u32), edges([num_edges*2]u32)
// Each edge pair is (follower_id, followed_id).
func LoadTopology(path string) (*Topology, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read topology file: %w", err)
	}

	if len(data) < 8 {
		return nil, fmt.Errorf("topology file too small: %d bytes", len(data))
	}

	numNodes := binary.LittleEndian.Uint32(data[0:4])
	offset := 4

	userIDs := make([]uint32, numNodes)
	for i := uint32(0); i < numNodes; i++ {
		if offset+4 > len(data) {
			return nil, fmt.Errorf("truncated user_ids at index %d", i)
		}
		userIDs[i] = binary.LittleEndian.Uint32(data[offset : offset+4])
		offset += 4
	}

	if offset+4 > len(data) {
		return nil, fmt.Errorf("truncated before num_edges")
	}
	numEdges := binary.LittleEndian.Uint32(data[offset : offset+4])
	offset += 4

	// Temporary: per-user list of followers
	tmpFollowers := make([][]uint32, numNodes)
	outDegree := make([]uint32, numNodes)

	edgeCount := numEdges * 2
	_ = edgeCount
	for i := uint32(0); i < numEdges; i++ {
		if offset+8 > len(data) {
			return nil, fmt.Errorf("truncated edges at index %d", i)
		}
		actorID := binary.LittleEndian.Uint32(data[offset : offset+4])
		subjectID := binary.LittleEndian.Uint32(data[offset+4 : offset+8])
		offset += 8

		if subjectID >= numNodes {
			continue
		}
		if actorID >= numNodes {
			continue
		}

		tmpFollowers[subjectID] = append(tmpFollowers[subjectID], actorID)
		outDegree[actorID]++
	}

	// Build CSR
	csr := make([]uint32, numEdges)
	start := make([]uint32, numNodes)

	var acc uint32 = 0
	for u := uint32(0); u < numNodes; u++ {
		start[u] = acc
		n := uint32(len(tmpFollowers[u]))
		copy(csr[acc:acc+n], tmpFollowers[u])
		acc += n
	}

	return &Topology{
		NumNodes:  numNodes,
		userIDs:   userIDs,
		NumEdges:  numEdges,
		csr:       csr,
		start:     start,
		outDegree: outDegree,
	}, nil
}

// Followers returns the list of user IDs who follow the given user.
func (t *Topology) Followers(userID uint32) []uint32 {
	if userID >= t.NumNodes {
		return nil
	}
	start := t.start[userID]
	var end uint32
	if userID+1 < t.NumNodes {
		end = t.start[userID+1]
	} else {
		end = uint32(len(t.csr))
	}
	return t.csr[start:end]
}

// OutDegree returns how many users the given user follows.
func (t *Topology) OutDegree(userID uint32) int {
	if userID >= t.NumNodes {
		return 0
	}
	return int(t.outDegree[userID])
}

// InDegree returns how many followers the given user has.
func (t *Topology) InDegree(userID uint32) int {
	return len(t.Followers(userID))
}

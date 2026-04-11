package main

import (
	"encoding/binary"
	"sync"
	"time"
)

// FEC Header (4 bytes, prepended to each data/parity payload):
//   [group_id: uint16][shard_idx: uint8][orig_len: uint8]
//
// shard_idx: 0..N-1 = data shards, N = parity shard
// orig_len: original payload length (before zero-padding)
const fecHeaderSize = 4

// ── FEC Encoder ──────────────────────────────────────────────
// Buffers data shards, generates XOR parity every N packets.
// Thread-safe: one encoder per worker goroutine.
type FECEncoder struct {
	groupSize int // N data shards per group
	groupID   uint16
	idx       int // current shard index in group
	maxLen    int // max payload size seen in this group
	shards    [][]byte
	parityBuf []byte // pre-allocated parity buffer
	mu        sync.Mutex
}

func NewFECEncoder(groupSize, maxPayload int) *FECEncoder {
	shards := make([][]byte, groupSize)
	for i := range shards {
		shards[i] = make([]byte, maxPayload)
	}
	return &FECEncoder{
		groupSize: groupSize,
		shards:    shards,
		parityBuf: make([]byte, maxPayload),
	}
}

// AddAndEncode adds a data shard and returns packets to send.
// Returns: list of (pktType, payload) tuples to send.
// When group is full, returns N data + 1 parity packet.
// Otherwise returns just the data packet immediately.
func (e *FECEncoder) AddAndEncode(data []byte) (packets []FECSendItem) {
	e.mu.Lock()
	defer e.mu.Unlock()

	dataLen := len(data)
	if dataLen > len(e.shards[0]) {
		dataLen = len(e.shards[0])
	}

	// Copy data into shard buffer (zero-padded)
	copy(e.shards[e.idx][:dataLen], data[:dataLen])
	for i := dataLen; i < len(e.shards[e.idx]); i++ {
		e.shards[e.idx][i] = 0
	}

	if dataLen > e.maxLen {
		e.maxLen = dataLen
	}

	// Build FEC header for this data shard
	hdr := makeFECHeader(e.groupID, uint8(e.idx), uint8(dataLen))

	// Always send data immediately (don't wait for group completion)
	item := FECSendItem{
		PktType: PktTypeData,
		Payload: make([]byte, fecHeaderSize+dataLen),
	}
	copy(item.Payload[:fecHeaderSize], hdr[:])
	copy(item.Payload[fecHeaderSize:], data[:dataLen])
	packets = append(packets, item)

	e.idx++

	// Group complete — generate parity
	if e.idx >= e.groupSize {
		parity := e.generateParity()
		parityItem := FECSendItem{
			PktType: PktTypeFEC,
			Payload: make([]byte, fecHeaderSize+e.maxLen),
		}
		parityHdr := makeFECHeader(e.groupID, uint8(e.groupSize), uint8(0))
		copy(parityItem.Payload[:fecHeaderSize], parityHdr[:])
		copy(parityItem.Payload[fecHeaderSize:], parity[:e.maxLen])
		packets = append(packets, parityItem)

		// Reset for next group
		e.groupID++
		e.idx = 0
		e.maxLen = 0
	}

	return packets
}

// Flush sends remaining data without parity (called on timeout).
func (e *FECEncoder) Flush() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.idx > 0 {
		e.groupID++
		e.idx = 0
		e.maxLen = 0
	}
}

func (e *FECEncoder) generateParity() []byte {
	// XOR all shards
	maxLen := e.maxLen
	for i := 0; i < maxLen; i++ {
		e.parityBuf[i] = 0
	}
	for s := 0; s < e.groupSize; s++ {
		for i := 0; i < maxLen; i++ {
			e.parityBuf[i] ^= e.shards[s][i]
		}
	}
	return e.parityBuf
}

// ── FEC Decoder ──────────────────────────────────────────────
// Collects shards by group_id, reconstructs missing data.

type FECGroup struct {
	shards    [][]byte // data shards (nil = missing)
	parity    []byte   // parity shard (nil = missing)
	lens      []uint8  // original lengths per shard
	received  int      // count of received data shards
	hasParity bool
	maxLen    int
	timestamp time.Time
}

type FECDecoder struct {
	groupSize int
	groups    map[uint16]*FECGroup
	mu        sync.Mutex
	maxPayload int
}

func NewFECDecoder(groupSize, maxPayload int) *FECDecoder {
	d := &FECDecoder{
		groupSize:  groupSize,
		groups:     make(map[uint16]*FECGroup),
		maxPayload: maxPayload,
	}
	// Start cleanup goroutine for expired groups
	go d.cleanupLoop()
	return d
}

// OnDataShard processes an incoming data shard.
// Returns recovered data if a missing shard was reconstructed, or nil.
func (d *FECDecoder) OnDataShard(groupID uint16, shardIdx uint8, origLen uint8, payload []byte) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()

	g := d.getOrCreateGroup(groupID)
	if int(shardIdx) >= d.groupSize || g.shards[shardIdx] != nil {
		return nil // invalid index or duplicate
	}

	g.shards[shardIdx] = make([]byte, len(payload))
	copy(g.shards[shardIdx], payload)
	g.lens[shardIdx] = origLen
	g.received++
	if len(payload) > g.maxLen {
		g.maxLen = len(payload)
	}

	return d.tryRecover(groupID, g)
}

// OnParityShard processes an incoming parity shard.
// Returns recovered data if a missing shard was reconstructed, or nil.
func (d *FECDecoder) OnParityShard(groupID uint16, payload []byte) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()

	g := d.getOrCreateGroup(groupID)
	if g.hasParity {
		return nil // duplicate
	}

	g.parity = make([]byte, len(payload))
	copy(g.parity, payload)
	g.hasParity = true
	if len(payload) > g.maxLen {
		g.maxLen = len(payload)
	}

	return d.tryRecover(groupID, g)
}

func (d *FECDecoder) getOrCreateGroup(groupID uint16) *FECGroup {
	g, ok := d.groups[groupID]
	if !ok {
		g = &FECGroup{
			shards:    make([][]byte, d.groupSize),
			lens:      make([]uint8, d.groupSize),
			timestamp: time.Now(),
		}
		d.groups[groupID] = g
	}
	return g
}

// tryRecover checks if exactly 1 data shard is missing and parity is available.
// If so, recovers it via XOR and returns the recovered payload.
func (d *FECDecoder) tryRecover(groupID uint16, g *FECGroup) []byte {
	if g.received >= d.groupSize {
		// All data received — no recovery needed, clean up
		delete(d.groups, groupID)
		return nil
	}

	if g.received != d.groupSize-1 || !g.hasParity {
		return nil // need exactly N-1 data + parity to recover
	}

	// Find the missing shard index
	missingIdx := -1
	for i := 0; i < d.groupSize; i++ {
		if g.shards[i] == nil {
			missingIdx = i
			break
		}
	}
	if missingIdx < 0 {
		delete(d.groups, groupID)
		return nil
	}

	// Recover: XOR parity with all present shards
	recovered := make([]byte, g.maxLen)
	copy(recovered, g.parity)
	for i := 0; i < d.groupSize; i++ {
		if i == missingIdx {
			continue
		}
		for j := 0; j < g.maxLen && j < len(g.shards[i]); j++ {
			recovered[j] ^= g.shards[i][j]
		}
	}

	// Figure out original length from reverse XOR of lens
	// We stored orig_len in the FEC header, but the missing shard's header
	// was never received. We need to reconstruct it.
	// For simplicity, use maxLen as the recovered length
	// (the parity covers all zero-padded data, so trailing zeros are harmless)
	// TCP/IP stack will handle any extra zeros.

	// Clean up
	delete(d.groups, groupID)
	return recovered[:g.maxLen]
}

func (d *FECDecoder) cleanupLoop() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		d.mu.Lock()
		now := time.Now()
		for gid, g := range d.groups {
			if now.Sub(g.timestamp) > 2*time.Second {
				delete(d.groups, gid)
			}
		}
		d.mu.Unlock()
	}
}

// ── Helpers ──────────────────────────────────────────────────

type FECSendItem struct {
	PktType byte
	Payload []byte // [FEC header (4 bytes)][data]
}

func makeFECHeader(groupID uint16, shardIdx, origLen uint8) [fecHeaderSize]byte {
	var hdr [fecHeaderSize]byte
	binary.BigEndian.PutUint16(hdr[0:2], groupID)
	hdr[2] = shardIdx
	hdr[3] = origLen
	return hdr
}

func parseFECHeader(data []byte) (groupID uint16, shardIdx uint8, origLen uint8) {
	if len(data) < fecHeaderSize {
		return 0, 0, 0
	}
	groupID = binary.BigEndian.Uint16(data[0:2])
	shardIdx = data[2]
	origLen = data[3]
	return
}

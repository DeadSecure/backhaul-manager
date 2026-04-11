package main

import (
	"encoding/binary"
	"sync"
	"time"
)

// FEC Header layout (6 bytes, prepended to data/parity payload):
//   [seqid: uint32][shard_idx: uint8][orig_len: uint8]
//
// seqid: monotonically increasing sequence number for the FEC group
// shard_idx: 0..N-1 = data shards, N..N+P-1 = parity shards
// orig_len: original data payload length before zero-padding (0 for parity)
//
// Design decisions (inspired by kcp-go):
//   - uint32 seqid prevents wrap-around collision at high PPS
//   - Separate PktTypeFECData / PktTypeFECParity byte in the wire header
//     eliminates the need to "guess" whether a Data packet is FEC-encoded
//   - Encoder is lock-free (one encoder per worker goroutine)
//   - Decoder uses sync.Pool for shard buffers to minimize GC pressure
const fecHeaderSize = 6

// ── FEC Encoder ──────────────────────────────────────────────
// One encoder per worker goroutine — NO locks needed.
// Buffers N data shards, generates 1 XOR parity, sends via callback.
// Zero allocations in steady state: all buffers pre-allocated.
type FECEncoder struct {
	groupSize int    // data shards per FEC group (e.g. 4)
	next      uint32 // monotonic sequence number (like kcp-go)

	shardCount int // shards buffered so far in current group
	maxLen     int // max payload length in current group

	// Pre-allocated storage — reused every group
	shards    [][]byte // [groupSize] shard copies (zero-padded)
	parityBuf []byte   // XOR accumulator
	sendBuf   []byte   // temporary buffer for building packets
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
		sendBuf:   make([]byte, fecHeaderSize+maxPayload),
	}
}

// EncodeAndSend processes one TUN packet:
//   - Immediately sends it as PktTypeFECData with an FEC header
//   - When the group fills (N data shards), also sends 1 PktTypeFECParity
//
// Zero allocations — sendFn receives a borrowed buffer valid only during call.
func (e *FECEncoder) EncodeAndSend(data []byte, sendFn func(pktType byte, payload []byte)) {
	dataLen := len(data)
	if dataLen > len(e.shards[0]) {
		dataLen = len(e.shards[0])
	}

	// Store data in shard buffer, zero-pad tail
	copy(e.shards[e.shardCount][:dataLen], data[:dataLen])
	for i := dataLen; i < len(e.shards[e.shardCount]); i++ {
		e.shards[e.shardCount][i] = 0
	}
	if dataLen > e.maxLen {
		e.maxLen = dataLen
	}

	// Build and send data shard: [seqid(4)][shard_idx(1)][orig_len(1)][payload]
	binary.BigEndian.PutUint32(e.sendBuf[0:4], e.next)
	e.sendBuf[4] = uint8(e.shardCount)
	e.sendBuf[5] = uint8(dataLen) // NOTE: max 255 — fine, TUN MTU is written here as-is
	copy(e.sendBuf[fecHeaderSize:], data[:dataLen])
	sendFn(PktTypeFECData, e.sendBuf[:fecHeaderSize+dataLen])
	e.next++

	e.shardCount++

	// Group complete — generate XOR parity
	if e.shardCount >= e.groupSize {
		// XOR all shards (only up to maxLen for efficiency)
		for i := 0; i < e.maxLen; i++ {
			e.parityBuf[i] = 0
		}
		for s := 0; s < e.groupSize; s++ {
			for i := 0; i < e.maxLen; i++ {
				e.parityBuf[i] ^= e.shards[s][i]
			}
		}

		// Send parity: [seqid(4)][shard_idx=groupSize(1)][0(1)][parity_data]
		binary.BigEndian.PutUint32(e.sendBuf[0:4], e.next)
		e.sendBuf[4] = uint8(e.groupSize) // parity index = N
		e.sendBuf[5] = 0                  // orig_len=0 for parity
		copy(e.sendBuf[fecHeaderSize:], e.parityBuf[:e.maxLen])
		sendFn(PktTypeFECParity, e.sendBuf[:fecHeaderSize+e.maxLen])
		e.next++

		// Reset for next group
		e.shardCount = 0
		e.maxLen = 0
	}
}

// ── FEC Decoder ──────────────────────────────────────────────
// Collects shards by group, reconstructs 1 missing data shard via XOR.
// Uses sync.Pool for shard buffers to minimize GC pressure.
// Expired groups cleaned by background goroutine.

var decoderBufPool = sync.Pool{
	New: func() interface{} {
		buf := make([]byte, 2048)
		return &buf
	},
}

type fecGroup struct {
	shards    []*[]byte // pooled buffers (nil = not received)
	shardLens []int     // actual data length per shard (0 = not received)
	origLens  []uint8   // orig_len from FEC header
	parity    *[]byte   // pooled parity buffer (nil = not received)
	parityLen int       // actual parity data length
	received  int       // count of data shards received
	hasParity bool
	maxLen    int
	created   time.Time
}

type FECDecoder struct {
	groupSize int
	groups    map[uint32]*fecGroup // key = seqid of first shard in group
	mu        sync.Mutex
}

func NewFECDecoder(groupSize int) *FECDecoder {
	d := &FECDecoder{
		groupSize: groupSize,
		groups:    make(map[uint32]*fecGroup),
	}
	go d.cleanupLoop()
	return d
}

// seqid-to-groupKey: the first seqid in the group.
// Group contains seqids: [key, key+1, ..., key+groupSize]
// where key+groupSize = parity.
func (d *FECDecoder) groupKey(seqid uint32) uint32 {
	shardSize := uint32(d.groupSize + 1) // data + parity
	return (seqid / shardSize) * shardSize
}

// OnDataShard processes an incoming FEC data shard.
// Returns recovered payload if recovery happened, otherwise nil.
func (d *FECDecoder) OnDataShard(seqid uint32, shardIdx uint8, origLen uint8, payload []byte) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()

	key := d.groupKey(seqid)
	g := d.getOrCreate(key)

	if int(shardIdx) >= d.groupSize || g.shards[shardIdx] != nil {
		return nil // invalid or duplicate
	}

	// Copy payload to pooled buffer
	bufPtr := decoderBufPool.Get().(*[]byte)
	buf := *bufPtr
	if len(payload) > len(buf) {
		buf = make([]byte, len(payload))
		*bufPtr = buf
	}
	n := copy(buf[:len(payload)], payload)

	g.shards[shardIdx] = bufPtr
	g.shardLens[shardIdx] = n
	g.origLens[shardIdx] = origLen
	g.received++
	if n > g.maxLen {
		g.maxLen = n
	}

	return d.tryRecover(key, g)
}

// OnParityShard processes an incoming FEC parity shard.
func (d *FECDecoder) OnParityShard(seqid uint32, payload []byte) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()

	key := d.groupKey(seqid)
	g := d.getOrCreate(key)

	if g.hasParity {
		return nil // duplicate
	}

	bufPtr := decoderBufPool.Get().(*[]byte)
	buf := *bufPtr
	if len(payload) > len(buf) {
		buf = make([]byte, len(payload))
		*bufPtr = buf
	}
	n := copy(buf[:len(payload)], payload)

	g.parity = bufPtr
	g.parityLen = n
	g.hasParity = true
	if n > g.maxLen {
		g.maxLen = n
	}

	return d.tryRecover(key, g)
}

func (d *FECDecoder) getOrCreate(key uint32) *fecGroup {
	g, ok := d.groups[key]
	if !ok {
		g = &fecGroup{
			shards:    make([]*[]byte, d.groupSize),
			shardLens: make([]int, d.groupSize),
			origLens:  make([]uint8, d.groupSize),
			created:   time.Now(),
		}
		d.groups[key] = g
	}
	return g
}

// tryRecover attempts XOR recovery when exactly 1 data shard is missing.
func (d *FECDecoder) tryRecover(key uint32, g *fecGroup) []byte {
	if g.received >= d.groupSize {
		// All data received — clean up, no recovery needed
		d.releaseGroup(key)
		return nil
	}

	if g.received != d.groupSize-1 || !g.hasParity {
		return nil // need exactly N-1 data + parity
	}

	// Find missing shard
	missingIdx := -1
	for i := 0; i < d.groupSize; i++ {
		if g.shards[i] == nil {
			missingIdx = i
			break
		}
	}
	if missingIdx < 0 {
		d.releaseGroup(key)
		return nil
	}

	// XOR-recover: result = parity ^ shard[0] ^ shard[1] ^ ... (skip missing)
	recovered := make([]byte, g.maxLen)
	parityData := (*g.parity)[:g.parityLen]
	copy(recovered, parityData)

	for i := 0; i < d.groupSize; i++ {
		if i == missingIdx {
			continue
		}
		sdata := (*g.shards[i])[:g.shardLens[i]]
		for j := 0; j < len(sdata) && j < g.maxLen; j++ {
			recovered[j] ^= sdata[j]
		}
	}

	d.releaseGroup(key)
	return recovered[:g.maxLen]
}

// releaseGroup returns all pooled buffers and removes the group.
func (d *FECDecoder) releaseGroup(key uint32) {
	g, ok := d.groups[key]
	if !ok {
		return
	}
	for i := range g.shards {
		if g.shards[i] != nil {
			decoderBufPool.Put(g.shards[i])
		}
	}
	if g.parity != nil {
		decoderBufPool.Put(g.parity)
	}
	delete(d.groups, key)
}

// cleanupLoop removes expired incomplete groups every 500ms.
func (d *FECDecoder) cleanupLoop() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		d.mu.Lock()
		now := time.Now()
		for key, g := range d.groups {
			if now.Sub(g.created) > 2*time.Second {
				d.releaseGroup(key)
			}
		}
		d.mu.Unlock()
	}
}

// ── Helpers ──────────────────────────────────────────────────

func parseFECHeader(data []byte) (seqid uint32, shardIdx uint8, origLen uint8) {
	if len(data) < fecHeaderSize {
		return 0, 0, 0
	}
	seqid = binary.BigEndian.Uint32(data[0:4])
	shardIdx = data[4]
	origLen = data[5]
	return
}

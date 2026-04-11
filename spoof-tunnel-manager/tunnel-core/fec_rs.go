package main

import (
	"encoding/binary"
	"log"
	"sync"
	"time"

	"github.com/klauspost/reedsolomon"
)

// Reed-Solomon FEC: stronger recovery than XOR, at the cost of more CPU.
// Default: 4 data + 2 parity = recover up to 2 lost packets per group of 6.
// Overhead: 50%.
//
// RS Header layout (same as XOR FEC, 6 bytes):
//   [seqid: uint32][shard_idx: uint8][total_shards: uint8]
//
// shard_idx: 0..dataShards-1 = data, dataShards..totalShards-1 = parity
// total_shards: dataShards + parityShards (used by decoder to validate)

const (
	rsDataShards   = 4
	rsParityShards = 2
	rsTotalShards  = rsDataShards + rsParityShards // 6
)

// ── RS Encoder ──────────────────────────────────────────────
// One encoder per worker goroutine — NO locks needed.
type RSEncoder struct {
	enc       reedsolomon.Encoder
	next      uint32
	count     int    // shards buffered so far
	maxLen    int    // max payload in current group
	shards    [][]byte // [rsTotalShards] pre-allocated
	sendBuf   []byte
}

func NewRSEncoder(maxPayload int) *RSEncoder {
	enc, err := reedsolomon.New(rsDataShards, rsParityShards)
	if err != nil {
		log.Fatalf("RS encoder init failed: %v", err)
	}

	shards := make([][]byte, rsTotalShards)
	for i := range shards {
		shards[i] = make([]byte, maxPayload)
	}

	return &RSEncoder{
		enc:     enc,
		shards:  shards,
		sendBuf: make([]byte, fecHeaderSize+maxPayload),
	}
}

// EncodeAndSend processes one TUN packet. Sends data immediately.
// When group fills (4 data), generates 2 parity shards and sends them too.
func (e *RSEncoder) EncodeAndSend(data []byte, sendFn func(pktType byte, payload []byte)) {
	dataLen := len(data)
	if dataLen > len(e.shards[0]) {
		dataLen = len(e.shards[0])
	}

	// Copy into shard buffer, zero-pad tail
	copy(e.shards[e.count][:dataLen], data[:dataLen])
	for i := dataLen; i < len(e.shards[e.count]); i++ {
		e.shards[e.count][i] = 0
	}
	if dataLen > e.maxLen {
		e.maxLen = dataLen
	}

	// Send data shard immediately: [seqid(4)][shard_idx(1)][total_shards(1)][payload]
	binary.BigEndian.PutUint32(e.sendBuf[0:4], e.next)
	e.sendBuf[4] = uint8(e.count)
	e.sendBuf[5] = uint8(rsTotalShards)
	copy(e.sendBuf[fecHeaderSize:], data[:dataLen])
	sendFn(PktTypeRSData, e.sendBuf[:fecHeaderSize+dataLen])
	e.next++

	e.count++

	// Group complete — generate RS parity
	if e.count >= rsDataShards {
		// Trim all shards to maxLen for RS encoding
		trimmed := make([][]byte, rsTotalShards)
		for i := 0; i < rsTotalShards; i++ {
			trimmed[i] = e.shards[i][:e.maxLen]
		}

		// Zero out parity shards before encoding
		for i := rsDataShards; i < rsTotalShards; i++ {
			for j := 0; j < e.maxLen; j++ {
				trimmed[i][j] = 0
			}
		}

		// Reed-Solomon encode — fills parity shards
		if err := e.enc.Encode(trimmed); err != nil {
			// Encoding failed — skip parity, advance seqid
			e.next += uint32(rsParityShards)
			e.count = 0
			e.maxLen = 0
			return
		}

		// Send parity shards
		for p := 0; p < rsParityShards; p++ {
			idx := rsDataShards + p
			binary.BigEndian.PutUint32(e.sendBuf[0:4], e.next)
			e.sendBuf[4] = uint8(idx)
			e.sendBuf[5] = uint8(rsTotalShards)
			copy(e.sendBuf[fecHeaderSize:], trimmed[idx])
			sendFn(PktTypeRSParity, e.sendBuf[:fecHeaderSize+e.maxLen])
			e.next++
		}

		e.count = 0
		e.maxLen = 0
	}
}

// ── RS Decoder ──────────────────────────────────────────────
// Collects shards by group, reconstructs missing data via RS.

var rsDecoderBufPool = sync.Pool{
	New: func() interface{} {
		buf := make([]byte, 2048)
		return &buf
	},
}

type rsGroup struct {
	shards    [rsTotalShards]*[]byte // pooled buffers (nil = not received)
	shardLens [rsTotalShards]int     // actual payload length
	present   [rsTotalShards]bool    // which shards received
	received  int
	maxLen    int
	created   time.Time
}

type RSDecoder struct {
	dec    reedsolomon.Encoder
	groups map[uint32]*rsGroup // key = first seqid of group
	mu     sync.Mutex
}

func NewRSDecoder() *RSDecoder {
	dec, err := reedsolomon.New(rsDataShards, rsParityShards)
	if err != nil {
		log.Fatalf("RS decoder init failed: %v", err)
	}
	d := &RSDecoder{
		dec:    dec,
		groups: make(map[uint32]*rsGroup),
	}
	go d.cleanupLoop()
	return d
}

func (d *RSDecoder) groupKey(seqid uint32) uint32 {
	return (seqid / uint32(rsTotalShards)) * uint32(rsTotalShards)
}

// OnShard processes any incoming RS shard (data or parity).
// Returns list of recovered DATA payloads (may be 0, 1, or 2).
func (d *RSDecoder) OnShard(seqid uint32, shardIdx uint8, payload []byte) [][]byte {
	d.mu.Lock()
	defer d.mu.Unlock()

	if int(shardIdx) >= rsTotalShards {
		return nil
	}

	key := d.groupKey(seqid)
	g := d.getOrCreate(key)

	if g.present[shardIdx] {
		return nil // duplicate
	}

	// Store in pooled buffer
	bufPtr := rsDecoderBufPool.Get().(*[]byte)
	buf := *bufPtr
	if len(payload) > len(buf) {
		buf = make([]byte, len(payload))
		*bufPtr = buf
	}
	n := copy(buf[:len(payload)], payload)

	g.shards[shardIdx] = bufPtr
	g.shardLens[shardIdx] = n
	g.present[shardIdx] = true
	g.received++
	if n > g.maxLen {
		g.maxLen = n
	}

	// Need at least rsDataShards (4) shards total to attempt recovery
	if g.received < rsDataShards {
		return nil
	}

	return d.tryRecover(key, g)
}

func (d *RSDecoder) getOrCreate(key uint32) *rsGroup {
	g, ok := d.groups[key]
	if !ok {
		g = &rsGroup{
			created: time.Now(),
		}
		d.groups[key] = g
	}
	return g
}

func (d *RSDecoder) tryRecover(key uint32, g *rsGroup) [][]byte {
	// Check if ALL data shards present — no recovery needed
	allDataPresent := true
	for i := 0; i < rsDataShards; i++ {
		if !g.present[i] {
			allDataPresent = false
			break
		}
	}
	if allDataPresent {
		d.releaseGroup(key)
		return nil
	}

	// Need exactly rsDataShards total to reconstruct
	if g.received < rsDataShards {
		return nil
	}

	// Build shard matrix for RS reconstruction
	rsShards := make([][]byte, rsTotalShards)
	for i := 0; i < rsTotalShards; i++ {
		if g.present[i] {
			// Copy data, pad to maxLen
			rsShards[i] = make([]byte, g.maxLen)
			copy(rsShards[i], (*g.shards[i])[:g.shardLens[i]])
		} else {
			rsShards[i] = nil // mark as missing
		}
	}

	// Reed-Solomon reconstruct — recovers missing shards in-place
	if err := d.dec.ReconstructData(rsShards); err != nil {
		// Not enough shards or other error
		if g.received >= rsTotalShards {
			d.releaseGroup(key)
		}
		return nil
	}

	// Collect recovered DATA shards (only data, not parity)
	var recovered [][]byte
	for i := 0; i < rsDataShards; i++ {
		if !g.present[i] && rsShards[i] != nil {
			recovered = append(recovered, rsShards[i][:g.maxLen])
		}
	}

	d.releaseGroup(key)
	return recovered
}

func (d *RSDecoder) releaseGroup(key uint32) {
	g, ok := d.groups[key]
	if !ok {
		return
	}
	for i := range g.shards {
		if g.shards[i] != nil {
			rsDecoderBufPool.Put(g.shards[i])
		}
	}
	delete(d.groups, key)
}

func (d *RSDecoder) cleanupLoop() {
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

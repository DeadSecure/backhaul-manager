package main

import (
	"log"
	"net"
	"sync"
	"syscall"

	"github.com/songgao/water"
)

// poolBuf wraps a byte slice for safe pool recycling.
type poolBuf struct {
	data []byte
}

type tunPkt struct {
	pb  *poolBuf
	len int
}

// StartForwarder reads TUN packets and sends via flow-hashed workers.
// Flow hashing ensures per-destination packet ordering (critical for TCP).
// Uses sync.Pool for buffer recycling and non-blocking sends for backpressure.
func StartForwarder(ifce *water.Interface, dstIPStr string, dstPort int, spoofSrcStr string, srcPort int, workers int, mtu int, channelSize int) {
	dstIP := net.ParseIP(dstIPStr).To4()
	srcIP := net.ParseIP(spoofSrcStr).To4()
	if dstIP == nil || srcIP == nil {
		log.Fatalf("Forwarder: invalid IPs dst=%s src=%s", dstIPStr, spoofSrcStr)
	}

	var dstMap [4]byte
	copy(dstMap[:], dstIP)
	dstAddr := &syscall.SockaddrInet4{Port: dstPort, Addr: dstMap}

	// maxPayload must be >= 1 (type byte) + max TUN read size
	// readBuf is mtu+100, so maxPayload must cover that + type byte + safety
	maxPayload := 1 + mtu + 150

	// Buffer pool — eliminates per-packet heap allocation
	bufPool := &sync.Pool{
		New: func() interface{} {
			return &poolBuf{data: make([]byte, mtu+100)}
		},
	}

	// Per-worker channels: flow hashing sends same-flow packets to same worker
	// This preserves TCP packet ordering within each flow
	if channelSize <= 0 {
		channelSize = 10000
	}
	chSize := channelSize / workers
	if chSize < 512 {
		chSize = 512
	}
	workerChs := make([]chan tunPkt, workers)
	for i := 0; i < workers; i++ {
		workerChs[i] = make(chan tunPkt, chSize)
		go func(ch chan tunPkt) {
			ctx := NewSpoofContext(srcIP, dstIP, srcPort, dstPort, maxPayload, dstAddr)
			for tp := range ch {
				_ = ctx.SendTyped(PktTypeData, tp.pb.data[:tp.len])
				bufPool.Put(tp.pb)
			}
		}(workerChs[i])
	}

	log.Printf("Forwarder: %d flow-hashed workers, TUN -> %s:%d (spoof: %s)", workers, dstIPStr, dstPort, spoofSrcStr)

	readBuf := make([]byte, mtu+100)
	for {
		n, err := ifce.Read(readBuf)
		if err != nil {
			log.Fatalf("TUN read error: %v", err)
		}
		if n == 0 {
			continue
		}

		pb := bufPool.Get().(*poolBuf)
		copy(pb.data[:n], readBuf[:n])
		tp := tunPkt{pb: pb, len: n}

		// Flow hash: use inner IP destination (bytes 16-19) to pick worker.
		// All packets to same dest IP go through same worker → TCP ordering preserved.
		var workerIdx uint
		if n >= 20 {
			workerIdx = (uint(readBuf[16]) ^ uint(readBuf[17]) ^ uint(readBuf[18]) ^ uint(readBuf[19])) % uint(workers)
		}

		select {
		case workerChs[workerIdx] <- tp:
		default:
			bufPool.Put(pb) // Channel full — drop, recycle buffer
		}
	}
}

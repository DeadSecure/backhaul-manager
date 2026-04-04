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
// Each worker has its own raw socket FD — zero contention under load.
// Uses HEAD-DROP strategy: when queue is full, discard OLDEST packet
// and insert new one. This keeps latency bounded under heavy load.
func StartForwarder(ifce *water.Interface, dstIPStr string, dstPort int, spoofSrcStr string, srcPort int, workers int, mtu int, channelSize int, sndbuf int) {
	dstIP := net.ParseIP(dstIPStr).To4()
	srcIP := net.ParseIP(spoofSrcStr).To4()
	if dstIP == nil || srcIP == nil {
		log.Fatalf("Forwarder: invalid IPs dst=%s src=%s", dstIPStr, spoofSrcStr)
	}

	var dstMap [4]byte
	copy(dstMap[:], dstIP)

	// maxPayload must be >= 1 (type byte) + max TUN read size
	maxPayload := 1 + mtu + 150

	// Buffer pool — eliminates per-packet heap allocation
	bufPool := &sync.Pool{
		New: func() interface{} {
			return &poolBuf{data: make([]byte, mtu+100)}
		},
	}

	// Anti-bufferbloat: keep channels SMALL
	// 64 packets * ~1400 bytes = ~90KB per worker ≈ 7ms at 100Mbps
	// Combined with HEAD-DROP, this guarantees low latency under any load
	if channelSize <= 0 {
		channelSize = 128
	}
	chSize := channelSize / workers
	if chSize < 32 {
		chSize = 32
	}
	if chSize > 64 {
		chSize = 64
	}

	// Track raw FDs for cleanup
	rawFDs := make([]int, 0, workers)

	workerChs := make([]chan tunPkt, workers)
	for i := 0; i < workers; i++ {
		workerChs[i] = make(chan tunPkt, chSize)

		// Each worker gets its own raw socket — NO mutex, NO contention
		fd, err := CreateRawSocket(sndbuf)
		if err != nil {
			log.Fatalf("Forwarder: worker %d raw socket failed: %v", i, err)
		}
		rawFDs = append(rawFDs, fd)

		go func(ch chan tunPkt, workerFD int) {
			dstAddr := &syscall.SockaddrInet4{Port: dstPort, Addr: dstMap}
			ctx := NewSpoofContext(srcIP, dstIP, srcPort, dstPort, maxPayload, dstAddr, workerFD)
			for tp := range ch {
				_ = ctx.SendTyped(PktTypeData, tp.pb.data[:tp.len])
				bufPool.Put(tp.pb)
			}
		}(workerChs[i], fd)
	}

	log.Printf("Forwarder: %d workers (per-worker FD), ch=%d [head-drop], TUN -> %s:%d (spoof: %s)", workers, chSize, dstIPStr, dstPort, spoofSrcStr)

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

		// Flow hash: use inner IP dst + src for even distribution
		var workerIdx uint
		if n >= 20 {
			workerIdx = (uint(readBuf[12]) ^ uint(readBuf[13]) ^ uint(readBuf[14]) ^ uint(readBuf[15]) ^
				uint(readBuf[16]) ^ uint(readBuf[17]) ^ uint(readBuf[18]) ^ uint(readBuf[19])) % uint(workers)
		}

		// HEAD-DROP: if channel full, discard OLDEST packet, insert NEW one.
		// This is the key anti-bufferbloat mechanism:
		// - Tail-drop (old behavior): drops new packet → stale data stays in queue → latency grows
		// - Head-drop (new behavior): drops old packet → fresh data always flows → latency stays bounded
		select {
		case workerChs[workerIdx] <- tp:
			// Inserted — all good
		default:
			// Channel full — evict oldest, then insert new
			select {
			case old := <-workerChs[workerIdx]:
				bufPool.Put(old.pb) // recycle stale packet
			default:
			}
			select {
			case workerChs[workerIdx] <- tp:
			default:
				bufPool.Put(pb) // still full (race), drop new
			}
		}
	}
}

package main

import (
	"log"
	"net"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/songgao/water"
)

// lastPongTime is updated atomically by the receiver when a pong arrives.
var lastPongTime int64

// StartReceiver listens for incoming UDP using raw syscalls (zero-allocation).
// Validates source IP, filters heartbeats, writes data packets to TUN.
func StartReceiver(ifce *water.Interface, listenIP string, listenPort int, mtu int, expectedSrcIP string, spoofSrcIP string, dstIPStr string, dstPort int, sndbuf int) {
	// Create UDP socket via syscall — avoids net.UDPConn which allocates per-read
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, syscall.IPPROTO_UDP)
	if err != nil {
		log.Fatalf("Receiver: socket failed: %v", err)
	}

	// Allow address reuse
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)

	// Bind to listen address
	listenIPv4 := net.ParseIP(listenIP).To4()
	if listenIPv4 == nil {
		log.Fatalf("Receiver: invalid listen IP: %s", listenIP)
	}
	var bindAddr [4]byte
	copy(bindAddr[:], listenIPv4)
	sa := &syscall.SockaddrInet4{Port: listenPort, Addr: bindAddr}
	if err := syscall.Bind(fd, sa); err != nil {
		log.Fatalf("Receiver: bind %s:%d failed: %v", listenIP, listenPort, err)
	}

	// Large receive buffer to absorb bursts
	rcvBuf := 8 * 1024 * 1024
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, rcvBuf)

	// Pre-compute allowed source IP as [4]byte for zero-alloc comparison
	var allowedSrc [4]byte
	hasAllowedSrc := false
	if expectedSrcIP != "" {
		srcParsed := net.ParseIP(expectedSrcIP).To4()
		if srcParsed != nil {
			copy(allowedSrc[:], srcParsed)
			hasAllowedSrc = true
		}
	}

	// Pong context gets its own raw socket — independent from forwarder
	pongFD, err := CreateRawSocket(sndbuf)
	if err != nil {
		log.Fatalf("Receiver: pong raw socket failed: %v", err)
	}

	pongSrcIP := net.ParseIP(spoofSrcIP).To4()
	pongDstIP := net.ParseIP(dstIPStr).To4()
	var pongDstMap [4]byte
	copy(pongDstMap[:], pongDstIP)
	pongAddr := &syscall.SockaddrInet4{Port: dstPort, Addr: pongDstMap}
	pongCtx := NewSpoofContext(pongSrcIP, pongDstIP, listenPort, dstPort, 64, pongAddr, pongFD)
	pongPayload := []byte{PktTypePong}

	log.Printf("Receiver on %s:%d (accept from: %s) [zero-alloc mode, dedup ON]", listenIP, listenPort, expectedSrcIP)

	// Dedup ring buffer — catches duplicates from packet_multiply (mode 2)
	const dedupSize = 8
	var dedupRing [dedupSize]uint64
	dedupIdx := 0

	// FEC decoder — for mode 3
	fecDec := NewFECDecoder(4, mtu+100)

	buf := make([]byte, mtu+200)
	for {
		// syscall.Recvfrom — ZERO heap allocation per packet
		n, from, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			log.Printf("Receiver read error: %v", err)
			continue
		}
		if n < 1 {
			continue
		}

		// Source IP validation — zero allocation (compare [4]byte directly)
		if hasAllowedSrc {
			sa4, ok := from.(*syscall.SockaddrInet4)
			if !ok || sa4.Addr != allowedSrc {
				continue
			}
		}

		pktType := buf[0]
		payload := buf[1:n]

		switch pktType {
		case PktTypeData:
			if len(payload) >= fecHeaderSize+1 {
				// Check if this is a FEC-encoded data packet (has FEC header)
				// FEC packets always have header at start of payload
				groupID, shardIdx, origLen := parseFECHeader(payload)

				if groupID > 0 || shardIdx > 0 || origLen > 0 {
					// FEC mode data packet — extract inner payload after header
					innerPayload := payload[fecHeaderSize:]
					if origLen > 0 && int(origLen) <= len(innerPayload) {
						innerPayload = innerPayload[:origLen]
					}

					// Write to TUN immediately (don't wait for group)
					if len(innerPayload) > 0 {
						_, _ = ifce.Write(innerPayload)
					}

					// Feed to FEC decoder for potential recovery of lost shards
					recovered := fecDec.OnDataShard(groupID, shardIdx, origLen, payload[fecHeaderSize:])
					if recovered != nil && len(recovered) > 0 {
						_, _ = ifce.Write(recovered)
					}
				} else {
					// Non-FEC data packet (mode 1 or 2)
					// Dedup for mode 2
					if len(payload) >= 20 {
						fp := uint64(payload[4])<<40 | uint64(payload[5])<<32 |
							uint64(payload[12])<<24 | uint64(payload[13])<<16 |
							uint64(payload[14])<<8 | uint64(payload[15]) |
							uint64(payload[16])<<56 | uint64(payload[17])<<48

						isDup := false
						for i := 0; i < dedupSize; i++ {
							if dedupRing[i] == fp {
								isDup = true
								break
							}
						}
						if isDup {
							continue
						}
						dedupRing[dedupIdx] = fp
						dedupIdx = (dedupIdx + 1) & (dedupSize - 1)
					}
					_, _ = ifce.Write(payload)
				}
			} else if len(payload) > 0 {
				_, _ = ifce.Write(payload)
			}

		case PktTypeFEC:
			// FEC parity packet — feed to decoder
			if len(payload) > fecHeaderSize {
				groupID, _, _ := parseFECHeader(payload)
				recovered := fecDec.OnParityShard(groupID, payload[fecHeaderSize:])
				if recovered != nil && len(recovered) > 0 {
					_, _ = ifce.Write(recovered)
				}
			}

		case PktTypeHeartbeat:
			_ = pongCtx.buildAndSend(pongPayload)

		case PktTypePong:
			atomic.StoreInt64(&lastPongTime, time.Now().Unix())
		}
	}
}


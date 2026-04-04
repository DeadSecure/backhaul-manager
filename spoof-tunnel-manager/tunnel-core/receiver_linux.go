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

	log.Printf("Receiver on %s:%d (accept from: %s) [zero-alloc mode]", listenIP, listenPort, expectedSrcIP)

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
			if len(payload) > 0 {
				_, _ = ifce.Write(payload)
			}

		case PktTypeHeartbeat:
			_ = pongCtx.buildAndSend(pongPayload)

		case PktTypePong:
			atomic.StoreInt64(&lastPongTime, time.Now().Unix())
		}
	}
}

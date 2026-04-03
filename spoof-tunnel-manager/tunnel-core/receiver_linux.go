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

// StartReceiver listens for incoming UDP, validates source, filters heartbeats, writes data to TUN.
func StartReceiver(ifce *water.Interface, listenIP string, listenPort int, mtu int, expectedSrcIP string, spoofSrcIP string, dstIPStr string, dstPort int) {
	addr := &net.UDPAddr{
		IP:   net.ParseIP(listenIP),
		Port: listenPort,
	}

	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("Receiver: listen %s:%d failed: %v", listenIP, listenPort, err)
	}
	defer conn.Close()
	_ = conn.SetReadBuffer(4 * 1024 * 1024)

	// Source IP we expect (the other side's spoof_src_ip = our spoof_dst_ip)
	var allowedSrc net.IP
	if expectedSrcIP != "" {
		allowedSrc = net.ParseIP(expectedSrcIP).To4()
	}

	// For sending pong replies back via raw socket
	pongSrcIP := net.ParseIP(spoofSrcIP).To4()
	pongDstIP := net.ParseIP(dstIPStr).To4()
	var pongDstMap [4]byte
	copy(pongDstMap[:], pongDstIP)
	pongAddr := &syscall.SockaddrInet4{Port: dstPort, Addr: pongDstMap}

	log.Printf("Receiver on %s:%d (accept from: %s)", listenIP, listenPort, expectedSrcIP)

	buf := make([]byte, mtu+200)
	for {
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("Receiver read error: %v", err)
			continue
		}
		if n < 1 {
			continue
		}

		// === Source IP Validation (anti-injection) ===
		if allowedSrc != nil {
			srcIP := remoteAddr.IP.To4()
			if srcIP != nil && !srcIP.Equal(allowedSrc) {
				continue // Drop garbage from unknown sources
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
			// Reply with pong via raw socket
			pongPayload := []byte{PktTypePong}
			_ = SendSpoofedUDP(pongSrcIP, pongDstIP, listenPort, dstPort, pongPayload, pongAddr)

		case PktTypePong:
			atomic.StoreInt64(&lastPongTime, time.Now().Unix())
		}
	}
}

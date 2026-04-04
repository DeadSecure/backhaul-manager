package main

import (
	"log"
	"net"
	"sync/atomic"
	"syscall"
	"time"
)

// StartHeartbeat sends periodic heartbeat pings and monitors pong responses
// to detect if the tunnel peer is alive.
func StartHeartbeat(dstIPStr string, dstPort int, spoofSrcStr string, srcPort int, intervalSec int, timeoutSec int) {
	dstIP := net.ParseIP(dstIPStr).To4()
	srcIP := net.ParseIP(spoofSrcStr).To4()

	var dstMap [4]byte
	copy(dstMap[:], dstIP)
	dstAddr := &syscall.SockaddrInet4{Port: dstPort, Addr: dstMap}

	ticker := time.NewTicker(time.Duration(intervalSec) * time.Second)
	defer ticker.Stop()

	// Initialize lastPongTime to now (assume alive at start)
	atomic.StoreInt64(&lastPongTime, time.Now().Unix())

	timeoutDuration := int64(timeoutSec)
	peerAlive := true

	log.Printf("Heartbeat: every %ds, timeout %ds -> %s:%d", intervalSec, timeoutSec, dstIPStr, dstPort)

	// Pre-allocate context and payload — zero allocation per tick
	hbCtx := NewSpoofContext(srcIP, dstIP, srcPort, dstPort, 64, dstAddr)
	pingPayload := []byte{PktTypeHeartbeat}

	for range ticker.C {
		// Send heartbeat ping — zero allocation
		_ = hbCtx.buildAndSend(pingPayload)

		// Check if we received a pong recently
		lastPong := atomic.LoadInt64(&lastPongTime)
		elapsed := time.Now().Unix() - lastPong

		if elapsed > timeoutDuration {
			if peerAlive {
				log.Printf("Heartbeat TIMEOUT: no pong from %s for %ds", dstIPStr, elapsed)
				peerAlive = false
			}
		} else {
			if !peerAlive {
				log.Printf("Heartbeat RECOVERED: peer %s is alive again", dstIPStr)
			}
			peerAlive = true
		}
	}
}

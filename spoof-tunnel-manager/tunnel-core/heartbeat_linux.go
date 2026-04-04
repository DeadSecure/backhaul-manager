package main

import (
	"log"
	"net"
	"sync/atomic"
	"syscall"
	"time"
)

// StartHeartbeat sends periodic heartbeat pings and monitors pong responses.
// Gets its own raw socket — completely independent from forwarder/receiver.
func StartHeartbeat(dstIPStr string, dstPort int, spoofSrcStr string, srcPort int, intervalSec int, timeoutSec int, sndbuf int) {
	dstIP := net.ParseIP(dstIPStr).To4()
	srcIP := net.ParseIP(spoofSrcStr).To4()

	var dstMap [4]byte
	copy(dstMap[:], dstIP)
	dstAddr := &syscall.SockaddrInet4{Port: dstPort, Addr: dstMap}

	// Heartbeat gets its own raw socket
	fd, err := CreateRawSocket(sndbuf)
	if err != nil {
		log.Fatalf("Heartbeat: raw socket failed: %v", err)
	}

	ticker := time.NewTicker(time.Duration(intervalSec) * time.Second)
	defer ticker.Stop()

	// Initialize lastPongTime to 0 — we haven't received any pong yet
	atomic.StoreInt64(&lastPongTime, 0)

	timeoutDuration := int64(timeoutSec)
	peerAlive := false
	firstConnect := true

	log.Printf("Heartbeat: every %ds, timeout %ds -> %s:%d (waiting for connection...)", intervalSec, timeoutSec, dstIPStr, dstPort)

	// Pre-allocate context and payload — zero allocation per tick
	hbCtx := NewSpoofContext(srcIP, dstIP, srcPort, dstPort, 64, dstAddr, fd)
	pingPayload := []byte{PktTypeHeartbeat}

	for range ticker.C {
		// Send heartbeat ping — zero allocation
		_ = hbCtx.buildAndSend(pingPayload)

		// Check if we received a pong recently
		lastPong := atomic.LoadInt64(&lastPongTime)

		// No pong ever received
		if lastPong == 0 {
			if !firstConnect {
				continue
			}
			// Still waiting for first connection
			continue
		}

		elapsed := time.Now().Unix() - lastPong

		if elapsed > timeoutDuration {
			if peerAlive {
				log.Printf("!! TUNNEL DISCONNECTED !! No pong from %s for %ds", dstIPStr, elapsed)
				peerAlive = false
			}
		} else {
			if !peerAlive {
				if firstConnect {
					log.Printf("** TUNNEL CONNECTED ** peer %s is reachable (rtt OK)", dstIPStr)
					firstConnect = false
				} else {
					log.Printf("** TUNNEL RECONNECTED ** peer %s is alive again", dstIPStr)
				}
			}
			peerAlive = true
		}
	}
}

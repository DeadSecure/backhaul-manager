package main

import (
	"log"
	"net"
	"syscall"

	"github.com/songgao/water"
)

// StartRelay runs in "relay" mode (Server B):
// - Receives spoofed packets from Kharej on a raw UDP socket
// - Forwards them via regular UDP to Server A (relay_target)
// - No TUN, no heartbeat — pure packet pipe.
//
// This enables split-path tunneling where:
// - Upload goes through Server A (Iran→Kharej spoof works)
// - Download goes through Server B (Kharej→Iran spoof works)
// - Server B relays download to Server A over internal Iran network
func StartRelay(listenIP string, listenPort int, expectedSrcIP string, relayTarget string, mtu int) {
	// ── 1. Create receiver socket (same as normal receiver) ──
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, syscall.IPPROTO_UDP)
	if err != nil {
		log.Fatalf("Relay: socket failed: %v", err)
	}
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)

	listenIPv4 := net.ParseIP(listenIP).To4()
	if listenIPv4 == nil {
		log.Fatalf("Relay: invalid listen IP: %s", listenIP)
	}
	var bindAddr [4]byte
	copy(bindAddr[:], listenIPv4)
	sa := &syscall.SockaddrInet4{Port: listenPort, Addr: bindAddr}
	if err := syscall.Bind(fd, sa); err != nil {
		log.Fatalf("Relay: bind %s:%d failed: %v", listenIP, listenPort, err)
	}

	rcvBuf := 8 * 1024 * 1024
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, rcvBuf)

	// Source IP filter
	var allowedSrc [4]byte
	hasAllowedSrc := false
	if expectedSrcIP != "" {
		srcParsed := net.ParseIP(expectedSrcIP).To4()
		if srcParsed != nil {
			copy(allowedSrc[:], srcParsed)
			hasAllowedSrc = true
		}
	}

	// ── 2. Create relay output socket (regular UDP to Server A) ──
	relayConn, err := net.Dial("udp4", relayTarget)
	if err != nil {
		log.Fatalf("Relay: cannot connect to relay target %s: %v", relayTarget, err)
	}
	defer relayConn.Close()

	log.Printf("Relay: listening on %s:%d (accept from: %s) → forwarding to %s",
		listenIP, listenPort, expectedSrcIP, relayTarget)

	// ── 3. Main loop: receive spoof → forward UDP ──
	buf := make([]byte, mtu+200)
	relayed := uint64(0)
	for {
		n, from, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			log.Printf("Relay read error: %v", err)
			continue
		}
		if n < 2 { // at least 1 byte type + 1 byte data
			continue
		}

		// Source validation
		if hasAllowedSrc {
			sa4, ok := from.(*syscall.SockaddrInet4)
			if !ok || sa4.Addr != allowedSrc {
				continue
			}
		}

		// Forward the ENTIRE packet (including type byte) as-is
		// Server A's relay listener will parse it
		_, _ = relayConn.Write(buf[:n])

		relayed++
		if relayed%100000 == 0 {
			log.Printf("Relay: forwarded %d packets to %s", relayed, relayTarget)
		}
	}
}

// StartRelayListener runs on Server A in split-path mode.
// Listens for regular UDP packets from Server B (relay) and writes to TUN.
// These are download packets that Kharej sent via spoof to Server B.
func StartRelayListener(ifce *water.Interface, port int, mtu int) {
	addr := &net.UDPAddr{IP: net.IPv4zero, Port: port}
	conn, err := net.ListenUDP("udp4", addr)
	if err != nil {
		log.Fatalf("RelayListener: bind :%d failed: %v", port, err)
	}
	defer conn.Close()

	// Large receive buffer
	_ = conn.SetReadBuffer(8 * 1024 * 1024)

	log.Printf("RelayListener: accepting download relay on :%d", port)

	buf := make([]byte, mtu+200)
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("RelayListener read error: %v", err)
			continue
		}
		if n < 2 {
			continue
		}

		// Packet format: [pktType(1)][payload...]
		// Same as what comes through spoof — just forwarded by Server B
		pktType := buf[0]
		payload := buf[1:n]

		switch pktType {
		case PktTypeData, PktTypeFECData, PktTypeRSData:
			// Data packet — extract inner payload and write to TUN
			if pktType == PktTypeFECData || pktType == PktTypeRSData {
				if len(payload) > fecHeaderSize {
					innerPayload := payload[fecHeaderSize:]
					if len(innerPayload) > 0 {
						_, _ = ifce.Write(innerPayload)
					}
				}
			} else {
				if len(payload) > 0 {
					_, _ = ifce.Write(payload)
				}
			}

		case PktTypeFECParity, PktTypeRSParity:
			// Parity packets from relay — currently ignored
			// (FEC decoder on main receiver handles direct packets)
			// For split-path, we'd need a separate decoder here
			// TODO: integrate FEC decoder if needed

		case PktTypeHeartbeat:
			// Ignore heartbeats from relay path

		case PktTypePong:
			// Ignore pongs from relay path
		}
	}
}

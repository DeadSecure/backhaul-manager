package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"sync/atomic"
	"syscall"
)

var (
	rawSocketFD int
	ipIDCounter uint32
)

func InitRawSocket(sndbuf int) error {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
	if err != nil {
		return fmt.Errorf("socket: %v", err)
	}
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		syscall.Close(fd)
		return fmt.Errorf("setsockopt HDRINCL: %v", err)
	}
	bufSize := sndbuf
	if bufSize <= 0 {
		bufSize = 4 * 1024 * 1024
	}
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, bufSize)
	rawSocketFD = fd
	return nil
}

func CloseRawSocket() {
	if rawSocketFD > 0 {
		syscall.Close(rawSocketFD)
	}
}

// SpoofContext holds pre-allocated buffers for zero-allocation packet sending.
// Each worker goroutine MUST have its own SpoofContext.
type SpoofContext struct {
	ipHdr   []byte
	udpHdr  []byte
	pseudo  []byte
	packet  []byte
	srcIP4  []byte
	dstIP4  []byte
	dstAddr *syscall.SockaddrInet4
	srcPort int
	dstPort int
}

func NewSpoofContext(srcIP, dstIP net.IP, srcPort, dstPort, maxPayload int, dstAddr *syscall.SockaddrInet4) *SpoofContext {
	maxTotal := 20 + 8 + maxPayload
	maxPseudo := 12 + 8 + maxPayload + 1
	return &SpoofContext{
		ipHdr:   make([]byte, 20),
		udpHdr:  make([]byte, 8),
		pseudo:  make([]byte, maxPseudo),
		packet:  make([]byte, maxTotal),
		srcIP4:  srcIP.To4(),
		dstIP4:  dstIP.To4(),
		dstAddr: dstAddr,
		srcPort: srcPort,
		dstPort: dstPort,
	}
}

// buildAndSend constructs IP+UDP headers and sends the packet.
// udpPayload is the raw data that goes into the UDP payload area.
// All work is done in pre-allocated buffers — ZERO heap allocation.
func (sc *SpoofContext) buildAndSend(udpPayload []byte) error {
	payloadLen := len(udpPayload)
	udpLen := 8 + payloadLen
	totalLen := 20 + udpLen
	ipID := uint16(atomic.AddUint32(&ipIDCounter, 1) & 0xFFFF)

	// === IP Header ===
	sc.ipHdr[0] = 0x45
	sc.ipHdr[1] = 0
	binary.BigEndian.PutUint16(sc.ipHdr[2:4], uint16(totalLen))
	binary.BigEndian.PutUint16(sc.ipHdr[4:6], ipID)
	binary.BigEndian.PutUint16(sc.ipHdr[6:8], 0x4000) // DF
	sc.ipHdr[8] = 64                                   // TTL
	sc.ipHdr[9] = 17                                   // UDP
	sc.ipHdr[10] = 0
	sc.ipHdr[11] = 0
	copy(sc.ipHdr[12:16], sc.srcIP4)
	copy(sc.ipHdr[16:20], sc.dstIP4)

	// === UDP Header ===
	binary.BigEndian.PutUint16(sc.udpHdr[0:2], uint16(sc.srcPort))
	binary.BigEndian.PutUint16(sc.udpHdr[2:4], uint16(sc.dstPort))
	binary.BigEndian.PutUint16(sc.udpHdr[4:6], uint16(udpLen))
	sc.udpHdr[6] = 0
	sc.udpHdr[7] = 0

	// === UDP Checksum (pseudo-header) ===
	pseudoLen := 12 + udpLen
	if pseudoLen%2 != 0 {
		pseudoLen++
	}
	copy(sc.pseudo[0:4], sc.srcIP4)
	copy(sc.pseudo[4:8], sc.dstIP4)
	sc.pseudo[8] = 0
	sc.pseudo[9] = 17
	binary.BigEndian.PutUint16(sc.pseudo[10:12], uint16(udpLen))
	copy(sc.pseudo[12:20], sc.udpHdr)
	copy(sc.pseudo[20:20+payloadLen], udpPayload)
	if pseudoLen > 20+payloadLen {
		sc.pseudo[20+payloadLen] = 0
	}
	csum := internetChecksum(sc.pseudo[:pseudoLen])
	if csum == 0 {
		csum = 0xFFFF
	}
	binary.BigEndian.PutUint16(sc.udpHdr[6:8], csum)

	// === Assemble ===
	copy(sc.packet[0:20], sc.ipHdr)
	copy(sc.packet[20:28], sc.udpHdr)
	copy(sc.packet[28:28+payloadLen], udpPayload)

	return syscall.Sendto(rawSocketFD, sc.packet[:totalLen], 0, sc.dstAddr)
}

// SendTyped sends [pktType (1 byte)][data] as UDP payload. Zero-alloc.
func (sc *SpoofContext) SendTyped(pktType byte, data []byte) error {
	// Build UDP payload inline in packet buffer: packet[28] = type, packet[29..] = data
	sc.packet[28] = pktType
	copy(sc.packet[29:29+len(data)], data)
	// Point buildAndSend to this region
	return sc.buildAndSend(sc.packet[28 : 28+1+len(data)])
}

// SendSpoofedUDP is the allocating version for low-frequency use (heartbeat/pong).
func SendSpoofedUDP(srcIP, dstIP net.IP, srcPort, dstPort int, payload []byte, dstAddr *syscall.SockaddrInet4) error {
	ctx := NewSpoofContext(srcIP, dstIP, srcPort, dstPort, len(payload)+64, dstAddr)
	return ctx.buildAndSend(payload)
}

func internetChecksum(data []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(data); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(data[i : i+2]))
	}
	if len(data)%2 == 1 {
		sum += uint32(data[len(data)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xFFFF) + (sum >> 16)
	}
	return ^uint16(sum)
}

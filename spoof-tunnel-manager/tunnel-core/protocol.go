package main

// Packet type prefixes for the tunnel protocol.
// Every UDP payload starts with one of these bytes.
const (
	PktTypeData      byte = 0x01 // Normal TUN packet (mode 1 or 2)
	PktTypeHeartbeat byte = 0x02 // Heartbeat ping
	PktTypePong      byte = 0x03 // Heartbeat pong (ACK)
	PktTypeFECParity byte = 0x04 // FEC parity packet (mode 3)
	PktTypeFECData   byte = 0x05 // FEC encoded data packet (mode 3)
)

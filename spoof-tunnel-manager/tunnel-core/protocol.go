package main

// Packet type prefixes for the tunnel protocol.
// Every UDP payload starts with one of these bytes.
const (
	PktTypeData      byte = 0x01 // TUN packet encapsulated in UDP
	PktTypeHeartbeat byte = 0x02 // Heartbeat ping
	PktTypePong      byte = 0x03 // Heartbeat pong (ACK)
)

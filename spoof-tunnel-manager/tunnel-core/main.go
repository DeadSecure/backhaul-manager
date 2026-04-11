package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"syscall"
)

func main() {
	configFile := flag.String("config", "", "Path to the TOML config file")
	flag.Parse()

	if *configFile == "" {
		log.Fatal("Usage: spoof-tunnel-core --config /path/to/config.toml")
	}

	cfg, err := ParseConfig(*configFile)
	if err != nil {
		log.Fatalf("Config error: %v", err)
	}

	// ── 0. Memory controls ── prevent unbounded heap growth
	debug.SetGCPercent(100)                       // Default GC — no need to be aggressive with zero-alloc
	debug.SetMemoryLimit(256 * 1024 * 1024)        // Hard cap at 256MB

	// ── 1. Apply kernel tuning for high throughput ──
	ApplyKernelTuning()

	// ── 2. Setup TUN Interface ──
	tunIfce, err := SetupTun(cfg.Tun.Name, cfg.Tun.LocalAddr, cfg.Tun.RemoteAddr, cfg.Tun.Mtu)
	if err != nil {
		log.Fatalf("TUN setup failed: %v", err)
	}

	// Increase TUN queue length for burst absorption
	SetTunQueueLen(cfg.Tun.Name, 5000)

	// ── 3. Graceful Shutdown ──
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down...")
		tunIfce.Close()
		os.Exit(0)
	}()

	// ── 4. Config values ──
	workers := cfg.Tuning.Workers
	if workers <= 0 {
		workers = runtime.NumCPU()
		if workers < 2 {
			workers = 2
		}
	}
	tunnelPort := cfg.Tun.HealthPort
	hbInterval := cfg.Transport.HeartbeatInterval
	if hbInterval <= 0 {
		hbInterval = 10
	}
	hbTimeout := cfg.Transport.HeartbeatTimeout
	if hbTimeout <= 0 {
		hbTimeout = 25
	}
	sndbuf := cfg.Tuning.SoSndbuf
	if sndbuf <= 0 {
		sndbuf = 4 * 1024 * 1024
	}
	multiply := cfg.Tuning.PacketMultiply
	if multiply <= 0 {
		multiply = 1
	}
	if multiply > 4 {
		multiply = 4 // cap at 4 (RS FEC)
	}

	log.Printf("══════════════════════════════════════════════════")
	log.Printf("  Spoof Tunnel Core v2.1 [per-worker FD, zero-alloc]")
	log.Printf("  Mode:       %s", cfg.Ipx.Mode)
	log.Printf("  TUN:        %s (%s <-> %s)", cfg.Tun.Name, cfg.Tun.LocalAddr, cfg.Tun.RemoteAddr)
	log.Printf("  Listen:     %s:%d", cfg.Ipx.ListenIP, tunnelPort)
	log.Printf("  Dest:       %s:%d", cfg.Ipx.DstIP, tunnelPort)
	log.Printf("  Spoof Src:  %s", cfg.Ipx.SpoofSrcIP)
	log.Printf("  Spoof Dst:  %s (expected incoming src)", cfg.Ipx.SpoofDstIP)
	log.Printf("  Workers:    %d (each with own raw socket)", workers)
	log.Printf("  MTU:        %d", cfg.Tun.Mtu)
	log.Printf("  Heartbeat:  %ds interval, %ds timeout", hbInterval, hbTimeout)
	switch multiply {
	case 2:
		log.Printf("  Anti-Loss:  x2 packet duplication ENABLED")
	case 3:
		log.Printf("  Anti-Loss:  XOR FEC mode (4 data + 1 parity, 25%% overhead)")
	case 4:
		log.Printf("  Anti-Loss:  RS FEC mode (4 data + 2 parity, 50%% overhead)")
	}
	log.Printf("══════════════════════════════════════════════════")

	// ── 5. Start Receiver (own raw socket for pong) ──
	go StartReceiver(tunIfce, cfg.Ipx.ListenIP, tunnelPort, cfg.Tun.Mtu,
		cfg.Ipx.SpoofDstIP, cfg.Ipx.SpoofSrcIP, cfg.Ipx.DstIP, tunnelPort, sndbuf)

	// ── 6. Start Heartbeat (own raw socket) ──
	go StartHeartbeat(cfg.Ipx.DstIP, tunnelPort, cfg.Ipx.SpoofSrcIP, tunnelPort, hbInterval, hbTimeout, sndbuf)

	// ── 7. Start Forwarder (per-worker raw sockets, blocking) ──
	StartForwarder(tunIfce, cfg.Ipx.DstIP, tunnelPort, cfg.Ipx.SpoofSrcIP, tunnelPort, workers, cfg.Tun.Mtu, cfg.Tuning.ChannelSize, sndbuf, multiply)
}

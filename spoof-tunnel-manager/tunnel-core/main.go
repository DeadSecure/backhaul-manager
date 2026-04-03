package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"runtime"
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

	// ── 1. Init Raw Socket ──
	if err := InitRawSocket(cfg.Tuning.SoSndbuf); err != nil {
		log.Fatalf("Raw socket init failed: %v", err)
	}
	defer CloseRawSocket()

	// ── 2. Setup TUN Interface ──
	tunIfce, err := SetupTun(cfg.Tun.Name, cfg.Tun.LocalAddr, cfg.Tun.RemoteAddr, cfg.Tun.Mtu)
	if err != nil {
		log.Fatalf("TUN setup failed: %v", err)
	}

	// NOTE: No iptables needed! We use SOCK_RAW + IP_HDRINCL which constructs
	// the entire IP header manually. The kernel sends our packet as-is,
	// bypassing netfilter POSTROUTING. SNAT is already baked into the raw header.

	// ── 3. Graceful Shutdown ──
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down...")
		tunIfce.Close()
		CloseRawSocket()
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

	log.Printf("══════════════════════════════════════════════════")
	log.Printf("  Spoof Tunnel Core")
	log.Printf("  Mode:       %s", cfg.Ipx.Mode)
	log.Printf("  TUN:        %s (%s <-> %s)", cfg.Tun.Name, cfg.Tun.LocalAddr, cfg.Tun.RemoteAddr)
	log.Printf("  Listen:     %s:%d", cfg.Ipx.ListenIP, tunnelPort)
	log.Printf("  Dest:       %s:%d", cfg.Ipx.DstIP, tunnelPort)
	log.Printf("  Spoof Src:  %s", cfg.Ipx.SpoofSrcIP)
	log.Printf("  Spoof Dst:  %s (expected incoming src)", cfg.Ipx.SpoofDstIP)
	log.Printf("  Workers:    %d", workers)
	log.Printf("  MTU:        %d", cfg.Tun.Mtu)
	log.Printf("  Heartbeat:  %ds interval, %ds timeout", hbInterval, hbTimeout)
	log.Printf("══════════════════════════════════════════════════")

	// ── 5. Start Receiver ──
	go StartReceiver(tunIfce, cfg.Ipx.ListenIP, tunnelPort, cfg.Tun.Mtu,
		cfg.Ipx.SpoofDstIP, cfg.Ipx.SpoofSrcIP, cfg.Ipx.DstIP, tunnelPort)

	// ── 6. Start Heartbeat ──
	go StartHeartbeat(cfg.Ipx.DstIP, tunnelPort, cfg.Ipx.SpoofSrcIP, tunnelPort, hbInterval, hbTimeout)

	// ── 7. Start Forwarder (blocking) ──
	StartForwarder(tunIfce, cfg.Ipx.DstIP, tunnelPort, cfg.Ipx.SpoofSrcIP, tunnelPort, workers, cfg.Tun.Mtu, cfg.Tuning.ChannelSize)
}

package main

import (
	"fmt"
	"log"
	"os/exec"
	"strings"

	"github.com/songgao/water"
)

// SetupTun creates a TUN interface, assigns IP, sets MTU, and brings it up.
func SetupTun(name string, localCIDR string, remoteCIDR string, mtu int) (*water.Interface, error) {
	config := water.Config{
		DeviceType: water.TUN,
	}
	config.Name = name

	ifce, err := water.New(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create TUN %s: %v", name, err)
	}
	log.Printf("TUN interface %s created", ifce.Name())

	localIP := strings.Split(localCIDR, "/")[0]
	mask := "24"
	if parts := strings.Split(localCIDR, "/"); len(parts) == 2 {
		mask = parts[1]
	}

	// Assign IP
	if out, err := exec.Command("ip", "addr", "add", localIP+"/"+mask, "dev", ifce.Name()).CombinedOutput(); err != nil {
		log.Printf("Warning: ip addr add failed: %s (%v)", string(out), err)
	}

	// Set MTU and bring up
	mtuStr := fmt.Sprintf("%d", mtu)
	if out, err := exec.Command("ip", "link", "set", "dev", ifce.Name(), "up", "mtu", mtuStr).CombinedOutput(); err != nil {
		log.Printf("Warning: ip link set failed: %s (%v)", string(out), err)
	}

	remoteIP := strings.Split(remoteCIDR, "/")[0]
	log.Printf("TUN %s up: local=%s remote=%s mtu=%d", ifce.Name(), localIP, remoteIP, mtu)
	return ifce, nil
}

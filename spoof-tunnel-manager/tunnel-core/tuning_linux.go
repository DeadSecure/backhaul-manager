package main

import (
	"log"
	"os"
	"os/exec"
	"syscall"
)

// ApplyKernelTuning sets critical sysctl parameters for high-throughput tunneling.
// These are applied at runtime — no persistent changes to /etc/sysctl.conf.
func ApplyKernelTuning() {
	tunings := map[string]string{
		// Socket buffer limits (backhaul uses 256MB, we try 128MB first)
		"net.core.rmem_max":     "134217728",
		"net.core.wmem_max":     "134217728",
		"net.core.rmem_default": "1048576",
		"net.core.wmem_default": "1048576",

		// Network queue depth — absorb bursts without drops
		"net.core.netdev_max_backlog": "50000",
		"net.core.somaxconn":          "65536",

		// TCP memory and performance
		"net.ipv4.tcp_rmem":                  "4096 1048576 16777216",
		"net.ipv4.tcp_wmem":                  "4096 1048576 16777216",
		"net.ipv4.tcp_congestion_control":    "bbr",
		"net.ipv4.tcp_fastopen":              "3",
		"net.ipv4.tcp_slow_start_after_idle": "0",
		"net.ipv4.tcp_mtu_probing":           "1",
		"net.ipv4.tcp_notsent_lowat":         "16384",
		"net.ipv4.tcp_window_scaling":        "1",

		// Connection recycling (from backhaul)
		"net.ipv4.tcp_tw_reuse":       "1",
		"net.ipv4.tcp_fin_timeout":    "15",
		"net.ipv4.tcp_max_syn_backlog": "20480",
		"net.ipv4.ip_local_port_range": "1024 65535",

		// UDP buffers
		"net.ipv4.udp_rmem_min": "8192",
		"net.ipv4.udp_wmem_min": "8192",

		// Disable reverse path filtering (required for spoofed packets)
		"net.ipv4.conf.all.rp_filter":     "0",
		"net.ipv4.conf.default.rp_filter": "0",
	}

	applied := 0
	for key, val := range tunings {
		path := "/proc/sys/" + sysToPath(key)
		if err := os.WriteFile(path, []byte(val), 0644); err == nil {
			applied++
		}
	}

	// Increase file descriptor limit (like backhaul: 1048576)
	var rLimit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &rLimit); err == nil {
		rLimit.Max = 1048576
		rLimit.Cur = 1048576
		if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &rLimit); err == nil {
			applied++
		}
	}

	log.Printf("Kernel tuning: %d params applied (rmem/wmem=128MB, BBR, fd=1M)", applied)
}

// sysToPath converts "net.core.rmem_max" to "net/core/rmem_max"
func sysToPath(key string) string {
	result := make([]byte, len(key))
	for i := 0; i < len(key); i++ {
		if key[i] == '.' {
			result[i] = '/'
		} else {
			result[i] = key[i]
		}
	}
	return string(result)
}

// SetTunQueueLen increases the TUN interface transmit queue length.
// Default is 500, but under high load this causes drops.
func SetTunQueueLen(tunName string, qlen int) {
	cmd := exec.Command("ip", "link", "set", "dev", tunName, "txqueuelen", itoa(qlen))
	if out, err := cmd.CombinedOutput(); err != nil {
		log.Printf("Warning: set txqueuelen failed: %s (%v)", string(out), err)
	} else {
		log.Printf("TUN %s txqueuelen set to %d", tunName, qlen)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	buf := [20]byte{}
	pos := len(buf)
	for n > 0 {
		pos--
		buf[pos] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[pos:])
}

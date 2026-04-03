package main

import (
	"fmt"
	"log"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Transport TransportConfig `toml:"transport"`
	Tun       TunConfig       `toml:"tun"`
	Ipx       IpxConfig       `toml:"ipx"`
	Security  SecurityConfig  `toml:"security"`
	Tuning    TuningConfig    `toml:"tuning"`
	Logging   LoggingConfig   `toml:"logging"`
}

type TransportConfig struct {
	Type              string `toml:"type"`
	HeartbeatInterval int    `toml:"heartbeat_interval"`
	HeartbeatTimeout  int    `toml:"heartbeat_timeout"`
}

type TunConfig struct {
	Encapsulation string `toml:"encapsulation"`
	Name          string `toml:"name"`
	LocalAddr     string `toml:"local_addr"`
	RemoteAddr    string `toml:"remote_addr"`
	HealthPort    int    `toml:"health_port"`
	Mtu           int    `toml:"mtu"`
}

type IpxConfig struct {
	Mode       string `toml:"mode"`
	Profile    string `toml:"profile"`
	ListenIP   string `toml:"listen_ip"`
	DstIP      string `toml:"dst_ip"`
	SpoofSrcIP string `toml:"spoof_src_ip"`
	SpoofDstIP string `toml:"spoof_dst_ip"`
	Interface  string `toml:"interface"`
}

type SecurityConfig struct {
	EnableEncryption bool   `toml:"enable_encryption"`
	Algorithm        string `toml:"algorithm"`
	Psk              string `toml:"psk"`
	KdfIterations    int    `toml:"kdf_iterations"`
}

type TuningConfig struct {
	AutoTuning    bool   `toml:"auto_tuning"`
	TuningProfile string `toml:"tuning_profile"`
	Workers       int    `toml:"workers"`
	ChannelSize   int    `toml:"channel_size"`
	SoSndbuf      int    `toml:"so_sndbuf"`
	BatchSize     int    `toml:"batch_size"`
}

type LoggingConfig struct {
	LogLevel string `toml:"log_level"`
}

func ParseConfig(path string) (*Config, error) {
	var config Config
	if _, err := toml.DecodeFile(path, &config); err != nil {
		return nil, err
	}

	// Validate required fields
	if config.Ipx.ListenIP == "" || config.Ipx.DstIP == "" || config.Ipx.SpoofSrcIP == "" || config.Ipx.SpoofDstIP == "" {
		return nil, fmt.Errorf("ipx: listen_ip, dst_ip, spoof_src_ip, spoof_dst_ip are all required")
	}
	if config.Ipx.Mode != "server" && config.Ipx.Mode != "client" {
		return nil, fmt.Errorf("ipx.mode must be 'server' or 'client'")
	}
	if config.Tun.HealthPort == 0 {
		config.Tun.HealthPort = 4096
	}
	if config.Tun.Mtu == 0 {
		config.Tun.Mtu = 1320
	}

	log.Printf("Config loaded: mode=%s listen=%s dst=%s spoofSrc=%s spoofDst=%s port=%d",
		config.Ipx.Mode, config.Ipx.ListenIP, config.Ipx.DstIP,
		config.Ipx.SpoofSrcIP, config.Ipx.SpoofDstIP, config.Tun.HealthPort)
	return &config, nil
}

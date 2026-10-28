package main

import (
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/listener"
	"net"
	"strconv"
	"testing"
)

func TestStartListenerReportsMixedConflictAndRecovers(t *testing.T) {
	savedConfig, savedRunning := currentConfig, isRunning
	handleStopListener()
	t.Cleanup(func() { handleStopListener(); currentConfig = savedConfig; isRunning = savedRunning })
	block, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer block.Close()
	port := block.Addr().(*net.TCPAddr).Port
	currentConfig = &config.Config{General: &config.General{}}
	currentConfig.General.MixedPort = port
	currentConfig.General.BindAddress = "127.0.0.1"
	if handleStartListener() {
		t.Fatal("conflicting mixed listener returned success")
	}
	if isRunning {
		t.Fatal("failed start left running flag true")
	}
	block.Close()
	if !handleStartListener() {
		t.Fatal("start failed after port released")
	}
	if !isRunning {
		t.Fatal("successful start left running flag false")
	}
	handleStopListener()
	tcp, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	tcp.Close()
	listener.StopListener()
}
func TestStartListenerWithoutConfigFails(t *testing.T) {
	savedConfig, savedRunning := currentConfig, isRunning
	handleStopListener()
	currentConfig = nil
	t.Cleanup(func() { handleStopListener(); currentConfig = savedConfig; isRunning = savedRunning })
	if handleStartListener() || isRunning {
		t.Fatal("no configuration reported running")
	}
}

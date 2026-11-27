//go:build linux

// Command nplab drives the bridge's packet path end to end on Linux for tests and benchmarks.
//
// It is a lab tool, not part of the shipped bridge. Every subcommand that touches interfaces is meant to run
// inside a dedicated network namespace created by Cores/BuildScripts/bridge-tunlab.sh; nplab itself never
// creates namespaces, routes or firewall rules.
//
//	nplab bridge  ...   run the engine on a kernel tun device (mode flow: host pump like NEPacketTunnelFlow;
//	                    mode fd: the core reads the device itself)
//	nplab tunexec ...   open a tun device, export its fd as xray.tun.fd and exec a program (stock xray)
//	nplab target  ...   echo / discard / source / DNS / TLS servers on the far side of the proxy
//	nplab client  ...   traffic generator and measurement, prints one JSON object per test
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	args := os.Args[2:]
	var err error
	switch os.Args[1] {
	case "bridge":
		err = runBridge(args)
	case "tunexec":
		err = runTunExec(args)
	case "target":
		err = runTarget(args)
	case "client":
		err = runClient(args)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "nplab:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: nplab bridge|tunexec|target|client [flags]")
	os.Exit(2)
}

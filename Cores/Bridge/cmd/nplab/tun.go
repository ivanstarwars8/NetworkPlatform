//go:build linux

package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

// openTun attaches to the tun device name (creating it if it does not exist) as IFF_TUN|IFF_NO_PI: one
// read or write is exactly one IP packet, as with NEPacketTunnelFlow. cloexec=false keeps the descriptor
// across exec (tunexec).
func openTun(name string, cloexec bool) (int, error) {
	flags := unix.O_RDWR
	if cloexec {
		flags |= unix.O_CLOEXEC
	}
	fd, err := unix.Open("/dev/net/tun", flags, 0)
	if err != nil {
		return -1, err
	}
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		unix.Close(fd)
		return -1, err
	}
	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(fd, unix.TUNSETIFF, ifr); err != nil {
		unix.Close(fd)
		return -1, fmt.Errorf("TUNSETIFF %s: %w", name, err)
	}
	return fd, nil
}

// runTunExec opens the tun device and execs the given program with xray.tun.fd pointing at it, so that the
// stock xray binary reads the same pre-configured device the bridge uses (the core's fd path).
func runTunExec(args []string) error {
	fs := flag.NewFlagSet("tunexec", flag.ExitOnError)
	name := fs.String("tun", "nptun0", "tun device")
	_ = fs.Parse(args)
	if fs.NArg() == 0 {
		return fmt.Errorf("tunexec: no program")
	}
	fd, err := openTun(*name, false)
	if err != nil {
		return err
	}
	prog, err := exec.LookPath(fs.Arg(0))
	if err != nil {
		return err
	}
	env := append(os.Environ(), "xray.tun.fd="+strconv.Itoa(fd))
	return syscall.Exec(prog, fs.Args(), env)
}

// packetInfo is what the pump learns from an IP header without copying it.
type packetInfo struct {
	version  int
	dst      netip.Addr
	fragment bool // IPv4 MF/offset set, or an IPv6 fragment header right after the fixed header
	df       bool // IPv4 don't-fragment
}

func inspect(p []byte) (pi packetInfo, ok bool) {
	if len(p) < 1 {
		return pi, false
	}
	switch p[0] >> 4 {
	case 4:
		if len(p) < 20 {
			return pi, false
		}
		pi.version = 4
		pi.dst = netip.AddrFrom4([4]byte(p[16:20]))
		ff := binary.BigEndian.Uint16(p[6:8])
		pi.df = ff&0x4000 != 0
		pi.fragment = ff&0x2000 != 0 || ff&0x1fff != 0
		return pi, true
	case 6:
		if len(p) < 40 {
			return pi, false
		}
		pi.version = 6
		pi.dst = netip.AddrFrom16([16]byte(p[24:40]))
		pi.fragment = p[6] == 44
		return pi, true
	}
	return pi, false
}

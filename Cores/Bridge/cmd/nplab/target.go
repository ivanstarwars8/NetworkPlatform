//go:build linux

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Target ports. They are fixed so that the scripts and the docs can name them.
const (
	portEcho    = 7    // TCP and UDP echo
	portDiscard = 9    // TCP: read until EOF, answer with the byte count (8 bytes BE), close (needs half-close)
	portSink    = 10   // TCP: read an 8-byte BE count, then that many bytes, answer with the count, close
	portSource  = 19   // TCP: read an 8-byte BE count, send that many bytes, close
	portDNS     = 53   // UDP DNS (reached through the core's dns outbound in the lab config)
	portDNSRaw  = 5353 // UDP DNS (plain UDP forwarding through the proxy)
	portTLS     = 8443 // TLS 1.3 server, the REALITY target of the lab server
)

func runTarget(args []string) error {
	fs := flag.NewFlagSet("target", flag.ExitOnError)
	addrs := fs.String("addrs", "0.0.0.0,::", "comma list of listen addresses")
	tlsAddr := fs.String("tls", "127.0.0.1:8443", "TLS listener (REALITY target); empty disables")
	answer4 := fs.String("dns-a", "198.18.0.10", "A answer for names under np.test")
	answer6 := fs.String("dns-aaaa", "2001:db8:1::10", "AAAA answer for names under np.test")
	_ = fs.Parse(args)

	a4, err := netip.ParseAddr(*answer4)
	if err != nil {
		return err
	}
	a6, err := netip.ParseAddr(*answer6)
	if err != nil {
		return err
	}
	for _, a := range strings.Split(*addrs, ",") {
		a = strings.TrimSpace(a)
		network := "4"
		if strings.Contains(a, ":") {
			network = "6"
		}
		for port, h := range map[int]func(net.Conn){portEcho: tcpEcho, portDiscard: tcpDiscard, portSink: tcpSink, portSource: tcpSource} {
			l, err := net.Listen("tcp"+network, net.JoinHostPort(a, fmt.Sprint(port)))
			if err != nil {
				return err
			}
			go serveTCP(l, h)
		}
		u, err := net.ListenPacket("udp"+network, net.JoinHostPort(a, fmt.Sprint(portEcho)))
		if err != nil {
			return err
		}
		go udpEcho(u)
		for _, port := range []int{portDNS, portDNSRaw} {
			d, err := net.ListenPacket("udp"+network, net.JoinHostPort(a, fmt.Sprint(port)))
			if err != nil {
				return err
			}
			go dnsServe(d, a4, a6)
		}
	}
	if *tlsAddr != "" {
		cfg, err := selfSignedTLS()
		if err != nil {
			return err
		}
		l, err := tls.Listen("tcp", *tlsAddr, cfg)
		if err != nil {
			return err
		}
		go serveTCP(l, func(c net.Conn) {
			_ = c.SetDeadline(time.Now().Add(10 * time.Second))
			_, _ = io.Copy(io.Discard, c)
		})
	}
	fmt.Println(`{"ready":true}`)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	return nil
}

func serveTCP(l net.Listener, h func(net.Conn)) {
	for {
		c, err := l.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			h(c)
		}()
	}
}

func tcpEcho(c net.Conn) { _, _ = io.Copy(c, c) }

func tcpDiscard(c net.Conn) {
	n, _ := io.Copy(io.Discard, c)
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(n))
	_, _ = c.Write(b[:])
}

func tcpSink(c net.Conn) {
	var b [8]byte
	if _, err := io.ReadFull(c, b[:]); err != nil {
		return
	}
	want := int64(binary.BigEndian.Uint64(b[:]))
	n, _ := io.CopyN(io.Discard, c, want)
	binary.BigEndian.PutUint64(b[:], uint64(n))
	_, _ = c.Write(b[:])
}

func tcpSource(c net.Conn) {
	var b [8]byte
	if _, err := io.ReadFull(c, b[:]); err != nil {
		return
	}
	left := int64(binary.BigEndian.Uint64(b[:]))
	chunk := make([]byte, 128<<10)
	for left > 0 {
		n := int64(len(chunk))
		if left < n {
			n = left
		}
		if _, err := c.Write(chunk[:n]); err != nil {
			return
		}
		left -= n
	}
}

func udpEcho(c net.PacketConn) {
	buf := make([]byte, 65536)
	for {
		n, from, err := c.ReadFrom(buf)
		if err != nil {
			return
		}
		_, _ = c.WriteTo(buf[:n], from)
	}
}

// dnsServe answers A/AAAA for every name under np.test. with fixed addresses and NXDOMAIN otherwise.
func dnsServe(c net.PacketConn, a4, a6 netip.Addr) {
	buf := make([]byte, 1500)
	for {
		n, from, err := c.ReadFrom(buf)
		if err != nil {
			return
		}
		var p dnsmessage.Parser
		h, err := p.Start(buf[:n])
		if err != nil {
			continue
		}
		q, err := p.Question()
		if err != nil {
			continue
		}
		rh := dnsmessage.Header{ID: h.ID, Response: true, Authoritative: true, RecursionDesired: h.RecursionDesired}
		name := strings.ToLower(q.Name.String())
		inZone := name == "np.test." || strings.HasSuffix(name, ".np.test.")
		if !inZone {
			rh.RCode = dnsmessage.RCodeNameError
		}
		b := dnsmessage.NewBuilder(make([]byte, 0, 512), rh)
		b.EnableCompression()
		_ = b.StartQuestions()
		_ = b.Question(q)
		_ = b.StartAnswers()
		if inZone {
			res := dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: 60}
			switch q.Type {
			case dnsmessage.TypeA:
				_ = b.AResource(res, dnsmessage.AResource{A: a4.As4()})
			case dnsmessage.TypeAAAA:
				_ = b.AAAAResource(res, dnsmessage.AAAAResource{AAAA: a6.As16()})
			}
		}
		out, err := b.Finish()
		if err != nil {
			continue
		}
		_, _ = c.WriteTo(out, from)
	}
}

func selfSignedTLS() (*tls.Config, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "np.test"},
		DNSNames:     []string{"np.test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{"h2", "http/1.1"},
	}, nil
}

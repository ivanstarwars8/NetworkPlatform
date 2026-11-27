package engine

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/listener/sing_tun"
	mlog "github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing/common"
	M "github.com/metacubex/sing/common/metadata"
)

// TunCounters describe the packet interface of TunFlow mode. Same fields as the Xray bridge, plus
// RxOversize.
type TunCounters struct {
	// Host -> core.
	RxPackets   uint64 `json:"rxPackets"`
	RxBytes     uint64 `json:"rxBytes"`
	RxMalformed uint64 `json:"rxMalformed"` // batches cut short by a bad frame
	RxNoStack   uint64 `json:"rxNoStack"`   // packets that arrived while no stack was attached
	RxOversize  uint64 `json:"rxOversize"`  // packets larger than the MTU, dropped
	RxDropped   uint64 `json:"rxDropped"`   // inbound queue full: the stack did not keep up
	// RxQueueHighest is the high-water mark of the inbound queue in bytes.
	RxQueueHighest int `json:"rxQueueHighest"`
	// Core -> host.
	TxPackets      uint64 `json:"txPackets"`
	TxBytes        uint64 `json:"txBytes"`
	TxDropped      uint64 `json:"txDropped"`      // tail drops: the host did not read fast enough
	TxQueueHighest int    `json:"txQueueHighest"` // high-water mark of the queue in bytes
	TxQueueBytes   int    `json:"txQueueBytes"`   // capacity
	// TCP connections handed to the core (tun.maxFlows counts these; UDP is not capped, see TunOptions).
	FlowsActive   int64  `json:"flowsActive"`
	FlowsHighest  int64  `json:"flowsHighest"`
	FlowsRejected uint64 `json:"flowsRejected"` // closed at once because tun.maxFlows was reached
}

// How packets reach the core without a utun descriptor
//
// sing-tun's Mipstack (stack_mipstack.go) accepts any tun.Tun, an io.ReadWriter plus Close. For a device
// that is none of LinuxTUN/WinTun/DarwinTUN its readLoop calls device.Read(buf) once per packet (buf sized to
// the MTU, no family header) and hands each packet to mipstack, and its writeLoop calls device.Write(packet)
// once per packet. The batched interfaces (LinuxTUN.BatchRead, DarwinTUN.BatchRead) are not used: LinuxTUN
// batching requires front headroom, which makes writeLoop reserve 64 KiB of GRO capacity for each of the 64
// output buffers (4 MiB), and DarwinTUN batching is selected by the recvmsgx option this bridge keeps off.
//
// flowDevice is that plain tun.Tun with a bounded packetQueue in each direction; the host side stays batched:
//
//   - TunWrite validates the frames of a batch and copies each packet into the inbound queue, then returns;
//     the stack's reader goroutine pops one packet per Read. A full queue drops the packet (counted as
//     rxDropped), which TCP treats as loss — the same policy as the outbound queue.
//   - Write (core -> host) appends to the outbound queue that TunRead drains in batches, as in the Xray bridge.
//
// A first version handed the batch to the reader goroutine synchronously (TunWrite waited until the stack had
// copied every packet: no inbound queue, natural backpressure). Through the C ABI that cost ~48 us per call
// whatever the batch size (cabi/ctest, dev server, 2026-11-27): every call parked and woke the C caller's
// thread. Hence the queue.
type flowDevice struct {
	mtu int
	in  *packetQueue // host -> stack
	out *packetQueue // stack -> host

	closed chan struct{}
	once   sync.Once

	attached atomic.Bool

	rxMalformed, rxNoStack, rxOversize atomic.Uint64

	maxFlows                  int64 // 0 = no cap
	flowsActive, flowsHighest atomic.Int64
	flowsRejected             atomic.Uint64
}

func newFlowDevice(mtu, inQueueBytes, outQueueBytes, maxFlows int) *flowDevice {
	return &flowDevice{
		mtu: mtu, in: newPacketQueue(inQueueBytes), out: newPacketQueue(outQueueBytes),
		closed: make(chan struct{}), maxFlows: int64(maxFlows),
	}
}

// acquireFlow admits one TCP connection unless tun.maxFlows is reached. Every admitted one is released with
// releaseFlow. Same accounting as the Xray bridge.
func (d *flowDevice) acquireFlow() bool {
	n := d.flowsActive.Add(1)
	if d.maxFlows > 0 && n > d.maxFlows {
		d.flowsActive.Add(-1)
		d.flowsRejected.Add(1)
		return false
	}
	for {
		old := d.flowsHighest.Load()
		if n <= old || d.flowsHighest.CompareAndSwap(old, n) {
			return true
		}
	}
}

func (d *flowDevice) releaseFlow() { d.flowsActive.Add(-1) }

// cappedHandler is the core's TUN handler with tun.maxFlows applied to TCP. The stack calls NewConnection on a
// goroutine of its own per accepted connection, and the call returns when the core is done with it.
type cappedHandler struct {
	*sing_tun.ListenerHandler
	device *flowDevice
}

func (h cappedHandler) NewConnection(ctx context.Context, conn net.Conn, metadata M.Metadata) error {
	if !h.device.acquireFlow() {
		return conn.Close()
	}
	defer h.device.releaseFlow()
	return h.ListenerHandler.NewConnection(ctx, conn, metadata)
}

var _ tun.Tun = (*flowDevice)(nil)

// Read implements io.Reader for the stack's readLoop: one IP packet per call, blocking until one is queued or
// the device closes (io.EOF ends the loop).
func (d *flowDevice) Read(p []byte) (int, error) {
	for {
		n, ok := d.in.readOne(p)
		if !ok {
			return 0, io.EOF
		}
		if n >= 0 {
			return n, nil
		}
		// cannot happen: writeBatch drops packets larger than the MTU, and the reader's buffer is MTU-sized
		d.rxOversize.Add(1)
	}
}

// readOne pops one packet into dst, waiting until one is queued; ok is false once the queue is closed.
// n is -1 if the packet did not fit dst (it is dropped). Single consumer only.
func (q *packetQueue) readOne(dst []byte) (n int, ok bool) {
	for {
		q.mu.Lock()
		if q.used > 0 {
			var h [frameHeaderSize]byte
			q.get(q.r, h[:])
			size := int(binary.LittleEndian.Uint16(h[:]))
			n = -1
			if size <= len(dst) {
				q.get(q.r+frameHeaderSize, dst[:size])
				n = size
			}
			q.r = (q.r + frameHeaderSize + size) % len(q.buf)
			q.used -= frameHeaderSize + size
			q.mu.Unlock()
			return n, true
		}
		closed := q.closed
		q.mu.Unlock()
		if closed {
			return 0, false
		}
		<-q.notify // signalled by push on empty -> non-empty, and by close
	}
}

// Write implements io.Writer for the stack's writeLoop. It never blocks; an overflowing queue drops the packet.
func (d *flowDevice) Write(p []byte) (int, error) {
	select {
	case <-d.closed:
		return 0, io.ErrClosedPipe
	default:
	}
	d.out.push(nil, p)
	return len(p), nil
}

// Close wakes the stack's reader and a waiting TunRead.
func (d *flowDevice) Close() error {
	d.once.Do(func() {
		close(d.closed)
		d.in.close()
		d.out.close()
	})
	return nil
}

// writeBatch is TunWrite: it queues every packet of batch and returns the number of frames consumed (queued,
// dropped as oversized, or dropped because the queue is full). The batch is not retained or modified.
func (d *flowDevice) writeBatch(batch []byte) (int, *Error) {
	select {
	case <-d.closed:
		return 0, newError(CodeClosed, "packet device closed")
	default:
	}
	attached := d.attached.Load()
	packets := 0
	var err *Error
	for len(batch) > 0 {
		if len(batch) < frameHeaderSize {
			err = newError(CodeInvalidArgument, "truncated frame header")
			break
		}
		size := int(binary.LittleEndian.Uint16(batch))
		if size == 0 || size > len(batch)-frameHeaderSize {
			err = newError(CodeInvalidArgument, "frame of %d bytes in %d remaining", size, len(batch)-frameHeaderSize)
			break
		}
		pkt := batch[frameHeaderSize : frameHeaderSize+size]
		batch = batch[frameHeaderSize+size:]
		packets++
		switch {
		case !attached:
		case size > d.mtu:
			d.rxOversize.Add(1)
		default:
			d.in.push(nil, pkt) // counts packets/bytes, or a drop when full
		}
	}
	if err != nil {
		d.rxMalformed.Add(1)
	}
	if !attached {
		d.rxNoStack.Add(uint64(packets))
		if err == nil {
			err = newError(CodeNotRunning, "no stack attached")
		}
		return 0, err
	}
	return packets, err
}

func (d *flowDevice) counters() TunCounters {
	var c TunCounters
	q := d.in
	q.mu.Lock()
	c.RxPackets, c.RxBytes, c.RxDropped, c.RxQueueHighest = q.packets, q.bytes, q.dropped, q.highest
	q.mu.Unlock()
	q = d.out
	q.mu.Lock()
	c.TxPackets, c.TxBytes, c.TxDropped, c.TxQueueHighest, c.TxQueueBytes = q.packets, q.bytes, q.dropped, q.highest, q.capacity
	q.mu.Unlock()
	c.RxMalformed, c.RxNoStack, c.RxOversize = d.rxMalformed.Load(), d.rxNoStack.Load(), d.rxOversize.Load()
	c.FlowsActive, c.FlowsHighest, c.FlowsRejected = d.flowsActive.Load(), d.flowsHighest.Load(), d.flowsRejected.Load()
	return c
}

// flowListener is the bridge's replacement for the core's TUN listener (listener/sing_tun.New) in TunFlow
// mode: the same handler type (sing_tun.ListenerHandler, which carries the DNS hijack and ICMP policy) and the
// same mips stack, but on flowDevice instead of a system tun, and without routes, interface monitors or
// auto-redirect.
type flowListener struct {
	device *flowDevice
	stack  tun.Stack
	spec   *tunSpec
}

func startFlowListener(spec *tunSpec, device *flowDevice) (*flowListener, error) {
	h, err := sing.NewListenerHandler(sing.ListenerConfig{
		Tunnel: tunnel.Tunnel,
		Type:   C.TUN,
		// Same additions as the core's own TUN listener, so IN-NAME/IN-TYPE rules match the same way.
		Additions: []inbound.Addition{inbound.WithInName("DEFAULT-TUN"), inbound.WithSpecialRules("")},
	})
	if err != nil {
		return nil, err
	}
	handler := &sing_tun.ListenerHandler{
		ListenerHandler:       h,
		DnsAddrPorts:          spec.dnsHijack,
		Inet4Address:          spec.inet4,
		Inet6Address:          spec.inet6,
		DisableICMPForwarding: spec.disableICMPForwarding,
	}
	var loop4, loop6 []netip.Addr
	for _, a := range spec.loopback {
		if a.Is4() {
			loop4 = append(loop4, a)
		} else {
			loop6 = append(loop6, a)
		}
	}
	tunOptions := tun.Options{
		Name:                 "np-flow",
		MTU:                  spec.mtu,
		Inet4Address:         spec.inet4,
		Inet6Address:         spec.inet6,
		Inet4LoopbackAddress: loop4,
		Inet6LoopbackAddress: loop6,
	}
	stack, err := tun.NewStack("mips", tun.StackOptions{
		Context:                context.Background(),
		Tun:                    device,
		TunOptions:             tunOptions,
		EndpointIndependentNat: spec.endpointIndependentNat,
		UDPTimeout:             spec.udpTimeout,
		ICMPTimeout:            spec.icmpTimeout,
		Handler:                cappedHandler{ListenerHandler: handler, device: device},
		Logger:                 mlog.SingLogger,
		InterfaceFinder:        sing_tun.DefaultInterfaceFinder,
		TCPCongestionControl:   spec.congestionControl,
	})
	if err != nil {
		return nil, err
	}
	if err := stack.Start(); err != nil {
		_ = stack.Close()
		return nil, err
	}
	device.attached.Store(true)
	// As the core's listener does: the tun-side DNS addresses must never be used as system resolvers.
	resolver.AddSystemDnsBlacklist(spec.dnsServerIPs...)
	return &flowListener{device: device, stack: stack, spec: spec}, nil
}

// Close stops the stack (it resets its connections) and closes the device, which ends the stack's goroutines.
func (l *flowListener) Close() error {
	l.device.attached.Store(false)
	resolver.RemoveSystemDnsBlacklist(l.spec.dnsServerIPs...)
	return common.Close(l.stack, l.device)
}

package engine

import (
	"context"
	"encoding/binary"
	"io"
	"sync"
	"sync/atomic"

	"github.com/xtls/xray-core/common/buf"
	cctx "github.com/xtls/xray-core/common/ctx"
	xerrors "github.com/xtls/xray-core/common/errors"
	xlog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/proxy/tun"
	"github.com/xtls/xray-core/transport"
)

// TunCounters describe the packet interface of TunFlow mode.
type TunCounters struct {
	// Host -> core.
	RxPackets   uint64 `json:"rxPackets"`
	RxBytes     uint64 `json:"rxBytes"`
	RxMalformed uint64 `json:"rxMalformed"` // batches cut short by a bad frame
	RxNoStack   uint64 `json:"rxNoStack"`   // packets that arrived while no stack was attached
	// Core -> host.
	TxPackets      uint64 `json:"txPackets"`
	TxBytes        uint64 `json:"txBytes"`
	TxDropped      uint64 `json:"txDropped"`      // tail drops: the host did not read fast enough
	TxQueueHighest int    `json:"txQueueHighest"` // high-water mark of the queue in bytes
	TxQueueBytes   int    `json:"txQueueBytes"`   // capacity
}

// flowDevice is the packet interface of one engine run in TunFlow mode. It implements the core's tun.Tun so
// that the core's userspace TCP/IP stack writes its packets into the bounded queue, and it hands the packets
// of the host straight to the stack's Input.
type flowDevice struct {
	out *packetQueue

	// mu guards stack against Close: Input never runs on a closed stack.
	mu    sync.RWMutex
	stack tun.Stack

	rxPackets, rxBytes, rxMalformed, rxNoStack atomic.Uint64
}

func newFlowDevice(outQueueBytes int) *flowDevice {
	return &flowDevice{out: newPacketQueue(outQueueBytes)}
}

var _ tun.Tun = (*flowDevice)(nil)

func (d *flowDevice) Start() error          { return nil }
func (d *flowDevice) Close() error          { d.out.close(); return nil }
func (d *flowDevice) Name() (string, error) { return "flow", nil }
func (d *flowDevice) Index() (int, error) {
	return 0, xerrors.New("flow device has no interface index")
}

// ReadPacket implements tun.Tun for completeness. The bridge never starts the stack's reader: packets are
// pushed with writeBatch instead.
func (d *flowDevice) ReadPacket([]byte) ([]byte, error) { return nil, io.EOF }

// WritePacket implements tun.Tun. It never blocks; an overflowing queue drops the packet.
func (d *flowDevice) WritePacket(header, payload []byte) error {
	d.out.push(header, payload)
	return nil
}

func (d *flowDevice) attach(s tun.Stack) {
	d.mu.Lock()
	d.stack = s
	d.mu.Unlock()
}

func (d *flowDevice) detach() tun.Stack {
	d.mu.Lock()
	s := d.stack
	d.stack = nil
	d.mu.Unlock()
	return s
}

// writeBatch feeds a batch of frames to the stack and returns the number of packets consumed. The batch is not
// retained, but the stack may modify packet bytes in place.
func (d *flowDevice) writeBatch(batch []byte) (int, *Error) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	packets, bytes := 0, 0
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
		if d.stack != nil {
			d.stack.Input(batch[frameHeaderSize : frameHeaderSize+size])
		}
		packets++
		bytes += size
		batch = batch[frameHeaderSize+size:]
	}
	if err != nil {
		d.rxMalformed.Add(1)
	}
	if d.stack == nil {
		d.rxNoStack.Add(uint64(packets))
		if err == nil {
			err = newError(CodeNotRunning, "no stack attached")
		}
		return 0, err
	}
	d.rxPackets.Add(uint64(packets))
	d.rxBytes.Add(uint64(bytes))
	return packets, err
}

func (d *flowDevice) counters() TunCounters {
	q := d.out
	q.mu.Lock()
	c := TunCounters{TxPackets: q.packets, TxBytes: q.bytes, TxDropped: q.dropped, TxQueueHighest: q.highest, TxQueueBytes: len(q.buf)}
	q.mu.Unlock()
	c.RxPackets, c.RxBytes = d.rxPackets.Load(), d.rxBytes.Load()
	c.RxMalformed, c.RxNoStack = d.rxMalformed.Load(), d.rxNoStack.Load()
	return c
}

// flowInbound is the inbound handler the bridge registers in place of the config's "tun" inbound in TunFlow
// mode. It owns the core's userspace stack (proxy/tun.NewStack) and dispatches every TCP connection and UDP
// flow the stack accepts, under the tag, user level and sniffing settings of the inbound it replaces.
type flowInbound struct {
	spec   *tunSpec
	device *flowDevice

	ctx        context.Context
	cancel     context.CancelFunc
	dispatcher routing.Dispatcher
	idle       policy.Timeout
	sniffing   session.SniffingRequest
	uplink     stats.Counter
	downlink   stats.Counter
}

// newFlowInbound resolves the features of instance. ctx must carry the instance (see instanceContext).
func newFlowInbound(ctx context.Context, instance *core.Instance, spec *tunSpec, device *flowDevice) (*flowInbound, error) {
	dispatcher, _ := instance.GetFeature(routing.DispatcherType()).(routing.Dispatcher)
	pm, _ := instance.GetFeature(policy.ManagerType()).(policy.Manager)
	if dispatcher == nil || pm == nil {
		return nil, xerrors.New("dispatcher or policy manager is not registered")
	}
	h := &flowInbound{spec: spec, device: device, dispatcher: dispatcher, sniffing: spec.sniffing}
	h.ctx, h.cancel = context.WithCancel(ctx)
	h.idle = pm.ForLevel(spec.userLevel).Timeouts
	if sm, _ := instance.GetFeature(stats.ManagerType()).(stats.Manager); sm != nil && spec.tag != "" {
		if pm.ForSystem().Stats.InboundUplink {
			h.uplink, _ = sm.GetOrRegisterCounter("inbound>>>" + spec.tag + ">>>traffic>>>uplink")
		}
		if pm.ForSystem().Stats.InboundDownlink {
			h.downlink, _ = sm.GetOrRegisterCounter("inbound>>>" + spec.tag + ">>>traffic>>>downlink")
		}
	}
	return h, nil
}

func (h *flowInbound) Tag() string                            { return h.spec.tag }
func (h *flowInbound) ReceiverSettings() *serial.TypedMessage { return h.spec.receiver }
func (h *flowInbound) ProxySettings() *serial.TypedMessage    { return h.spec.proxy }

// Start implements common.Runnable: the stack starts taking packets.
func (h *flowInbound) Start() error {
	s, err := tun.NewStack(h.ctx, tun.StackOptions{
		Tun:         h.device,
		MTU:         h.spec.mtu,
		IdleTimeout: h.idle.ConnectionIdle,
	}, h)
	if err != nil {
		return err
	}
	// stack.Start is deliberately not called: it would only spawn a goroutine that reads the device.
	h.device.attach(s)
	return nil
}

// Close implements common.Closable. Dispatches in flight are cancelled, then the stack resets its connections.
func (h *flowInbound) Close() error {
	h.cancel()
	if s := h.device.detach(); s != nil {
		return s.Close()
	}
	return nil
}

// countingWriter counts UDP payload bytes written towards the tun side.
type countingWriter struct {
	buf.Writer
	counter stats.Counter
}

func (w *countingWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	size := int64(mb.Len())
	if err := w.Writer.WriteMultiBuffer(mb); err != nil {
		return err
	}
	w.counter.Add(size)
	return nil
}

// HandleConnection implements tun.ConnectionHandler. The stack calls it on its own goroutine for every accepted
// TCP connection and every new UDP flow.
func (h *flowInbound) HandleConnection(conn xnet.Conn, destination xnet.Destination) {
	defer conn.Close()

	ctx, cancel := context.WithCancel(h.ctx)
	defer cancel()
	ctx = cctx.ContextWithID(ctx, session.NewID())

	source := xnet.DestinationFromAddr(conn.RemoteAddr())
	ctx = session.ContextWithInbound(ctx, &session.Inbound{
		Name:          "tun",
		Tag:           h.spec.tag,
		CanSpliceCopy: 3,
		Source:        source,
		User:          &protocol.MemoryUser{Level: h.spec.userLevel},
	})
	ctx = session.ContextWithContent(ctx, &session.Content{SniffingRequest: h.sniffing})
	ctx = session.SubContextFromMuxInbound(ctx)
	ctx = xlog.ContextWithAccessMessage(ctx, &xlog.AccessMessage{
		From:   source,
		To:     destination,
		Status: xlog.AccessAccepted,
	})

	reader := &buf.TimeoutWrapperReader{Reader: buf.NewReader(conn), Counter: h.uplink}
	writer := buf.NewWriter(conn)
	if destination.Network != xnet.Network_UDP {
		// tun.TCPWriter has no Close on purpose: the stack keeps sending after the outbound finished writing.
		writer = &tun.TCPWriter{Writer: writer, Counter: h.downlink}
	} else if h.downlink != nil {
		writer = &countingWriter{Writer: writer, counter: h.downlink}
	}
	if err := h.dispatcher.DispatchLink(ctx, destination, &transport.Link{Reader: reader, Writer: writer}); err != nil {
		xerrors.LogInfoInner(ctx, err, "tun connection ended")
	}
}

// instanceContext returns a context that carries instance the way the core's own components expect it.
// core.toContext is unexported; the key type is exported ("exported for test") and its value is checked by
// TestInstanceContextKey so that a core upgrade that changes it fails loudly.
func instanceContext(instance *core.Instance) context.Context {
	return context.WithValue(context.Background(), core.XrayKey(1), instance)
}

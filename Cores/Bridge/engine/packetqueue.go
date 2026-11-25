package engine

import (
	"encoding/binary"
	"sync"
	"time"
)

// Batch wire format, used in both directions between the host and the bridge:
//
//	batch  = frame*
//	frame  = length(uint16, little-endian) packet(length bytes)
//
// A packet is one complete IP packet (IPv4 or IPv6, told apart by its version nibble). There is no
// per-packet protocol-family field and no padding.
const frameHeaderSize = 2

// maxPacketSize is the largest IP packet a frame can carry.
const maxPacketSize = 0xffff

// packetQueue is a bounded FIFO of packets travelling from the core to the host, stored as frames in one
// circular byte buffer so that queueing a packet allocates nothing. Producers never block: a packet that does
// not fit is dropped and counted (tail drop), which the TCP side of the stack treats as ordinary loss.
type packetQueue struct {
	mu     sync.Mutex
	buf    []byte
	r      int // read offset
	used   int // bytes in use
	closed bool
	notify chan struct{} // capacity 1

	packets  uint64
	bytes    uint64
	dropped  uint64
	highest  int // high-water mark of used
	capacity int // len(buf), kept for the counters after close
}

func newPacketQueue(capacity int) *packetQueue {
	return &packetQueue{buf: make([]byte, capacity), capacity: capacity, notify: make(chan struct{}, 1)}
}

func (q *packetQueue) put(off int, p []byte) {
	off %= len(q.buf)
	n := copy(q.buf[off:], p)
	copy(q.buf, p[n:])
}

func (q *packetQueue) get(off int, p []byte) {
	off %= len(q.buf)
	n := copy(p, q.buf[off:])
	copy(p[n:], q.buf)
}

// push queues one packet given in two parts. It reports whether the packet was queued.
func (q *packetQueue) push(header, payload []byte) bool {
	n := len(header) + len(payload)
	if n == 0 || n > maxPacketSize {
		return false
	}
	q.mu.Lock()
	if q.closed || q.used+frameHeaderSize+n > len(q.buf) {
		q.dropped++
		q.mu.Unlock()
		return false
	}
	w := q.r + q.used
	var h [frameHeaderSize]byte
	binary.LittleEndian.PutUint16(h[:], uint16(n))
	q.put(w, h[:])
	q.put(w+frameHeaderSize, header)
	q.put(w+frameHeaderSize+len(header), payload)
	wasEmpty := q.used == 0
	q.used += frameHeaderSize + n
	if q.used > q.highest {
		q.highest = q.used
	}
	q.packets++
	q.bytes += uint64(n)
	q.mu.Unlock()
	if wasEmpty {
		select {
		case q.notify <- struct{}{}:
		default:
		}
	}
	return true
}

// read copies as many whole frames as fit into dst and returns the number of bytes written. It waits up to
// timeout for the first packet; zero polls, negative waits until a packet arrives or the queue is closed.
func (q *packetQueue) read(dst []byte, timeout time.Duration) (int, *Error) {
	var timer *time.Timer
	var expired <-chan time.Time
	for {
		q.mu.Lock()
		if q.used > 0 {
			n := 0
			for q.used > 0 {
				var h [frameHeaderSize]byte
				q.get(q.r, h[:])
				size := frameHeaderSize + int(binary.LittleEndian.Uint16(h[:]))
				if size > len(dst)-n {
					break
				}
				q.get(q.r, dst[n:n+size])
				q.r = (q.r + size) % len(q.buf)
				q.used -= size
				n += size
			}
			q.mu.Unlock()
			if timer != nil {
				timer.Stop()
			}
			if n == 0 {
				return 0, newError(CodeBufferTooSmall, "buffer of %d bytes cannot hold the next packet", len(dst))
			}
			return n, nil
		}
		closed := q.closed
		q.mu.Unlock()
		if closed {
			return 0, newError(CodeClosed, "packet device closed")
		}
		if timeout == 0 {
			return 0, nil
		}
		if timeout > 0 && timer == nil {
			timer = time.NewTimer(timeout)
			expired = timer.C
		}
		select {
		case <-q.notify:
		case <-expired:
			return 0, nil
		}
	}
}

// close drops what is queued and releases the buffer right away: timers of the core's stack may keep the
// device reachable for seconds after a stop.
func (q *packetQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.buf, q.used, q.r = nil, 0, 0
	q.mu.Unlock()
	select {
	case q.notify <- struct{}{}:
	default:
	}
}

package main

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/tailscale/wireguard-go/tun"
)

// bridge is the node's TUN device. tsnet's own listeners and dials (the
// control and transfer connections, over gVisor's TCP) never reach it; every
// other packet for this node does, as a raw IP packet. UDP to a port the app
// opened goes straight to that port's socketpair, without gVisor: measured
// in-process at 120 Mbps, both nodes together used 100–107% CPU this way
// against 155–159% through gVisor's UDP, and carried 2.25 Gbps at most
// against 1.75 (docs/performance.md).
type bridge struct {
	out       chan []byte // toward the tailnet: what Read hands to tsnet
	held      []byte      // see Read
	closed    chan struct{}
	events    chan tun.Event // never sent on; closed with the device
	closeOnce sync.Once

	mu    sync.RWMutex
	ports map[uint16]*datagramPort

	self4, self6 atomic.Pointer[netip.Addr]
	reassemblyMu sync.Mutex
	reassembly   *reassembler

	// Datagrams dropped because the app's socket was full, or too large
	// for the tunnel; for diagnostics.
	droppedInbound, droppedOutbound atomic.Uint64
}

// tunnelMTU is the Tailscale tunnel's: room for WireGuard on any path.
const tunnelMTU = 1280

// socketBuffer holds a 4:4:4 keyframe burst (1–2 MB) between Go and the app.
// The default for a Unix datagram socket is 4 KB: three datagrams.
const socketBuffer = 8 << 20

type datagramPort struct {
	port uint16
	conn *net.UnixConn
	raw  syscall.RawConn
}

func newBridge() *bridge {
	return &bridge{
		out:        make(chan []byte, 4096),
		closed:     make(chan struct{}),
		events:     make(chan tun.Event),
		ports:      map[uint16]*datagramPort{},
		reassembly: newReassembler(),
	}
}

func (b *bridge) setSelf(ip4, ip6 netip.Addr) {
	b.self4.Store(&ip4)
	b.self6.Store(&ip6)
}

func (b *bridge) close() {
	b.closeOnce.Do(func() {
		close(b.closed)
		close(b.events)
	})
	b.mu.Lock()
	ports := b.ports
	b.ports = map[uint16]*datagramPort{}
	b.mu.Unlock()
	for _, port := range ports {
		port.conn.Close()
	}
}

// MARK: tun.Device

func (b *bridge) File() *os.File { return nil }

// Read packs the packets waiting for the tailnet into slab, with
// tun.ReadPacketSpacing bytes around each. tsnet reads from one goroutine,
// so `held` (a packet that didn't fit last time) needs no lock.
func (b *bridge) Read(slab []byte, packets []tun.ReadPacket) (int, error) {
	next := b.held
	b.held = nil
	if next == nil {
		select {
		case next = <-b.out:
		case <-b.closed:
			return 0, os.ErrClosed
		}
	}
	offset := tun.ReadPacketSpacing
	count := 0
	for {
		if offset+len(next)+tun.ReadPacketSpacing > len(slab) {
			if count == 0 {
				return 0, tun.ErrTooManySegments
			}
			b.held = next
			return count, nil
		}
		copy(slab[offset:], next)
		packets[count] = tun.ReadPacket{Offset: offset, Size: len(next)}
		count++
		offset += len(next) + tun.ReadPacketSpacing
		if count == len(packets) {
			return count, nil
		}
		select {
		case next = <-b.out:
		default:
			return count, nil
		}
	}
}

func (b *bridge) Write(bufs [][]byte, offset int) (int, error) {
	for _, buf := range bufs {
		b.deliver(buf[offset:])
	}
	return len(bufs), nil
}

func (b *bridge) MTU() (int, error)        { return tunnelMTU, nil }
func (b *bridge) Name() (string, error)    { return "anyremote", nil }
func (b *bridge) Events() <-chan tun.Event { return b.events }
func (b *bridge) BatchSize() int           { return 128 }

func (b *bridge) Close() error {
	b.close()
	return nil
}

// deliver takes a packet that arrived from the tailnet.
func (b *bridge) deliver(packet []byte) {
	if isIPv4Fragment(packet) {
		b.reassemblyMu.Lock()
		packet = b.reassembly.add(packet, time.Now())
		b.reassemblyMu.Unlock()
		if packet == nil {
			return
		}
	}
	if datagram, ok := parseUDP(packet); ok {
		b.mu.RLock()
		port := b.ports[datagram.dst.Port()]
		b.mu.RUnlock()
		if port == nil {
			return
		}
		frame := appendFrame(make([]byte, 0, 19+len(datagram.payload)), datagram.src, datagram.payload)
		if !port.send(frame) {
			b.droppedInbound.Add(1)
		}
		return
	}
	if self := b.self4.Load(); self != nil {
		if reply := echoReply(packet, *self); reply != nil {
			b.enqueue(reply)
		}
	}
}

func (b *bridge) enqueue(packet []byte) {
	select {
	case b.out <- packet:
	case <-b.closed:
	}
}

// send hands a frame to the app without waiting: a full socket drops it,
// as the network would.
func (p *datagramPort) send(frame []byte) bool {
	sent := false
	p.raw.Write(func(fd uintptr) bool {
		err := syscall.Sendto(int(fd), frame, syscall.MSG_DONTWAIT, nil)
		sent = err == nil
		return true
	})
	return sent
}

// MARK: Datagram ports

var errPortInUse = errors.New("that port is already open on this node")

// open binds a UDP port on this node (0: any free one) and returns the
// app's end of its socketpair.
func (b *bridge) open(port uint16) (uint16, int, error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return 0, -1, err
	}
	for _, fd := range fds {
		syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, socketBuffer)
		syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 64<<10)
	}
	file := os.NewFile(uintptr(fds[1]), "anyremote-datagrams")
	conn, err := net.FileConn(file)
	file.Close()
	if err != nil {
		syscall.Close(fds[0])
		return 0, -1, err
	}
	unix := conn.(*net.UnixConn)
	raw, err := unix.SyscallConn()
	if err != nil {
		unix.Close()
		syscall.Close(fds[0])
		return 0, -1, err
	}
	b.mu.Lock()
	if port == 0 {
		for candidate := uint16(49152); candidate != 0; candidate++ {
			if b.ports[candidate] == nil {
				port = candidate
				break
			}
		}
	}
	if port == 0 || b.ports[port] != nil {
		b.mu.Unlock()
		unix.Close()
		syscall.Close(fds[0])
		return 0, -1, errPortInUse
	}
	entry := &datagramPort{port: port, conn: unix, raw: raw}
	b.ports[port] = entry
	b.mu.Unlock()
	go b.forward(entry)
	return port, fds[0], nil
}

func (b *bridge) closePort(port uint16) {
	b.mu.Lock()
	entry := b.ports[port]
	delete(b.ports, port)
	b.mu.Unlock()
	if entry != nil {
		entry.conn.Close()
	}
}

// forward sends the app's datagrams from one port out to the tailnet.
func (b *bridge) forward(port *datagramPort) {
	buffer := make([]byte, 65536)
	for {
		count, err := port.conn.Read(buffer)
		if err != nil {
			return
		}
		destination, payload, err := parseFrame(buffer[:count])
		if err != nil {
			continue
		}
		var source *netip.Addr
		if destination.Addr().Is4() {
			source = b.self4.Load()
		} else {
			source = b.self6.Load()
		}
		headers := ipv4Header + udpHeader
		if !destination.Addr().Is4() {
			headers = ipv6Header + udpHeader
		}
		if source == nil || !source.IsValid() || len(payload)+headers > tunnelMTU {
			b.droppedOutbound.Add(1)
			continue
		}
		b.enqueue(buildUDP(netip.AddrPortFrom(*source, port.port), destination, payload))
	}
}

func (b *bridge) String() string {
	return fmt.Sprintf("bridge(dropped in %d, out %d)", b.droppedInbound.Load(), b.droppedOutbound.Load())
}

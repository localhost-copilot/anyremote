package main

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"slices"
	"time"
)

// IP and UDP headers for the datagrams that bypass gVisor (see bridge.go).
// The tailnet carries raw IP packets; the app sends and receives UDP
// payloads, so this file turns one into the other.

const (
	protocolICMP = 1
	protocolUDP  = 17
	ipv4Header   = 20
	ipv6Header   = 40
	udpHeader    = 8
)

// frame is how a datagram crosses the socketpair between Go and the app:
// family (4 or 6), the peer's port (big-endian), its address (4 or 16
// bytes), then the UDP payload. Inbound the peer is the sender, outbound
// the destination.
func appendFrame(dst []byte, peer netip.AddrPort, payload []byte) []byte {
	addr := peer.Addr()
	if addr.Is4() {
		dst = append(dst, 4)
	} else {
		dst = append(dst, 6)
	}
	dst = binary.BigEndian.AppendUint16(dst, peer.Port())
	dst = append(dst, addr.AsSlice()...)
	return append(dst, payload...)
}

var errBadFrame = errors.New("malformed datagram frame")

func parseFrame(frame []byte) (netip.AddrPort, []byte, error) {
	if len(frame) < 3 {
		return netip.AddrPort{}, nil, errBadFrame
	}
	port := binary.BigEndian.Uint16(frame[1:3])
	var size int
	switch frame[0] {
	case 4:
		size = 4
	case 6:
		size = 16
	default:
		return netip.AddrPort{}, nil, errBadFrame
	}
	if len(frame) < 3+size {
		return netip.AddrPort{}, nil, errBadFrame
	}
	addr, _ := netip.AddrFromSlice(frame[3 : 3+size])
	return netip.AddrPortFrom(addr, port), frame[3+size:], nil
}

// checksumAdd adds data to a running one's-complement sum.
func checksumAdd(sum uint32, data []byte) uint32 {
	for len(data) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}
	if len(data) == 1 {
		sum += uint32(data[0]) << 8
	}
	return sum
}

func checksumFold(sum uint32) uint16 {
	for sum > 0xffff {
		sum = sum>>16 + sum&0xffff
	}
	return ^uint16(sum)
}

// buildUDP makes an IPv4 or IPv6 packet carrying payload from src to dst,
// with valid IP and UDP checksums (IPv6 requires the UDP one).
func buildUDP(src, dst netip.AddrPort, payload []byte) []byte {
	udpLength := udpHeader + len(payload)
	var packet []byte
	var pseudo uint32
	if src.Addr().Is4() {
		packet = make([]byte, ipv4Header+udpLength)
		packet[0] = 0x45
		binary.BigEndian.PutUint16(packet[2:], uint16(len(packet)))
		binary.BigEndian.PutUint16(packet[6:], 0x4000) // don't fragment
		packet[8] = 64
		packet[9] = protocolUDP
		s, d := src.Addr().As4(), dst.Addr().As4()
		copy(packet[12:16], s[:])
		copy(packet[16:20], d[:])
		binary.BigEndian.PutUint16(packet[10:], checksumFold(checksumAdd(0, packet[:ipv4Header])))
		pseudo = checksumAdd(0, packet[12:20])
	} else {
		packet = make([]byte, ipv6Header+udpLength)
		packet[0] = 0x60
		binary.BigEndian.PutUint16(packet[4:], uint16(udpLength))
		packet[6] = protocolUDP
		packet[7] = 64
		s, d := src.Addr().As16(), dst.Addr().As16()
		copy(packet[8:24], s[:])
		copy(packet[24:40], d[:])
		pseudo = checksumAdd(0, packet[8:40])
	}
	udp := packet[len(packet)-udpLength:]
	binary.BigEndian.PutUint16(udp[0:], src.Port())
	binary.BigEndian.PutUint16(udp[2:], dst.Port())
	binary.BigEndian.PutUint16(udp[4:], uint16(udpLength))
	copy(udp[udpHeader:], payload)
	pseudo += protocolUDP + uint32(udpLength)
	sum := checksumFold(checksumAdd(pseudo, udp))
	if sum == 0 {
		sum = 0xffff
	}
	binary.BigEndian.PutUint16(udp[6:], sum)
	return packet
}

// udpDatagram is a UDP packet that arrived for this node.
type udpDatagram struct {
	src, dst netip.AddrPort
	payload  []byte
}

// parseUDP reads an unfragmented IPv4 or IPv6 UDP packet. IPv6 packets
// with extension headers aren't expected from a tailnet peer and are not
// parsed.
func parseUDP(packet []byte) (udpDatagram, bool) {
	var src, dst netip.Addr
	var udp []byte
	switch {
	case len(packet) >= ipv4Header && packet[0]>>4 == 4:
		ihl := int(packet[0]&0x0f) * 4
		total := int(binary.BigEndian.Uint16(packet[2:]))
		if ihl < ipv4Header || total < ihl+udpHeader || total > len(packet) || packet[9] != protocolUDP {
			return udpDatagram{}, false
		}
		src = netip.AddrFrom4([4]byte(packet[12:16]))
		dst = netip.AddrFrom4([4]byte(packet[16:20]))
		udp = packet[ihl:total]
	case len(packet) >= ipv6Header && packet[0]>>4 == 6:
		length := int(binary.BigEndian.Uint16(packet[4:]))
		if packet[6] != protocolUDP || length < udpHeader || ipv6Header+length > len(packet) {
			return udpDatagram{}, false
		}
		src = netip.AddrFrom16([16]byte(packet[8:24]))
		dst = netip.AddrFrom16([16]byte(packet[24:40]))
		udp = packet[ipv6Header : ipv6Header+length]
	default:
		return udpDatagram{}, false
	}
	length := int(binary.BigEndian.Uint16(udp[4:]))
	if length < udpHeader || length > len(udp) {
		return udpDatagram{}, false
	}
	return udpDatagram{
		src:     netip.AddrPortFrom(src, binary.BigEndian.Uint16(udp[0:])),
		dst:     netip.AddrPortFrom(dst, binary.BigEndian.Uint16(udp[2:])),
		payload: udp[udpHeader:length],
	}, true
}

// isIPv4Fragment says whether an IPv4 packet is one piece of a larger one.
func isIPv4Fragment(packet []byte) bool {
	if len(packet) < ipv4Header || packet[0]>>4 != 4 {
		return false
	}
	flags := binary.BigEndian.Uint16(packet[6:])
	return flags&0x2000 != 0 || flags&0x1fff != 0
}

// echoReply answers an IPv4 ICMP echo request to this node, so `ping`
// works for diagnosing the path. Nil for anything else.
func echoReply(packet []byte, self netip.Addr) []byte {
	if len(packet) < ipv4Header+8 || packet[0]>>4 != 4 || packet[9] != protocolICMP || isIPv4Fragment(packet) {
		return nil
	}
	ihl := int(packet[0]&0x0f) * 4
	total := int(binary.BigEndian.Uint16(packet[2:]))
	if ihl < ipv4Header || total > len(packet) || total < ihl+8 || packet[ihl] != 8 {
		return nil
	}
	if netip.AddrFrom4([4]byte(packet[16:20])) != self {
		return nil
	}
	reply := make([]byte, ipv4Header+total-ihl)
	reply[0] = 0x45
	binary.BigEndian.PutUint16(reply[2:], uint16(len(reply)))
	reply[8] = 64
	reply[9] = protocolICMP
	copy(reply[12:16], packet[16:20])
	copy(reply[16:20], packet[12:16])
	binary.BigEndian.PutUint16(reply[10:], checksumFold(checksumAdd(0, reply[:ipv4Header])))
	icmp := reply[ipv4Header:]
	copy(icmp, packet[ihl:total])
	icmp[0] = 0
	icmp[2], icmp[3] = 0, 0
	binary.BigEndian.PutUint16(icmp[2:], checksumFold(checksumAdd(0, icmp)))
	return reply
}

// reassembler puts IPv4 fragments back together. A host whose datagrams
// are larger than the tunnel's 1280 bytes (an AnyRemote from before path
// sizing, sending over the Tailscale app) arrives here in pieces: the
// sender's kernel split them, and only a TUN, not gVisor, sees them now.
type reassembler struct {
	pending map[fragmentKey]*fragmentSet
	lastGC  time.Time
}

type fragmentKey struct {
	src, dst [4]byte
	id       uint16
	protocol byte
}

type fragmentSet struct {
	header   []byte // the first fragment's IP header
	pieces   map[int][]byte
	received int
	total    int // payload length, once the last fragment came; else -1
	started  time.Time
}

const (
	maximumPendingFragments = 256
	fragmentTimeout         = 2 * time.Second
)

func newReassembler() *reassembler {
	return &reassembler{pending: map[fragmentKey]*fragmentSet{}}
}

// add takes one fragment and returns the whole packet once every piece is
// there. Overlapping or oversized fragments drop the packet.
func (r *reassembler) add(packet []byte, now time.Time) []byte {
	ihl := int(packet[0]&0x0f) * 4
	total := int(binary.BigEndian.Uint16(packet[2:]))
	if ihl < ipv4Header || total < ihl || total > len(packet) {
		return nil
	}
	if now.Sub(r.lastGC) > fragmentTimeout {
		r.lastGC = now
		for key, set := range r.pending {
			if now.Sub(set.started) > fragmentTimeout {
				delete(r.pending, key)
			}
		}
	}
	key := fragmentKey{src: [4]byte(packet[12:16]), dst: [4]byte(packet[16:20]),
		id: binary.BigEndian.Uint16(packet[4:]), protocol: packet[9]}
	flags := binary.BigEndian.Uint16(packet[6:])
	offset := int(flags&0x1fff) * 8
	more := flags&0x2000 != 0
	payload := packet[ihl:total]
	set := r.pending[key]
	if set == nil {
		if len(r.pending) >= maximumPendingFragments {
			return nil
		}
		set = &fragmentSet{pieces: map[int][]byte{}, total: -1, started: now}
		r.pending[key] = set
	}
	if _, seen := set.pieces[offset]; seen || offset+len(payload) > 65535-ipv4Header {
		delete(r.pending, key)
		return nil
	}
	set.pieces[offset] = append([]byte(nil), payload...)
	set.received += len(payload)
	if offset == 0 {
		set.header = append([]byte(nil), packet[:ihl]...)
	}
	if !more {
		set.total = offset + len(payload)
	}
	if set.total < 0 || set.received < set.total || set.header == nil {
		return nil
	}
	delete(r.pending, key)
	offsets := make([]int, 0, len(set.pieces))
	for offset := range set.pieces {
		offsets = append(offsets, offset)
	}
	slices.Sort(offsets)
	whole := make([]byte, len(set.header)+set.total)
	copy(whole, set.header)
	end := 0
	for _, offset := range offsets {
		piece := set.pieces[offset]
		// Each piece starts where the one before ended: no gap, no overlap.
		if offset != end {
			return nil
		}
		copy(whole[len(set.header)+offset:], piece)
		end = offset + len(piece)
	}
	if end != set.total {
		return nil
	}
	binary.BigEndian.PutUint16(whole[2:], uint16(len(whole)))
	binary.BigEndian.PutUint16(whole[6:], 0)
	whole[10], whole[11] = 0, 0
	binary.BigEndian.PutUint16(whole[10:], checksumFold(checksumAdd(0, whole[:len(set.header)])))
	return whole
}

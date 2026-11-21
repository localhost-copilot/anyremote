package main

import (
	"bytes"
	"encoding/binary"
	"net/netip"
	"testing"
	"time"
)

func TestFrameRoundTrip(t *testing.T) {
	for _, peer := range []netip.AddrPort{
		netip.MustParseAddrPort("100.86.208.99:47800"),
		netip.MustParseAddrPort("[fd7a:115c:a1e0::d33:b04e]:49152"),
	} {
		frame := appendFrame(nil, peer, []byte("payload"))
		got, payload, err := parseFrame(frame)
		if err != nil || got != peer || string(payload) != "payload" {
			t.Fatalf("%v: got %v %q %v", peer, got, payload, err)
		}
	}
	for _, bad := range [][]byte{nil, {4, 0}, {5, 0, 1, 1, 2, 3, 4}, {6, 0, 1, 1}} {
		if _, _, err := parseFrame(bad); err == nil {
			t.Fatalf("parsed malformed frame %v", bad)
		}
	}
}

// Valid checksums matter: the peer's kernel (a Mac on the Tailscale app)
// drops a UDP packet whose checksum doesn't add up.
func TestUDPPacketChecksums(t *testing.T) {
	cases := []struct{ src, dst string }{
		{"100.75.176.77:47800", "100.86.208.99:50000"},
		{"[fd7a:115c:a1e0::1]:47800", "[fd7a:115c:a1e0::2]:50000"},
	}
	for _, c := range cases {
		src, dst := netip.MustParseAddrPort(c.src), netip.MustParseAddrPort(c.dst)
		payload := bytes.Repeat([]byte{0xa5}, 1201)
		packet := buildUDP(src, dst, payload)
		datagram, ok := parseUDP(packet)
		if !ok || datagram.src != src || datagram.dst != dst || !bytes.Equal(datagram.payload, payload) {
			t.Fatalf("%s: round trip failed", c.src)
		}
		var pseudo uint32
		var udp []byte
		if src.Addr().Is4() {
			if checksumFold(checksumAdd(0, packet[:ipv4Header])) != 0 {
				t.Fatalf("IPv4 header checksum invalid")
			}
			pseudo = checksumAdd(0, packet[12:20])
			udp = packet[ipv4Header:]
		} else {
			pseudo = checksumAdd(0, packet[8:40])
			udp = packet[ipv6Header:]
		}
		pseudo += protocolUDP + uint32(len(udp))
		if checksumFold(checksumAdd(pseudo, udp)) != 0 {
			t.Fatalf("%s: UDP checksum invalid", c.src)
		}
	}
}

func fragment(packet []byte, payloadPerFragment int) [][]byte {
	header := packet[:ipv4Header]
	payload := packet[ipv4Header:]
	var fragments [][]byte
	for offset := 0; offset < len(payload); offset += payloadPerFragment {
		end := min(offset+payloadPerFragment, len(payload))
		piece := append(append([]byte(nil), header...), payload[offset:end]...)
		binary.BigEndian.PutUint16(piece[2:], uint16(len(piece)))
		flags := uint16(offset / 8)
		if end < len(payload) {
			flags |= 0x2000
		}
		binary.BigEndian.PutUint16(piece[4:], 0x1234)
		binary.BigEndian.PutUint16(piece[6:], flags)
		fragments = append(fragments, piece)
	}
	return fragments
}

// A 1400-byte datagram from an older host, split by its kernel for the
// 1280-byte tunnel, comes back whole, in either order.
func TestReassemblesFragments(t *testing.T) {
	src, dst := netip.MustParseAddrPort("100.86.208.99:50000"), netip.MustParseAddrPort("100.75.176.77:47800")
	payload := bytes.Repeat([]byte{7}, 1400)
	packet := buildUDP(src, dst, payload)
	pieces := fragment(packet, 1256)
	for _, order := range [][]int{{0, 1}, {1, 0}} {
		r := newReassembler()
		var whole []byte
		for _, index := range order {
			if whole != nil {
				t.Fatal("reassembled before the last piece")
			}
			if !isIPv4Fragment(pieces[index]) {
				t.Fatal("piece not recognized as a fragment")
			}
			whole = r.add(pieces[index], time.Now())
		}
		datagram, ok := parseUDP(whole)
		if !ok || !bytes.Equal(datagram.payload, payload) || datagram.src != src {
			t.Fatalf("order %v: reassembly failed", order)
		}
	}
}

func TestReassemblyRejectsOverlapsAndExpires(t *testing.T) {
	src, dst := netip.MustParseAddrPort("100.86.208.99:50000"), netip.MustParseAddrPort("100.75.176.77:47800")
	packet := buildUDP(src, dst, bytes.Repeat([]byte{1}, 1400))
	pieces := fragment(packet, 1256)
	r := newReassembler()
	start := time.Now()
	r.add(pieces[0], start)
	// The rest arrives too late: the first piece was dropped meanwhile.
	if whole := r.add(pieces[1], start.Add(3*fragmentTimeout)); whole != nil {
		t.Fatal("reassembled across the timeout")
	}
	// A duplicate of the first piece drops the packet.
	r = newReassembler()
	r.add(pieces[0], start)
	r.add(pieces[0], start)
	if whole := r.add(pieces[1], start); whole != nil {
		t.Fatal("reassembled after an overlapping duplicate")
	}
}

func TestAnswersPing(t *testing.T) {
	self := netip.MustParseAddr("100.75.176.77")
	request := make([]byte, ipv4Header+8+4)
	request[0] = 0x45
	binary.BigEndian.PutUint16(request[2:], uint16(len(request)))
	request[8], request[9] = 64, protocolICMP
	copy(request[12:16], []byte{100, 86, 208, 99})
	copy(request[16:20], self.AsSlice())
	request[ipv4Header] = 8
	copy(request[ipv4Header+4:], []byte{0, 1, 0, 2, 'p', 'i', 'n', 'g'})
	reply := echoReply(request, self)
	if reply == nil || reply[ipv4Header] != 0 || !bytes.Equal(reply[16:20], []byte{100, 86, 208, 99}) {
		t.Fatal("no echo reply")
	}
	if checksumFold(checksumAdd(0, reply[ipv4Header:])) != 0 || checksumFold(checksumAdd(0, reply[:ipv4Header])) != 0 {
		t.Fatal("echo reply checksum invalid")
	}
	if echoReply(request, netip.MustParseAddr("100.1.1.1")) != nil {
		t.Fatal("answered a ping for another address")
	}
}

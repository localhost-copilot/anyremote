package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"tailscale.com/ipn/store/mem"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
)

// Two nodes on a tailnet of Tailscale's test control server, in this
// process, with the bridge and sockets the app uses.

func startControl(t *testing.T) string {
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	derpMap := integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1")
	control := &testcontrol.Server{DERPMap: derpMap}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	t.Cleanup(control.HTTPTestServer.Close)
	return control.HTTPTestServer.URL
}

func startNode(t *testing.T, ctx context.Context, controlURL, name string) (*tsnet.Server, *bridge, netip.Addr) {
	b := newBridge()
	server := &tsnet.Server{Dir: filepath.Join(t.TempDir(), name), ControlURL: controlURL, Hostname: name,
		Store: new(mem.Store), Ephemeral: true, Tun: b, Logf: logger.Discard, UserLogf: logger.Discard}
	status, err := server.Up(ctx)
	if err != nil {
		t.Fatal(err)
	}
	stop := make(chan struct{})
	go followAddresses(server, b, stop)
	t.Cleanup(func() {
		close(stop)
		b.close()
		server.Close()
	})
	for b.self4.Load() == nil {
		time.Sleep(10 * time.Millisecond)
	}
	return server, b, status.TailscaleIPs[0]
}

func readFrame(t *testing.T, fd int, deadline time.Duration) (netip.AddrPort, []byte, bool) {
	tv := syscall.NsecToTimeval(deadline.Nanoseconds())
	syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	buffer := make([]byte, 65536)
	count, err := syscall.Read(fd, buffer)
	if err != nil {
		return netip.AddrPort{}, nil, false
	}
	peer, payload, err := parseFrame(buffer[:count])
	if err != nil {
		t.Fatal(err)
	}
	return peer, payload, true
}

func TestDatagramsAndStreamsBetweenNodes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	controlURL := startControl(t)
	a, aBridge, aIP := startNode(t, ctx, controlURL, "viewer")
	b, bBridge, bIP := startNode(t, ctx, controlURL, "host")

	// Datagrams: the host's port 47800, the viewer's any port.
	hostPort, hostFD, err := bBridge.open(47800)
	if err != nil || hostPort != 47800 {
		t.Fatal(err)
	}
	defer syscall.Close(hostFD)
	if _, _, err := bBridge.open(47800); err == nil {
		t.Fatal("opened a port twice")
	}
	viewerPort, viewerFD, err := aBridge.open(0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(viewerFD)
	host := netip.AddrPortFrom(bIP, 47800)
	var from netip.AddrPort
	for attempt := 0; ; attempt++ {
		syscall.Write(viewerFD, appendFrame(nil, host, []byte("keepalive")))
		peer, payload, ok := readFrame(t, hostFD, 200*time.Millisecond)
		if ok {
			if string(payload) != "keepalive" {
				t.Fatalf("got %q", payload)
			}
			from = peer
			break
		}
		if attempt > 100 {
			t.Fatal("no datagram arrived")
		}
	}
	if from != netip.AddrPortFrom(aIP, viewerPort) {
		t.Fatalf("datagram from %v, want %v", from, netip.AddrPortFrom(aIP, viewerPort))
	}
	// A keyframe-sized burst back to the viewer, as the host sends video.
	payload := bytes.Repeat([]byte{0x5a}, 1232)
	const burst = 1700
	for index := 0; index < burst; index++ {
		binary.BigEndian.PutUint32(payload, uint32(index))
		if _, err := syscall.Write(hostFD, appendFrame(nil, from, payload)); err != nil {
			t.Fatal(err)
		}
	}
	received := 0
	for {
		peer, got, ok := readFrame(t, viewerFD, time.Second)
		if !ok {
			break
		}
		if peer != host || len(got) != len(payload) {
			t.Fatalf("got %d bytes from %v", len(got), peer)
		}
		received++
	}
	if received < burst*99/100 {
		t.Fatalf("burst: %d of %d datagrams arrived", received, burst)
	}
	t.Logf("burst: %d of %d datagrams arrived", received, burst)
	// Too large for the tunnel: dropped and counted, not fragmented.
	syscall.Write(hostFD, appendFrame(nil, from, make([]byte, tunnelMTU)))
	time.Sleep(100 * time.Millisecond)
	if bBridge.droppedOutbound.Load() == 0 {
		t.Fatal("an oversized datagram wasn't counted")
	}

	// TCP: the host listens, the viewer dials.
	channel, err := listen(b, 47800)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(channel)
	conn, err := dial(a, host.String(), 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	record := make([]byte, acceptRecordSize)
	if count, err := syscall.Read(channel, record); err != nil || count != acceptRecordSize {
		t.Fatalf("accept record: %d %v", count, err)
	}
	accepted := int(int32(binary.BigEndian.Uint32(record)))
	defer syscall.Close(accepted)
	remote, err := netip.ParseAddrPort(string(record[5 : 5+int(record[4])]))
	if err != nil || remote.Addr() != aIP {
		t.Fatalf("remote %v %v, want %v", remote, err, aIP)
	}
	syscall.Write(conn, []byte("hello"))
	reply := make([]byte, 5)
	if count, err := syscall.Read(accepted, reply); err != nil || string(reply[:count]) != "hello" {
		t.Fatalf("read %q %v", reply[:count], err)
	}
	// Closing one end ends the other.
	syscall.Close(conn)
	tv := syscall.NsecToTimeval(int64(5 * time.Second))
	syscall.SetsockoptTimeval(accepted, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	if count, err := syscall.Read(accepted, reply); err != nil || count != 0 {
		t.Fatalf("after close: %d %v", count, err)
	}
}

// Package main is AnyRemote's embedded Tailscale node: a tsnet server that
// joins the user's tailnet as a device of its own, so AnyRemote reaches
// other Macs there without the Tailscale app. It is built as a C archive
// (scripts/build-tailnet.sh) and linked into the app; the C interface is
// Packages/AnyRemoteKit/Sources/CAnyRemoteTailnet/include/anyremote_tailnet.h.
//
// One node per process. Every function is safe to call from any thread.
package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"sort"
	"strings"
	"sync"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

var node struct {
	sync.Mutex
	server *tsnet.Server
	bridge *bridge
	stop   chan struct{}
}

var errNotStarted = errors.New("the embedded Tailscale node isn't running")

func current() (*tsnet.Server, *bridge, error) {
	node.Lock()
	defer node.Unlock()
	if node.server == nil {
		return nil, nil, errNotStarted
	}
	return node.server, node.bridge, nil
}

func fail(errorOut **C.char, err error) C.int {
	if errorOut != nil {
		*errorOut = C.CString(err.Error())
	}
	return -1
}

func optional(value *C.char) string {
	if value == nil {
		return ""
	}
	return C.GoString(value)
}

//export ar_tailnet_start
func ar_tailnet_start(stateDir, hostname, controlURL, authKey *C.char, errorOut **C.char) C.int {
	node.Lock()
	defer node.Unlock()
	if node.server != nil {
		return 0
	}
	b := newBridge()
	server := &tsnet.Server{
		Dir:        C.GoString(stateDir),
		Hostname:   C.GoString(hostname),
		ControlURL: optional(controlURL),
		AuthKey:    optional(authKey),
		Tun:        b,
		Logf:       logger.Discard,
		UserLogf:   logger.Discard,
	}
	// Without a key this starts the interactive login: the status then
	// carries the URL to open.
	if err := server.Start(); err != nil {
		server.Close()
		return fail(errorOut, err)
	}
	stop := make(chan struct{})
	node.server, node.bridge, node.stop = server, b, stop
	go followAddresses(server, b, stop)
	return 0
}

// followAddresses keeps the bridge's idea of this node's addresses current:
// they are the source of every datagram it sends.
func followAddresses(server *tsnet.Server, b *bridge, stop chan struct{}) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		ip4, ip6 := server.TailscaleIPs()
		b.setSelf(ip4, ip6)
		select {
		case <-stop:
			return
		case <-ticker.C:
		}
	}
}

//export ar_tailnet_stop
func ar_tailnet_stop() {
	node.Lock()
	server, b, stop := node.server, node.bridge, node.stop
	node.server, node.bridge, node.stop = nil, nil, nil
	node.Unlock()
	if server == nil {
		return
	}
	close(stop)
	b.close()
	server.Close()
}

//export ar_tailnet_login
func ar_tailnet_login(errorOut **C.char) C.int {
	server, _, err := current()
	if err != nil {
		return fail(errorOut, err)
	}
	client, err := server.LocalClient()
	if err != nil {
		return fail(errorOut, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := client.StartLoginInteractive(ctx); err != nil {
		return fail(errorOut, err)
	}
	return 0
}

//export ar_tailnet_logout
func ar_tailnet_logout(errorOut **C.char) C.int {
	server, _, err := current()
	if err != nil {
		return fail(errorOut, err)
	}
	client, err := server.LocalClient()
	if err != nil {
		return fail(errorOut, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := client.Logout(ctx); err != nil {
		return fail(errorOut, err)
	}
	return 0
}

type statusJSON struct {
	State           string     `json:"state"`
	AuthURL         string     `json:"authURL,omitempty"`
	Tailnet         string     `json:"tailnet,omitempty"`
	User            string     `json:"user,omitempty"`
	Self            *peerJSON  `json:"self,omitempty"`
	Peers           []peerJSON `json:"peers"`
	Health          []string   `json:"health,omitempty"`
	DroppedInbound  uint64     `json:"droppedInbound"`
	DroppedOutbound uint64     `json:"droppedOutbound"`
}

type peerJSON struct {
	ID        string     `json:"id"`
	HostName  string     `json:"hostName"`
	DNSName   string     `json:"dnsName"`
	OS        string     `json:"os"`
	Online    bool       `json:"online"`
	Addresses []string   `json:"addresses"`
	CurAddr   string     `json:"curAddr,omitempty"`
	Relay     string     `json:"relay,omitempty"`
	PeerRelay string     `json:"peerRelay,omitempty"`
	KeyExpiry *time.Time `json:"keyExpiry,omitempty"`
}

// ar_tailnet_status returns the node's state, this device and its peers as
// JSON (TailnetStatus in AnyRemoteNetwork), to be freed with free(); NULL
// when the node isn't running.
//
//export ar_tailnet_status
func ar_tailnet_status() *C.char {
	server, b, err := current()
	if err != nil {
		return nil
	}
	client, err := server.LocalClient()
	if err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return nil
	}
	out := statusJSON{
		State:           status.BackendState,
		AuthURL:         status.AuthURL,
		Health:          status.Health,
		Peers:           []peerJSON{},
		DroppedInbound:  b.droppedInbound.Load(),
		DroppedOutbound: b.droppedOutbound.Load(),
	}
	if status.CurrentTailnet != nil {
		out.Tailnet = status.CurrentTailnet.Name
	}
	convert := func(peer *ipnstate.PeerStatus) peerJSON {
		addresses := make([]string, 0, len(peer.TailscaleIPs))
		for _, ip := range peer.TailscaleIPs {
			addresses = append(addresses, ip.String())
		}
		return peerJSON{
			ID: string(peer.ID), HostName: peer.HostName, DNSName: strings.TrimSuffix(peer.DNSName, "."),
			OS: peer.OS, Online: peer.Online, Addresses: addresses, CurAddr: peer.CurAddr,
			Relay: peer.Relay, PeerRelay: peer.PeerRelay, KeyExpiry: peer.KeyExpiry,
		}
	}
	if self := status.Self; self != nil {
		converted := convert(self)
		out.Self = &converted
		if user, ok := status.User[self.UserID]; ok {
			out.User = user.LoginName
		}
	}
	for _, peer := range status.Peer {
		out.Peers = append(out.Peers, convert(peer))
	}
	sort.Slice(out.Peers, func(i, j int) bool { return out.Peers[i].HostName < out.Peers[j].HostName })
	data, err := json.Marshal(out)
	if err != nil {
		return nil
	}
	return C.CString(string(data))
}

//export ar_tailnet_listen
func ar_tailnet_listen(port C.uint16_t, fdOut *C.int, errorOut **C.char) C.int {
	server, _, err := current()
	if err != nil {
		return fail(errorOut, err)
	}
	fd, err := listen(server, uint16(port))
	if err != nil {
		return fail(errorOut, err)
	}
	*fdOut = C.int(fd)
	return 0
}

//export ar_tailnet_dial
func ar_tailnet_dial(address *C.char, timeoutMilliseconds C.int, fdOut *C.int, errorOut **C.char) C.int {
	server, _, err := current()
	if err != nil {
		return fail(errorOut, err)
	}
	if _, err := netip.ParseAddrPort(C.GoString(address)); err != nil {
		return fail(errorOut, err)
	}
	fd, err := dial(server, C.GoString(address), time.Duration(timeoutMilliseconds)*time.Millisecond)
	if err != nil {
		return fail(errorOut, err)
	}
	*fdOut = C.int(fd)
	return 0
}

//export ar_tailnet_open_datagram
func ar_tailnet_open_datagram(port C.uint16_t, boundPortOut *C.uint16_t, fdOut *C.int, errorOut **C.char) C.int {
	_, b, err := current()
	if err != nil {
		return fail(errorOut, err)
	}
	bound, fd, err := b.open(uint16(port))
	if err != nil {
		return fail(errorOut, err)
	}
	*boundPortOut = C.uint16_t(bound)
	*fdOut = C.int(fd)
	return 0
}

//export ar_tailnet_close_datagram
func ar_tailnet_close_datagram(port C.uint16_t) {
	if _, b, err := current(); err == nil {
		b.closePort(uint16(port))
	}
}

func main() {}

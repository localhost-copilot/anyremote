package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"syscall"
	"time"

	"tailscale.com/tsnet"
)

// TCP over the tailnet reaches the app as ordinary file descriptors: each
// connection is a socketpair whose other end Go copies to and from the
// tsnet connection, and a listener is a stream socket on which every
// accepted connection arrives as one fixed-size record.

const streamBuffer = 1 << 20

// socketpair makes a pair with close-on-exec set (the app runs helper
// processes) and the given buffer sizes; buffer 0 keeps the default.
func socketpair(kind int, buffer int) ([2]int, error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, kind, 0)
	if err != nil {
		return fds, err
	}
	for _, fd := range fds {
		syscall.CloseOnExec(fd)
		syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_NOSIGPIPE, 1)
		if buffer > 0 {
			syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, buffer)
			syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, buffer)
		}
	}
	return fds, nil
}

// unixConn adopts one end of a socketpair for Go's poller.
func unixConn(fd int, name string) (*net.UnixConn, error) {
	file := os.NewFile(uintptr(fd), name)
	conn, err := net.FileConn(file)
	file.Close()
	if err != nil {
		return nil, err
	}
	return conn.(*net.UnixConn), nil
}

// streamPair connects conn to a new socketpair and returns the app's end.
// Whichever side closes first closes both: AnyRemote never half-closes.
func streamPair(conn net.Conn) (int, error) {
	fds, err := socketpair(syscall.SOCK_STREAM, streamBuffer)
	if err != nil {
		return -1, err
	}
	local, err := unixConn(fds[1], "anyremote-stream")
	if err != nil {
		syscall.Close(fds[0])
		return -1, err
	}
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			conn.Close()
			local.Close()
		})
	}
	go func() {
		defer closeBoth()
		io.Copy(local, conn)
	}()
	go func() {
		defer closeBoth()
		io.Copy(conn, local)
	}()
	return fds[0], nil
}

// acceptRecordSize is one accepted connection on a listener's socket: the
// connection's descriptor (big-endian int32), the length of the remote
// address, and the address ("ip:port"), zero-padded.
const acceptRecordSize = 64

func acceptRecord(fd int, remote string) []byte {
	record := make([]byte, acceptRecordSize)
	binary.BigEndian.PutUint32(record, uint32(int32(fd)))
	if len(remote) > acceptRecordSize-5 {
		remote = remote[:acceptRecordSize-5]
	}
	record[4] = byte(len(remote))
	copy(record[5:], remote)
	return record
}

// listen accepts TCP connections on port and returns the app's end of the
// listener's socket. Closing that end stops listening.
func listen(server *tsnet.Server, port uint16) (int, error) {
	listener, err := server.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return -1, err
	}
	fds, err := socketpair(syscall.SOCK_STREAM, 0)
	if err != nil {
		listener.Close()
		return -1, err
	}
	channel, err := unixConn(fds[1], "anyremote-listener")
	if err != nil {
		listener.Close()
		syscall.Close(fds[0])
		return -1, err
	}
	var once sync.Once
	stop := func() {
		once.Do(func() {
			listener.Close()
			channel.Close()
		})
	}
	go func() {
		// The app never writes: this returns once it closed its end.
		var buffer [1]byte
		channel.Read(buffer[:])
		stop()
	}()
	go func() {
		defer stop()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			fd, err := streamPair(conn)
			if err != nil {
				conn.Close()
				continue
			}
			if _, err := channel.Write(acceptRecord(fd, conn.RemoteAddr().String())); err != nil {
				syscall.Close(fd)
				return
			}
		}
	}()
	return fds[0], nil
}

// dial connects to address ("ip:port") over the tailnet and returns the
// app's end of the connection.
func dial(server *tsnet.Server, address string, timeout time.Duration) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	conn, err := server.Dial(ctx, "tcp", address)
	if err != nil {
		return -1, err
	}
	fd, err := streamPair(conn)
	if err != nil {
		conn.Close()
		return -1, err
	}
	return fd, nil
}

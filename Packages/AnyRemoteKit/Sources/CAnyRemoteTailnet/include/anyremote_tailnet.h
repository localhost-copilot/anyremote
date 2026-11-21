// The embedded Tailscale node (Tailnet/, a Go C archive linked into the
// app by scripts/build-tailnet.sh). The declarations match the ones cgo
// generates for Tailnet/tailnet.go exactly (hence `char *`, not `const`);
// the build script compiles both headers together to check that.
//
// Functions returning int return 0 on success, or -1 with *error_out set to
// a message to free() (when error_out isn't NULL). Strings returned are
// freed with free(). Any thread may call any function.

#ifndef ANYREMOTE_TAILNET_H
#define ANYREMOTE_TAILNET_H

#include <stdint.h>

// Starts this process's node, keeping its state in state_dir. control_url
// and auth_key may be NULL (Tailscale's control server; interactive login,
// whose URL then appears in the status). Does nothing if already running.
extern int ar_tailnet_start(char *state_dir, char *hostname, char *control_url, char *auth_key, char **error_out);

// Stops the node; its sockets close.
extern void ar_tailnet_stop(void);

// Starts an interactive login (again): the status carries its URL.
extern int ar_tailnet_login(char **error_out);

// Signs this device out of the tailnet.
extern int ar_tailnet_logout(char **error_out);

// The node's state, this device and its peers as JSON (TailnetStatus);
// NULL when the node isn't running.
extern char *ar_tailnet_status(void);

// Listens for TCP connections on port. *fd_out receives a stream socket on
// which each accepted connection arrives as a 64-byte record: its
// descriptor (big-endian int32), the length of the remote address and the
// address ("ip:port"). Closing that socket stops listening.
extern int ar_tailnet_listen(uint16_t port, int *fd_out, char **error_out);

// Connects to address ("ip:port", IPv6 in brackets) over the tailnet,
// waiting up to timeout_ms. *fd_out receives a connected stream socket.
extern int ar_tailnet_dial(char *address, int timeout_ms, int *fd_out, char **error_out);

// Opens UDP port on this node (0: any free one; *bound_port_out receives
// it). *fd_out receives a datagram socket; each datagram on it is framed as
// family (4 or 6), the peer's port (big-endian), its address (4 or 16 bytes)
// and the UDP payload: the sender coming in, the destination going out.
extern int ar_tailnet_open_datagram(uint16_t port, uint16_t *bound_port_out, int *fd_out, char **error_out);

// Closes a port opened with ar_tailnet_open_datagram.
extern void ar_tailnet_close_datagram(uint16_t port);

#endif

// Thin wrappers around macOS serial ioctls whose request codes are
// function-like macros (_IOW/_IO) that Swift cannot import directly.

#ifndef CSERIAL_H
#define CSERIAL_H

#include <stdint.h>

/// Opens a serial device in raw mode. Returns the fd, or -1 (errno set).
int cserial_open(const char *path);

/// Applies 8 data bits, the given parity ('N', 'E', 'O') and stop bits (1 or 2),
/// raw mode, no flow control. Any baud rate is accepted: standard rates go
/// through termios, others through IOSSIOSPEED. Returns 0 or -1 (errno set).
int cserial_configure(int fd, uint32_t baud, char parity, int stopbits);

/// Asks the driver to deliver received bytes after at most `microseconds`.
/// Lowers the default USB latency of FTDI adapters. Returns 0 or -1.
int cserial_set_read_latency(int fd, uint32_t microseconds);

/// Sets the DTR and RTS modem control lines. Returns 0 or -1.
int cserial_set_control_lines(int fd, int dtr, int rts);

/// Turns a break condition on or off. Returns 0 or -1.
int cserial_set_break(int fd, int on);

/// Number of bytes waiting in the receive buffer, or -1.
int cserial_bytes_available(int fd);

/// Discards pending input (which: 0 = input, 1 = output, 2 = both).
int cserial_flush(int fd, int which);

/// Waits up to `timeout_ms` for the fd to become readable.
/// Returns 1 if readable, 0 on timeout, -1 on error.
int cserial_wait_readable(int fd, int timeout_ms);

/// Waits until all queued output has been transmitted.
int cserial_drain(int fd);

/// Releases exclusive access and closes the fd.
int cserial_close(int fd);

/// Creates a raw pseudo terminal pair for the virtual ECU. On success returns 0,
/// stores the controller fd in *controller and the device path (e.g. /dev/ttys012)
/// in `name`. The device side stays open in *device so the pair survives until
/// the client opens it; close it after the client connected.
int cserial_openpty(int *controller, int *device, char *name, int name_len);

#endif

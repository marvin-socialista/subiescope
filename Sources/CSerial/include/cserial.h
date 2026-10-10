// Thin wrappers around macOS serial ioctls whose request codes are
// function-like macros (_IOW/_IO) that Swift cannot import directly.
//
// On Windows the same functions work on COM ports (cserial_win.c). The numbers they
// hand out there are not file descriptors: use them with these functions only.

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

/// Reads bytes that are waiting (call cserial_wait_readable first). Returns how many,
/// 0 when the other side went away, or -1 (errno set).
int cserial_read(int fd, void *buffer, int count);

/// Writes bytes. Returns how many were taken, or -1 (errno set).
int cserial_write(int fd, const void *buffer, int count);

/// Waits until all queued output has been transmitted.
int cserial_drain(int fd);

/// Releases exclusive access and closes the fd.
int cserial_close(int fd);

/// Creates a raw pseudo terminal pair for the virtual ECU. On success returns 0,
/// stores the controller fd in *controller and the device path (e.g. /dev/ttys012)
/// in `name`. The device side stays open in *device so the pair survives until
/// the client opens it; close it after the client connected.
///
/// Windows has no pseudo terminals. There the pair is two queues in memory, the name
/// is "sim:N", only this process can open it, and *device is -1.
int cserial_openpty(int *controller, int *device, char *name, int name_len);

/// Closes one end of a pseudo terminal pair, or a socket.
int cserial_release(int fd);

#ifdef _WIN32

/// Connects to a TCP port within `timeout_ms`. Returns a number for the functions above, or -1 (errno set).
int cserial_tcp_connect(const char *host, int port, int timeout_ms);

/// Listens on 127.0.0.1. Port 0 picks a free one; the port in use is stored in *bound_port.
int cserial_tcp_listen(int port, int *bound_port);

/// A local socket (AF_UNIX) at a file path, for the remote control.
int cserial_local_listen(const char *path);
int cserial_local_connect(const char *path);

/// Waits for the next client of a listening socket. Returns -1 once the listener is closed.
int cserial_accept(int listener);

/// The serial ports of this PC, one per line, fields separated by tabs: port name (COM4),
/// friendly name, manufacturer, device instance id, the parent's instance id, product name
/// as the USB device reports it. Returns the length of the whole text; call again with a
/// larger buffer when that is `size` or more.
int cserial_list_ports(char *text, int size);

/// The USB devices of this PC, in the same form: device instance id, description,
/// manufacturer, product name as the device reports it, driver service (empty without a driver).
int cserial_list_usb_devices(char *text, int size);

/// The latency timer of an FTDI cable's driver in milliseconds (how long it holds received
/// bytes back), or -1 when the port is not an FTDI one. `port` is the name, e.g. "COM4".
int cserial_ftdi_latency(const char *port);

/// The name of a paired Bluetooth device, by its address as twelve hex digits. Returns the
/// length of the name, or 0 when Windows does not know the device.
int cserial_bluetooth_name(const char *address, char *name, int size);

/// Windows' own name for the time zone the PC is set to ("W. Europe Standard Time"). Returns its length.
int cserial_time_zone_name(char *name, int size);

/// How many seconds the PC's clock is ahead of GMT right now.
int cserial_time_zone_offset(void);

/// 1 when a process with this id is running.
int cserial_process_alive(int pid);

#endif

#endif

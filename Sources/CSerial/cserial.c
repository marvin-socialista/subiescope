#ifndef _WIN32

#include "cserial.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <IOKit/serial/ioss.h>
#include <util.h>

int cserial_open(const char *path)
{
	// O_NONBLOCK so open() does not wait for DCD; cleared again below.
	int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0)
		return -1;
	if (ioctl(fd, TIOCEXCL) == -1) {
		// Not fatal: pseudo terminals used by the virtual ECU refuse it.
	}
	int flags = fcntl(fd, F_GETFL);
	if (flags == -1 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == -1) {
		int saved = errno;
		close(fd);
		errno = saved;
		return -1;
	}
	return fd;
}

static speed_t standard_speed(uint32_t baud)
{
	switch (baud) {
	case 300: return B300;
	case 600: return B600;
	case 1200: return B1200;
	case 1800: return B1800;
	case 2400: return B2400;
	case 4800: return B4800;
	case 9600: return B9600;
	case 19200: return B19200;
	case 38400: return B38400;
	case 57600: return B57600;
	case 115200: return B115200;
	case 230400: return B230400;
	default: return 0;
	}
}

int cserial_configure(int fd, uint32_t baud, char parity, int stopbits)
{
	struct termios tio;
	if (tcgetattr(fd, &tio) == -1)
		return -1;
	cfmakeraw(&tio);
	tio.c_cflag &= ~(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS);
	tio.c_cflag |= CS8 | CLOCAL | CREAD;
	if (parity == 'E') {
		tio.c_cflag |= PARENB;
	} else if (parity == 'O') {
		tio.c_cflag |= PARENB | PARODD;
	}
	if (stopbits == 2)
		tio.c_cflag |= CSTOPB;
	tio.c_iflag = IGNBRK | IGNPAR;
	tio.c_oflag = 0;
	tio.c_lflag = 0;
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 0;

	speed_t std = standard_speed(baud);
	cfsetspeed(&tio, std ? std : B9600);
	if (tcsetattr(fd, TCSANOW, &tio) == -1)
		return -1;
	if (!std) {
		// Must come after tcsetattr, which would otherwise reset it.
		speed_t custom = baud;
		if (ioctl(fd, IOSSIOSPEED, &custom) == -1)
			return -1;
	}
	return 0;
}

int cserial_set_read_latency(int fd, uint32_t microseconds)
{
	unsigned long us = microseconds;
	return ioctl(fd, IOSSDATALAT, &us);
}

int cserial_set_control_lines(int fd, int dtr, int rts)
{
	int status = 0;
	if (ioctl(fd, TIOCMGET, &status) == -1)
		return -1;
	if (dtr) status |= TIOCM_DTR; else status &= ~TIOCM_DTR;
	if (rts) status |= TIOCM_RTS; else status &= ~TIOCM_RTS;
	return ioctl(fd, TIOCMSET, &status);
}

int cserial_set_break(int fd, int on)
{
	return ioctl(fd, on ? TIOCSBRK : TIOCCBRK);
}

int cserial_bytes_available(int fd)
{
	int n = 0;
	if (ioctl(fd, FIONREAD, &n) == -1)
		return -1;
	return n;
}

int cserial_flush(int fd, int which)
{
	int queue = which == 0 ? TCIFLUSH : (which == 1 ? TCOFLUSH : TCIOFLUSH);
	return tcflush(fd, queue);
}

int cserial_wait_readable(int fd, int timeout_ms)
{
	struct pollfd p = { .fd = fd, .events = POLLIN, .revents = 0 };
	for (;;) {
		int r = poll(&p, 1, timeout_ms);
		if (r == -1 && errno == EINTR)
			continue;
		if (r <= 0)
			return r;
		if (p.revents & (POLLERR | POLLNVAL))
			return -1;
		// POLLHUP with no data means the device went away.
		if ((p.revents & POLLHUP) && !(p.revents & POLLIN))
			return -1;
		return 1;
	}
}

int cserial_read(int fd, void *buffer, int count)
{
	return (int)read(fd, buffer, count);
}

int cserial_write(int fd, const void *buffer, int count)
{
	return (int)write(fd, buffer, count);
}

int cserial_drain(int fd)
{
	return tcdrain(fd);
}

int cserial_close(int fd)
{
	ioctl(fd, TIOCNXCL);
	return close(fd);
}

int cserial_openpty(int *controller, int *device, char *name, int name_len)
{
	char path[128] = {0};
	struct termios tio;
	cfmakeraw(&tio);
	tio.c_cflag |= CLOCAL | CREAD;
	if (openpty(controller, device, path, &tio, NULL) == -1)
		return -1;
	strncpy(name, path, name_len - 1);
	name[name_len - 1] = 0;
	return 0;
}

int cserial_release(int fd)
{
	return close(fd);
}

#endif

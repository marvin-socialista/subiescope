// The Windows side of the serial shim: COM ports, a stand-in for the pseudo terminal
// the virtual ECU lives on, and the sockets the rest of SSMKit needs.
//
// Everything is handed out as a small number, so the Swift code can treat it like the
// file descriptors it uses on a Mac.

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#define _WINSOCK_DEPRECATED_NO_WARNINGS

#include <winsock2.h>
#include <ws2tcpip.h>
#include <afunix.h>
#include <windows.h>
#include <initguid.h>
#include <devguid.h>
#include <devpkey.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <timeapi.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cserial.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "cfgmgr32.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "advapi32.lib")

enum kind { KIND_FREE = 0, KIND_COM, KIND_CONTROLLER, KIND_DEVICE, KIND_SOCKET };

#define SLOTS 256
#define QUEUE_SIZE 65536

// What stands in for a pseudo terminal: two byte queues between a simulator (the
// controller) and whoever opens the device.
struct pair {
	SRWLOCK lock;
	CONDITION_VARIABLE changed;
	unsigned char *to_controller, *to_device;
	int to_controller_count, to_device_count;
	int controller_open, device_open;
};

struct entry {
	enum kind kind;
	HANDLE handle;
	SOCKET socket;
	struct pair *pair;
	// A COM port is read ahead into `buffer`, so that waiting for bytes and reading
	// them can stay two steps, as with poll() and read().
	OVERLAPPED reading, writing;
	int read_pending;
	unsigned char buffer[4096];
	DWORD buffered, taken;
};

static SRWLOCK table_lock = SRWLOCK_INIT;
static struct entry table[SLOTS];
static int next_slot;
static struct pair **pairs;
static int pair_count, pair_capacity;
static INIT_ONCE started = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK start(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
	WSADATA data;
	WSAStartup(MAKEWORD(2, 2), &data);
	// Windows otherwise rounds every short wait up to its 15.6 ms timer tick, which is
	// longer than a whole message takes on the K-line.
	timeBeginPeriod(1);
	return TRUE;
}

static int fail(DWORD error)
{
	switch (error) {
	case ERROR_FILE_NOT_FOUND:
	case ERROR_PATH_NOT_FOUND:
		errno = ENOENT;
		break;
	case ERROR_SHARING_VIOLATION:
		errno = EBUSY;
		break;
	case ERROR_INVALID_PARAMETER:
	case ERROR_INVALID_HANDLE:
		errno = EINVAL;
		break;
	// What a read or a write reports once the cable has been pulled out.
	case ERROR_ACCESS_DENIED:
	case ERROR_BAD_COMMAND:
	case ERROR_GEN_FAILURE:
	case ERROR_DEVICE_REMOVED:
	case ERROR_DEVICE_NOT_CONNECTED:
	case ERROR_OPERATION_ABORTED:
	case ERROR_NOT_READY:
	case ERROR_BROKEN_PIPE:
		errno = ENXIO;
		break;
	default:
		errno = EIO;
	}
	return -1;
}

static int allocate(enum kind kind)
{
	InitOnceExecuteOnce(&started, start, NULL, NULL);
	AcquireSRWLockExclusive(&table_lock);
	int found = -1;
	// Slots are taken in turn, so a number that was just closed is not handed out
	// again while another thread may still be waiting on it.
	for (int i = 0; i < SLOTS; i++) {
		int slot = (next_slot + i) % SLOTS;
		if (table[slot].kind == KIND_FREE) {
			found = slot;
			break;
		}
	}
	if (found >= 0) {
		struct entry *e = &table[found];
		HANDLE reading = e->reading.hEvent, writing = e->writing.hEvent;
		memset(e, 0, sizeof *e);
		e->reading.hEvent = reading ? reading : CreateEventW(NULL, TRUE, FALSE, NULL);
		e->writing.hEvent = writing ? writing : CreateEventW(NULL, TRUE, FALSE, NULL);
		ResetEvent(e->reading.hEvent);
		ResetEvent(e->writing.hEvent);
		e->handle = INVALID_HANDLE_VALUE;
		e->socket = INVALID_SOCKET;
		e->kind = kind;
		next_slot = (found + 1) % SLOTS;
	}
	ReleaseSRWLockExclusive(&table_lock);
	if (found < 0)
		errno = EMFILE;
	return found;
}

static struct entry *lookup(int fd)
{
	if (fd < 0 || fd >= SLOTS || table[fd].kind == KIND_FREE) {
		errno = EBADF;
		return NULL;
	}
	return &table[fd];
}

static void release_slot(struct entry *e)
{
	AcquireSRWLockExclusive(&table_lock);
	e->kind = KIND_FREE;
	ReleaseSRWLockExclusive(&table_lock);
}

static int adopt(SOCKET s)
{
	int fd = allocate(KIND_SOCKET);
	if (fd < 0) {
		closesocket(s);
		return -1;
	}
	table[fd].socket = s;
	return fd;
}

static double seconds_now(void)
{
	static LARGE_INTEGER frequency;
	LARGE_INTEGER now;
	if (!frequency.QuadPart)
		QueryPerformanceFrequency(&frequency);
	QueryPerformanceCounter(&now);
	return (double)now.QuadPart / (double)frequency.QuadPart;
}

// How long is left until `deadline`, in the milliseconds a wait takes.
static DWORD remaining(int timeout_ms, double deadline)
{
	if (timeout_ms < 0)
		return INFINITE;
	double left = (deadline - seconds_now()) * 1000.0;
	return left <= 0 ? 0 : (DWORD)(left + 0.999);
}

// MARK: The stand-in for a pseudo terminal

int cserial_openpty(int *controller, int *device, char *name, int name_len)
{
	struct pair *p = calloc(1, sizeof *p);
	if (!p) {
		errno = ENOMEM;
		return -1;
	}
	p->to_controller = malloc(QUEUE_SIZE);
	p->to_device = malloc(QUEUE_SIZE);
	if (!p->to_controller || !p->to_device) {
		free(p->to_controller);
		free(p->to_device);
		free(p);
		errno = ENOMEM;
		return -1;
	}
	InitializeSRWLock(&p->lock);
	InitializeConditionVariable(&p->changed);
	p->controller_open = 1;

	int fd = allocate(KIND_CONTROLLER);
	if (fd < 0) {
		free(p->to_controller);
		free(p->to_device);
		free(p);
		return -1;
	}
	table[fd].pair = p;

	AcquireSRWLockExclusive(&table_lock);
	if (pair_count == pair_capacity) {
		int capacity = pair_capacity ? pair_capacity * 2 : 64;
		struct pair **grown = realloc(pairs, capacity * sizeof *grown);
		if (!grown) {
			ReleaseSRWLockExclusive(&table_lock);
			cserial_release(fd);
			errno = ENOMEM;
			return -1;
		}
		pairs = grown;
		pair_capacity = capacity;
	}
	int number = pair_count;
	pairs[pair_count++] = p;
	ReleaseSRWLockExclusive(&table_lock);

	*controller = fd;
	*device = -1;
	snprintf(name, name_len, "sim:%d", number);
	return 0;
}

static int open_device(const char *path)
{
	int number = atoi(path + 4);
	AcquireSRWLockShared(&table_lock);
	struct pair *p = number >= 0 && number < pair_count ? pairs[number] : NULL;
	ReleaseSRWLockShared(&table_lock);
	if (!p) {
		errno = ENOENT;
		return -1;
	}
	AcquireSRWLockExclusive(&p->lock);
	if (!p->controller_open) {
		ReleaseSRWLockExclusive(&p->lock);
		errno = ENOENT;
		return -1;
	}
	p->device_open++;
	ReleaseSRWLockExclusive(&p->lock);

	int fd = allocate(KIND_DEVICE);
	if (fd < 0) {
		AcquireSRWLockExclusive(&p->lock);
		p->device_open--;
		ReleaseSRWLockExclusive(&p->lock);
		return -1;
	}
	table[fd].pair = p;
	return fd;
}

// Waits for bytes going to one side of a pair. 1: there are some, 0: not within the
// time, -1: this side was closed, or (for the device) the simulator is gone.
static int pair_wait(struct entry *e, int timeout_ms)
{
	struct pair *p = e->pair;
	int controller = e->kind == KIND_CONTROLLER;
	double deadline = seconds_now() + timeout_ms / 1000.0;
	int result;
	AcquireSRWLockExclusive(&p->lock);
	for (;;) {
		if (controller ? !p->controller_open : !p->controller_open || !p->device_open) {
			result = -1;
			break;
		}
		if ((controller ? p->to_controller_count : p->to_device_count) > 0) {
			result = 1;
			break;
		}
		DWORD wait = remaining(timeout_ms, deadline);
		if (wait == 0 || !SleepConditionVariableSRW(&p->changed, &p->lock, wait, 0)) {
			result = controller ? (p->controller_open ? 0 : -1) : (p->controller_open && p->device_open ? 0 : -1);
			// Something may have arrived just as the time ran out.
			if (result == 0 && (controller ? p->to_controller_count : p->to_device_count) > 0)
				result = 1;
			break;
		}
	}
	ReleaseSRWLockExclusive(&p->lock);
	if (result < 0)
		errno = ENXIO;
	return result;
}

static int pair_read(struct entry *e, void *buffer, int count)
{
	if (pair_wait(e, -1) < 0)
		return e->kind == KIND_DEVICE ? 0 : -1;
	struct pair *p = e->pair;
	AcquireSRWLockExclusive(&p->lock);
	unsigned char *queue = e->kind == KIND_CONTROLLER ? p->to_controller : p->to_device;
	int *queued = e->kind == KIND_CONTROLLER ? &p->to_controller_count : &p->to_device_count;
	int n = count < *queued ? count : *queued;
	if (n > 0 && queue) {
		memcpy(buffer, queue, n);
		memmove(queue, queue + n, *queued - n);
		*queued -= n;
	}
	ReleaseSRWLockExclusive(&p->lock);
	return n;
}

static int pair_write(struct entry *e, const void *buffer, int count)
{
	struct pair *p = e->pair;
	int controller = e->kind == KIND_CONTROLLER;
	AcquireSRWLockExclusive(&p->lock);
	if (!p->controller_open) {
		ReleaseSRWLockExclusive(&p->lock);
		errno = ENXIO;
		return -1;
	}
	// A simulator talks whether or not anyone listens: without a listener, and when the
	// listener has stopped reading, what it says is dropped.
	if (!controller || p->device_open) {
		unsigned char *queue = controller ? p->to_device : p->to_controller;
		int *queued = controller ? &p->to_device_count : &p->to_controller_count;
		int room = QUEUE_SIZE - *queued;
		int n = count < room ? count : room;
		if (n > 0) {
			memcpy(queue + *queued, buffer, n);
			*queued += n;
			WakeAllConditionVariable(&p->changed);
		}
	}
	ReleaseSRWLockExclusive(&p->lock);
	return count;
}

static void pair_discard(struct entry *e, int input, int output)
{
	struct pair *p = e->pair;
	int controller = e->kind == KIND_CONTROLLER;
	AcquireSRWLockExclusive(&p->lock);
	// The device's input is what the simulator has sent it.
	if (controller ? input : output)
		p->to_controller_count = 0;
	if (controller ? output : input)
		p->to_device_count = 0;
	ReleaseSRWLockExclusive(&p->lock);
}

static void pair_close(struct entry *e)
{
	struct pair *p = e->pair;
	AcquireSRWLockExclusive(&p->lock);
	if (e->kind == KIND_CONTROLLER) {
		p->controller_open = 0;
	} else if (p->device_open > 0) {
		p->device_open--;
		// The next one to open the device starts with nothing left over.
		if (p->device_open == 0)
			p->to_controller_count = p->to_device_count = 0;
	}
	if (!p->controller_open && !p->device_open) {
		// The small part stays, for a thread that is still waiting on it.
		free(p->to_controller);
		free(p->to_device);
		p->to_controller = p->to_device = NULL;
		p->to_controller_count = p->to_device_count = 0;
	}
	WakeAllConditionVariable(&p->changed);
	ReleaseSRWLockExclusive(&p->lock);
}

// MARK: COM ports

int cserial_open(const char *path)
{
	if (strncmp(path, "sim:", 4) == 0)
		return open_device(path);

	// "COM10" and up only open with the device prefix; it does no harm on the others.
	char full[300];
	if (strncmp(path, "\\\\.\\", 4) == 0)
		snprintf(full, sizeof full, "%s", path);
	else
		snprintf(full, sizeof full, "\\\\.\\%s", path);
	wchar_t wide[300];
	if (!MultiByteToWideChar(CP_UTF8, 0, full, -1, wide, 300)) {
		errno = EINVAL;
		return -1;
	}
	HANDLE handle = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
	if (handle == INVALID_HANDLE_VALUE) {
		DWORD error = GetLastError();
		// Another program has the port open.
		if (error == ERROR_ACCESS_DENIED) {
			errno = EBUSY;
			return -1;
		}
		return fail(error);
	}
	int fd = allocate(KIND_COM);
	if (fd < 0) {
		CloseHandle(handle);
		return -1;
	}
	table[fd].handle = handle;
	SetupComm(handle, 16384, 16384);
	return fd;
}

int cserial_configure(int fd, uint32_t baud, char parity, int stopbits)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (e->kind != KIND_COM)
		return 0;

	DCB dcb;
	memset(&dcb, 0, sizeof dcb);
	dcb.DCBlength = sizeof dcb;
	if (!GetCommState(e->handle, &dcb))
		return fail(GetLastError());
	dcb.BaudRate = baud;
	dcb.ByteSize = 8;
	dcb.Parity = parity == 'E' ? EVENPARITY : (parity == 'O' ? ODDPARITY : NOPARITY);
	dcb.StopBits = stopbits == 2 ? TWOSTOPBITS : ONESTOPBIT;
	dcb.fBinary = TRUE;
	dcb.fParity = parity == 'E' || parity == 'O';
	dcb.fOutxCtsFlow = FALSE;
	dcb.fOutxDsrFlow = FALSE;
	dcb.fDsrSensitivity = FALSE;
	dcb.fDtrControl = DTR_CONTROL_ENABLE;
	dcb.fRtsControl = RTS_CONTROL_DISABLE;
	dcb.fOutX = FALSE;
	dcb.fInX = FALSE;
	dcb.fTXContinueOnXoff = TRUE;
	dcb.fErrorChar = FALSE;
	dcb.fNull = FALSE;
	// A BREAK on the K-line comes back as an error on the receiving side; it must not
	// stop the port.
	dcb.fAbortOnError = FALSE;
	if (!SetCommState(e->handle, &dcb))
		return fail(GetLastError());

	// A read comes back as soon as there is at least one byte, and waits for one otherwise.
	COMMTIMEOUTS timeouts = { MAXDWORD, MAXDWORD, MAXDWORD - 1, 0, 5000 };
	if (!SetCommTimeouts(e->handle, &timeouts))
		return fail(GetLastError());
	return 0;
}

int cserial_set_read_latency(int fd, uint32_t microseconds)
{
	// An FTDI cable's latency timer is a setting of its driver on Windows (Device Manager,
	// the port's advanced settings). It cannot be changed through the open port.
	errno = ENOTSUP;
	return -1;
}

int cserial_set_control_lines(int fd, int dtr, int rts)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (e->kind != KIND_COM)
		return 0;
	BOOL ok = EscapeCommFunction(e->handle, dtr ? SETDTR : CLRDTR);
	ok = EscapeCommFunction(e->handle, rts ? SETRTS : CLRRTS) && ok;
	return ok ? 0 : fail(GetLastError());
}

int cserial_set_break(int fd, int on)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (e->kind != KIND_COM)
		return 0;
	if (!(on ? SetCommBreak(e->handle) : ClearCommBreak(e->handle)))
		return fail(GetLastError());
	return 0;
}

// Ends the read that is waiting for bytes, and drops what it had.
static void com_cancel_read(struct entry *e)
{
	if (e->read_pending) {
		DWORD count = 0;
		CancelIoEx(e->handle, &e->reading);
		GetOverlappedResult(e->handle, &e->reading, &count, TRUE);
		e->read_pending = 0;
	}
	e->buffered = e->taken = 0;
}

// Reads ahead into the buffer. 1: there are bytes, 0: none within the time, -1: the port is gone.
static int com_fill(struct entry *e, int timeout_ms)
{
	if (e->taken < e->buffered)
		return 1;
	e->buffered = e->taken = 0;
	double deadline = seconds_now() + timeout_ms / 1000.0;
	for (;;) {
		DWORD count = 0;
		if (!e->read_pending) {
			if (ReadFile(e->handle, e->buffer, sizeof e->buffer, &count, &e->reading)) {
				if (count > 0) {
					e->buffered = count;
					return 1;
				}
				// A driver that does not wait for the first byte itself: wait here.
				if (remaining(timeout_ms, deadline) == 0)
					return 0;
				Sleep(1);
				continue;
			}
			DWORD error = GetLastError();
			if (error != ERROR_IO_PENDING)
				return fail(error);
			e->read_pending = 1;
		}
		DWORD waited = WaitForSingleObject(e->reading.hEvent, remaining(timeout_ms, deadline));
		if (waited == WAIT_TIMEOUT)
			return 0;
		if (waited != WAIT_OBJECT_0)
			return fail(GetLastError());
		BOOL ok = GetOverlappedResult(e->handle, &e->reading, &count, FALSE);
		e->read_pending = 0;
		if (!ok)
			return fail(GetLastError());
		if (count > 0) {
			e->buffered = count;
			return 1;
		}
		if (remaining(timeout_ms, deadline) == 0)
			return 0;
	}
}

int cserial_bytes_available(int fd)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (e->kind == KIND_COM) {
		DWORD errors = 0;
		COMSTAT status;
		memset(&status, 0, sizeof status);
		if (!ClearCommError(e->handle, &errors, &status))
			return fail(GetLastError());
		return (int)(e->buffered - e->taken + status.cbInQue);
	}
	if (e->kind == KIND_SOCKET) {
		u_long waiting = 0;
		if (ioctlsocket(e->socket, FIONREAD, &waiting) != 0)
			return -1;
		return (int)waiting;
	}
	struct pair *p = e->pair;
	AcquireSRWLockShared(&p->lock);
	int n = e->kind == KIND_CONTROLLER ? p->to_controller_count : p->to_device_count;
	ReleaseSRWLockShared(&p->lock);
	return n;
}

int cserial_flush(int fd, int which)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	int input = which == 0 || which == 2, output = which == 1 || which == 2;
	if (e->kind == KIND_COM) {
		if (input)
			com_cancel_read(e);
		DWORD flags = (input ? PURGE_RXCLEAR | PURGE_RXABORT : 0) | (output ? PURGE_TXCLEAR | PURGE_TXABORT : 0);
		return PurgeComm(e->handle, flags) ? 0 : fail(GetLastError());
	}
	if (e->kind == KIND_CONTROLLER || e->kind == KIND_DEVICE)
		pair_discard(e, input, output);
	return 0;
}

int cserial_wait_readable(int fd, int timeout_ms)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (e->kind == KIND_COM)
		return com_fill(e, timeout_ms);
	if (e->kind == KIND_SOCKET) {
		fd_set readable;
		FD_ZERO(&readable);
		FD_SET(e->socket, &readable);
		struct timeval time = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
		int n = select(0, &readable, NULL, NULL, timeout_ms < 0 ? NULL : &time);
		if (n < 0) {
			errno = ENXIO;
			return -1;
		}
		return n > 0 ? 1 : 0;
	}
	return pair_wait(e, timeout_ms);
}

int cserial_read(int fd, void *buffer, int count)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (count <= 0)
		return 0;
	if (e->kind == KIND_COM) {
		if (com_fill(e, -1) <= 0)
			return -1;
		DWORD n = e->buffered - e->taken;
		if (n > (DWORD)count)
			n = (DWORD)count;
		memcpy(buffer, e->buffer + e->taken, n);
		e->taken += n;
		return (int)n;
	}
	if (e->kind == KIND_SOCKET) {
		int n = recv(e->socket, buffer, count, 0);
		if (n < 0) {
			// The time set for the socket ran out, or the other side dropped the connection.
			errno = WSAGetLastError() == WSAETIMEDOUT ? EAGAIN : ENXIO;
			return WSAGetLastError() == WSAETIMEDOUT ? -1 : 0;
		}
		return n;
	}
	return pair_read(e, buffer, count);
}

int cserial_write(int fd, const void *buffer, int count)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (count <= 0)
		return 0;
	if (e->kind == KIND_COM) {
		DWORD written = 0;
		if (!WriteFile(e->handle, buffer, (DWORD)count, &written, &e->writing)) {
			DWORD error = GetLastError();
			if (error != ERROR_IO_PENDING)
				return fail(error);
			if (!GetOverlappedResult(e->handle, &e->writing, &written, TRUE))
				return fail(GetLastError());
		}
		if (written == 0) {
			// Nothing went out within the write timeout.
			errno = EIO;
			return -1;
		}
		return (int)written;
	}
	if (e->kind == KIND_SOCKET) {
		int n = send(e->socket, buffer, count, 0);
		if (n < 0) {
			errno = ENXIO;
			return -1;
		}
		return n;
	}
	return pair_write(e, buffer, count);
}

int cserial_drain(int fd)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	if (e->kind == KIND_COM)
		return FlushFileBuffers(e->handle) ? 0 : fail(GetLastError());
	return 0;
}

int cserial_release(int fd)
{
	struct entry *e = lookup(fd);
	if (!e)
		return -1;
	switch (e->kind) {
	case KIND_COM: {
		HANDLE handle = e->handle;
		CancelIoEx(handle, NULL);
		if (e->read_pending) {
			DWORD count = 0;
			GetOverlappedResult(handle, &e->reading, &count, TRUE);
			e->read_pending = 0;
		}
		e->handle = INVALID_HANDLE_VALUE;
		CloseHandle(handle);
		break;
	}
	case KIND_SOCKET: {
		SOCKET s = e->socket;
		e->socket = INVALID_SOCKET;
		shutdown(s, SD_BOTH);
		closesocket(s);
		break;
	}
	case KIND_CONTROLLER:
	case KIND_DEVICE:
		pair_close(e);
		break;
	default:
		break;
	}
	release_slot(e);
	return 0;
}

int cserial_close(int fd)
{
	return cserial_release(fd);
}

// MARK: Sockets

int cserial_tcp_connect(const char *host, int port, int timeout_ms)
{
	InitOnceExecuteOnce(&started, start, NULL, NULL);
	char service[16];
	snprintf(service, sizeof service, "%d", port);
	struct addrinfo hints, *list = NULL;
	memset(&hints, 0, sizeof hints);
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	if (getaddrinfo(host, service, &hints, &list) != 0 || !list) {
		errno = EHOSTUNREACH;
		return -1;
	}

	SOCKET s = INVALID_SOCKET;
	int error = WSAEHOSTUNREACH;
	for (struct addrinfo *a = list; a; a = a->ai_next) {
		s = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
		if (s == INVALID_SOCKET)
			continue;
		u_long nonblocking = 1;
		ioctlsocket(s, FIONBIO, &nonblocking);
		int result = connect(s, a->ai_addr, (int)a->ai_addrlen);
		if (result != 0 && WSAGetLastError() == WSAEWOULDBLOCK) {
			fd_set writable, failed;
			FD_ZERO(&writable);
			FD_SET(s, &writable);
			FD_ZERO(&failed);
			FD_SET(s, &failed);
			struct timeval time = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
			int n = select(0, NULL, &writable, &failed, &time);
			if (n > 0 && FD_ISSET(s, &writable)) {
				result = 0;
			} else if (n == 0) {
				error = WSAETIMEDOUT;
			} else {
				int reason = 0, length = sizeof reason;
				getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&reason, &length);
				error = reason ? reason : WSAECONNREFUSED;
			}
		} else if (result != 0) {
			error = WSAGetLastError();
		}
		if (result == 0)
			break;
		closesocket(s);
		s = INVALID_SOCKET;
	}
	freeaddrinfo(list);
	if (s == INVALID_SOCKET) {
		errno = error == WSAETIMEDOUT ? ETIMEDOUT : (error == WSAECONNREFUSED ? ECONNREFUSED : EHOSTUNREACH);
		return -1;
	}
	u_long blocking = 0;
	ioctlsocket(s, FIONBIO, &blocking);
	// Requests are a few bytes each: send them right away.
	BOOL yes = TRUE;
	setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&yes, sizeof yes);
	return adopt(s);
}

int cserial_tcp_listen(int port, int *bound_port)
{
	InitOnceExecuteOnce(&started, start, NULL, NULL);
	SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (s == INVALID_SOCKET) {
		errno = EIO;
		return -1;
	}
	struct sockaddr_in address;
	memset(&address, 0, sizeof address);
	address.sin_family = AF_INET;
	address.sin_port = htons((u_short)port);
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	int length = sizeof address;
	if (bind(s, (struct sockaddr *)&address, length) != 0 || listen(s, 4) != 0
	    || getsockname(s, (struct sockaddr *)&address, &length) != 0) {
		errno = WSAGetLastError() == WSAEADDRINUSE ? EADDRINUSE : EIO;
		closesocket(s);
		return -1;
	}
	if (bound_port)
		*bound_port = ntohs(address.sin_port);
	return adopt(s);
}

static int local_address(const char *path, struct sockaddr_un *address)
{
	memset(address, 0, sizeof *address);
	address->sun_family = AF_UNIX;
	if (strlen(path) >= sizeof address->sun_path) {
		errno = ENAMETOOLONG;
		return -1;
	}
	strcpy(address->sun_path, path);
	return 0;
}

int cserial_local_listen(const char *path)
{
	InitOnceExecuteOnce(&started, start, NULL, NULL);
	struct sockaddr_un address;
	if (local_address(path, &address) != 0)
		return -1;
	// What an earlier run left behind.
	wchar_t wide[300];
	if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 300))
		DeleteFileW(wide);
	SOCKET s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s == INVALID_SOCKET) {
		errno = EIO;
		return -1;
	}
	if (bind(s, (struct sockaddr *)&address, sizeof address) != 0 || listen(s, 4) != 0) {
		errno = EIO;
		closesocket(s);
		return -1;
	}
	return adopt(s);
}

int cserial_local_connect(const char *path)
{
	InitOnceExecuteOnce(&started, start, NULL, NULL);
	struct sockaddr_un address;
	if (local_address(path, &address) != 0)
		return -1;
	SOCKET s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s == INVALID_SOCKET) {
		errno = EIO;
		return -1;
	}
	if (connect(s, (struct sockaddr *)&address, sizeof address) != 0) {
		errno = ECONNREFUSED;
		closesocket(s);
		return -1;
	}
	return adopt(s);
}

int cserial_accept(int listener)
{
	struct entry *e = lookup(listener);
	if (!e || e->kind != KIND_SOCKET)
		return -1;
	SOCKET client = accept(e->socket, NULL, NULL);
	if (client == INVALID_SOCKET) {
		errno = ENXIO;
		return -1;
	}
	return adopt(client);
}

// MARK: What is plugged in

struct text {
	char *out;
	int size, length;
};

static void put(struct text *t, const char *bytes, int count)
{
	for (int i = 0; i < count; i++) {
		if (t->length < t->size - 1)
			t->out[t->length] = bytes[i];
		t->length++;
	}
}

// One field: the text without anything that would break the line apart.
static void put_wide(struct text *t, const wchar_t *wide)
{
	char utf8[1024];
	int n = WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, sizeof utf8, NULL, NULL);
	for (int i = 0; i + 1 < n; i++) {
		if (utf8[i] == '\t' || utf8[i] == '\n' || utf8[i] == '\r')
			utf8[i] = ' ';
	}
	if (n > 1)
		put(t, utf8, n - 1);
}

static void finish(struct text *t)
{
	if (t->size > 0)
		t->out[t->length < t->size ? t->length : t->size - 1] = 0;
}

static void property(HDEVINFO set, SP_DEVINFO_DATA *info, DWORD which, wchar_t *out, DWORD chars)
{
	memset(out, 0, chars * sizeof(wchar_t));
	SetupDiGetDeviceRegistryPropertyW(set, info, which, NULL, (PBYTE)out, (chars - 1) * sizeof(wchar_t), NULL);
}

// The product name the device itself reports ("FT232R USB UART"), not the driver's name for it.
static void reported_name(DEVINST node, wchar_t *out, ULONG chars)
{
	DEVPROPTYPE type = 0;
	ULONG size = (chars - 1) * sizeof(wchar_t);
	memset(out, 0, chars * sizeof(wchar_t));
	if (CM_Get_DevNode_PropertyW(node, &DEVPKEY_Device_BusReportedDeviceDesc, &type, (PBYTE)out, &size, 0) != CR_SUCCESS
	    || type != DEVPROP_TYPE_STRING)
		out[0] = 0;
}

int cserial_list_ports(char *out, int size)
{
	struct text t = { out, size, 0 };
	HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVCLASS_PORTS, NULL, NULL, DIGCF_PRESENT);
	if (set == INVALID_HANDLE_VALUE) {
		finish(&t);
		return 0;
	}
	SP_DEVINFO_DATA info;
	info.cbSize = sizeof info;
	for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
		wchar_t port[64] = {0};
		HKEY key = SetupDiOpenDevRegKey(set, &info, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_QUERY_VALUE);
		if (key == INVALID_HANDLE_VALUE)
			continue;
		DWORD bytes = sizeof port - sizeof(wchar_t);
		LSTATUS status = RegQueryValueExW(key, L"PortName", NULL, NULL, (LPBYTE)port, &bytes);
		RegCloseKey(key);
		// The same class holds printer ports (LPT1).
		if (status != ERROR_SUCCESS || wcsncmp(port, L"COM", 3) != 0)
			continue;

		wchar_t friendly[256], maker[256], id[512] = {0}, parent_id[512] = {0}, product[256];
		property(set, &info, SPDRP_FRIENDLYNAME, friendly, 256);
		property(set, &info, SPDRP_MFG, maker, 256);
		SetupDiGetDeviceInstanceIdW(set, &info, id, 511, NULL);
		reported_name(info.DevInst, product, 256);
		DEVINST parent = 0;
		if (CM_Get_Parent(&parent, info.DevInst, 0) == CR_SUCCESS) {
			CM_Get_Device_IDW(parent, parent_id, 511, 0);
			// An FTDI cable's port hangs under the USB device that has the name.
			if (!product[0])
				reported_name(parent, product, 256);
		}

		put_wide(&t, port);
		put(&t, "\t", 1);
		put_wide(&t, friendly);
		put(&t, "\t", 1);
		put_wide(&t, maker);
		put(&t, "\t", 1);
		put_wide(&t, id);
		put(&t, "\t", 1);
		put_wide(&t, parent_id);
		put(&t, "\t", 1);
		put_wide(&t, product);
		put(&t, "\n", 1);
	}
	SetupDiDestroyDeviceInfoList(set);
	finish(&t);
	return t.length;
}

int cserial_list_usb_devices(char *out, int size)
{
	struct text t = { out, size, 0 };
	HDEVINFO set = SetupDiGetClassDevsW(NULL, L"USB", NULL, DIGCF_PRESENT | DIGCF_ALLCLASSES);
	if (set == INVALID_HANDLE_VALUE) {
		finish(&t);
		return 0;
	}
	SP_DEVINFO_DATA info;
	info.cbSize = sizeof info;
	for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
		wchar_t id[512] = {0}, description[256], maker[256], product[256], service[256];
		if (!SetupDiGetDeviceInstanceIdW(set, &info, id, 511, NULL))
			continue;
		property(set, &info, SPDRP_DEVICEDESC, description, 256);
		property(set, &info, SPDRP_MFG, maker, 256);
		property(set, &info, SPDRP_SERVICE, service, 256);
		reported_name(info.DevInst, product, 256);

		put_wide(&t, id);
		put(&t, "\t", 1);
		put_wide(&t, description);
		put(&t, "\t", 1);
		put_wide(&t, maker);
		put(&t, "\t", 1);
		put_wide(&t, product);
		put(&t, "\t", 1);
		put_wide(&t, service);
		put(&t, "\n", 1);
	}
	SetupDiDestroyDeviceInfoList(set);
	finish(&t);
	return t.length;
}

int cserial_ftdi_latency(const char *port)
{
	wchar_t wanted[64];
	if (!MultiByteToWideChar(CP_UTF8, 0, port, -1, wanted, 64))
		return -1;
	int latency = -1;
	HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVCLASS_PORTS, NULL, NULL, DIGCF_PRESENT);
	if (set == INVALID_HANDLE_VALUE)
		return -1;
	SP_DEVINFO_DATA info;
	info.cbSize = sizeof info;
	for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
		HKEY key = SetupDiOpenDevRegKey(set, &info, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_QUERY_VALUE);
		if (key == INVALID_HANDLE_VALUE)
			continue;
		wchar_t name[64] = {0};
		DWORD bytes = sizeof name - sizeof(wchar_t);
		if (RegQueryValueExW(key, L"PortName", NULL, NULL, (LPBYTE)name, &bytes) == ERROR_SUCCESS && _wcsicmp(name, wanted) == 0) {
			DWORD value = 0, length = sizeof value, type = 0;
			if (RegQueryValueExW(key, L"LatencyTimer", NULL, &type, (LPBYTE)&value, &length) == ERROR_SUCCESS && type == REG_DWORD)
				latency = (int)value;
			RegCloseKey(key);
			break;
		}
		RegCloseKey(key);
	}
	SetupDiDestroyDeviceInfoList(set);
	return latency;
}

int cserial_bluetooth_name(const char *address, char *name, int size)
{
	char path[160];
	snprintf(path, sizeof path, "SYSTEM\\CurrentControlSet\\Services\\BTHPORT\\Parameters\\Devices\\%s", address);
	HKEY key;
	if (size <= 0 || RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS)
		return 0;
	// Stored as bytes of UTF-8 text, with or without a closing zero.
	DWORD bytes = (DWORD)size - 1, type = 0;
	LSTATUS status = RegQueryValueExA(key, "Name", NULL, &type, (LPBYTE)name, &bytes);
	RegCloseKey(key);
	if (status != ERROR_SUCCESS || bytes == 0)
		return 0;
	name[bytes] = 0;
	return (int)strlen(name);
}

int cserial_time_zone_name(char *name, int size)
{
	DYNAMIC_TIME_ZONE_INFORMATION zone;
	if (size <= 0 || GetDynamicTimeZoneInformation(&zone) == TIME_ZONE_ID_INVALID)
		return 0;
	int length = WideCharToMultiByte(CP_UTF8, 0, zone.TimeZoneKeyName, -1, name, size, NULL, NULL);
	return length > 1 ? length - 1 : 0;
}

int cserial_time_zone_offset(void)
{
	DYNAMIC_TIME_ZONE_INFORMATION zone;
	DWORD kind = GetDynamicTimeZoneInformation(&zone);
	if (kind == TIME_ZONE_ID_INVALID)
		return 0;
	LONG minutes = zone.Bias + (kind == TIME_ZONE_ID_DAYLIGHT ? zone.DaylightBias : zone.StandardBias);
	return (int)(-minutes * 60);
}

int cserial_process_alive(int pid)
{
	HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
	if (!process)
		return GetLastError() == ERROR_ACCESS_DENIED;
	DWORD code = 0;
	BOOL ok = GetExitCodeProcess(process, &code);
	CloseHandle(process);
	return ok && code == STILL_ACTIVE;
}

#endif

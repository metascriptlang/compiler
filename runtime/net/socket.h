/**
 * MetaScript Network Runtime (C Backend) — TCP Socket Primitives
 *
 * Thin POSIX wrappers for TCP socket operations.
 * All functions are static inline (header-only, no separate .c file).
 *
 * Type mapping:
 *   int32 → int32_t  (file descriptors, ports, status codes)
 *   string → msString (addresses, data)
 *
 * Error convention:
 *   int32_t returns: -1 on error, 0 on success (bind/listen/connect/timeout)
 *   int32_t returns: -1 on error, >= 0 for fd (socket/accept) or bytes (send)
 *   msString returns: MS_EMPTY_STRING on error or connection close
 */

#ifndef MS_STD_NET_H
#define MS_STD_NET_H

#ifndef MS_LIKELY
#define MS_LIKELY(x)   __builtin_expect(!!(x), 1)
#define MS_UNLIKELY(x) __builtin_expect(!!(x), 0)
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>  /* offsetof — used by _Static_assert below for layout invariants */
#include <string.h>
#include <time.h>
#include "runtime/core/system.h"

/* ===== Platform Abstraction ===== */
#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #include <windows.h>
  typedef int ms_socklen_t;
  typedef int ms_ssize_t;
  #define ms_close_socket(fd)  closesocket((SOCKET)(intptr_t)(fd))
  #define ms_errno()           WSAGetLastError()
  #define MS_EWOULDBLOCK       WSAEWOULDBLOCK
  #define MS_EINTR             WSAEINTR
  #define MS_SEND_FLAGS        0
  static inline int32_t ms_set_nonblock(int32_t fd) {
      u_long mode = 1;
      return ioctlsocket((SOCKET)(intptr_t)fd, FIONBIO, &mode) == 0 ? 0 : -1;
  }
  static inline int32_t ms_set_blocking(int32_t fd) {
      u_long mode = 0;
      return ioctlsocket((SOCKET)(intptr_t)fd, FIONBIO, &mode) == 0 ? 0 : -1;
  }
  #define MS_SOCKOPT_CAST (const char*)
  static inline struct tm* ms_gmtime(const time_t* t, struct tm* result) {
      gmtime_s(result, t); return result;
  }
  static inline void msNetEnsureInit(void) {
      static int _wsaReady = 0;
      if (!_wsaReady) { WSADATA d; WSAStartup(MAKEWORD(2,2), &d); _wsaReady = 1; }
  }
#else
  #include <errno.h>
  #include <sys/types.h>
  #include <unistd.h>
  #include <sys/socket.h>
  #include <sys/time.h>
  #include <netinet/in.h>
  #include <netinet/tcp.h>
  #include <arpa/inet.h>
  #include <netdb.h>
  #include <fcntl.h>
  typedef socklen_t ms_socklen_t;
  typedef ssize_t ms_ssize_t;
  #define ms_close_socket(fd)  close(fd)
  #define ms_errno()           errno
  #define MS_EWOULDBLOCK       EAGAIN
  #define MS_EINTR             EINTR
  /* MSG_NOSIGNAL on send() suppresses SIGPIPE atomically with the syscall —
   * no race window between accept() and per-fd setsockopt(SO_NOSIGPIPE).
   * Linux always; macOS 10.9+ and FreeBSD also expose it. Fall back to 0 on
   * platforms that lack the flag (rare modern Unixes) — those rely on the
   * per-fd SO_NOSIGPIPE set by msNetSetNoSigpipe at accept time. */
  #ifdef MSG_NOSIGNAL
    #define MS_SEND_FLAGS      MSG_NOSIGNAL
  #else
    #define MS_SEND_FLAGS      0
  #endif
  static inline int32_t ms_set_nonblock(int32_t fd) {
      int flags = fcntl(fd, F_GETFL, 0);
      return (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) ? -1 : 0;
  }
  static inline int32_t ms_set_blocking(int32_t fd) {
      int flags = fcntl(fd, F_GETFL, 0);
      return (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0) ? -1 : 0;
  }
  #define MS_SOCKOPT_CAST
  #define ms_gmtime(t, tm)     gmtime_r(t, tm)
  static inline void msNetEnsureInit(void) {}
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ===== Socket Creation ===== */

/**
 * Create a TCP socket (AF_INET, SOCK_STREAM).
 * Returns fd on success, -1 on error.
 */
static inline int32_t msNetSocket(void) {
	msNetEnsureInit();
#ifdef _WIN32
	SOCKET s = WSASocketW(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED);
	return s == INVALID_SOCKET ? -1 : (int32_t)(intptr_t)s;
#else
	return (int32_t)socket(AF_INET, SOCK_STREAM, 0);
#endif
}

/* ===== Server Operations ===== */

/**
 * Bind socket to address and port. Sets SO_REUSEADDR automatically.
 * Returns 0 on success, -1 on error.
 */
static inline int32_t msNetBind(int32_t fd, msString addr, int32_t port) {
	int opt = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, MS_SOCKOPT_CAST &opt, sizeof(opt));

	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);

	const char* addr_str = msStringToCString(addr);
	if (strcmp(addr_str, "0.0.0.0") == 0) {
		sa.sin_addr.s_addr = INADDR_ANY;
	} else {
		if (inet_pton(AF_INET, addr_str, &sa.sin_addr) != 1) return -1;
	}

	return (int32_t)bind(fd, (struct sockaddr*)&sa, sizeof(sa));
}

/**
 * Bind with SO_REUSEPORT — allows multiple threads to bind to the same port.
 * Kernel load-balances incoming connections across all threads.
 * Used by serveConcurrent() for httpbeast-style thread-per-core architecture.
 */
static inline int32_t msNetBindShared(int32_t fd, msString addr, int32_t port) {
	int opt = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, MS_SOCKOPT_CAST &opt, sizeof(opt));
#ifdef SO_REUSEPORT
	setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, MS_SOCKOPT_CAST &opt, sizeof(opt));
#endif

	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);

	const char* addr_str = msStringToCString(addr);
	if (strcmp(addr_str, "0.0.0.0") == 0) {
		sa.sin_addr.s_addr = INADDR_ANY;
	} else {
		if (inet_pton(AF_INET, addr_str, &sa.sin_addr) != 1) return -1;
	}

	return (int32_t)bind(fd, (struct sockaddr*)&sa, sizeof(sa));
}

/**
 * Listen for connections. Returns 0 on success, -1 on error.
 */
static inline int32_t msNetListen(int32_t fd, int32_t backlog) {
	return (int32_t)listen(fd, backlog);
}

/**
 * Accept a connection. Sets TCP_NODELAY on accepted socket for low latency.
 * Returns client fd on success, -1 on error.
 */
static inline int32_t msNetAccept(int32_t fd) {
	struct sockaddr_in client_addr;
	ms_socklen_t client_len = sizeof(client_addr);
	int client_fd = accept(fd, (struct sockaddr*)&client_addr, &client_len);
	if (MS_LIKELY(client_fd >= 0)) {
		int flag = 1;
		setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, MS_SOCKOPT_CAST &flag, sizeof(flag));
	}
	return (int32_t)client_fd;
}

/* ===== Client Operations ===== */

/**
 * Connect to host:port. Uses getaddrinfo for DNS resolution (supports
 * hostnames, not just IPs). Retries on EINTR, iterates address list.
 * Returns 0 on success, -1 on error.
 */
static inline int32_t msNetConnect(int32_t fd, msString host, int32_t port) {
	const char* host_str = msStringToCString(host);
	char port_str[8];
	snprintf(port_str, sizeof(port_str), "%d", port);

	struct addrinfo hints, *result, *rp;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	if (getaddrinfo(host_str, port_str, &hints, &result) != 0) return -1;

	int ret = -1;
	for (rp = result; rp != NULL; rp = rp->ai_next) {
		do {
			ret = connect(fd, rp->ai_addr, (ms_socklen_t)rp->ai_addrlen);
		} while (ret < 0 && ms_errno() == MS_EINTR);
		if (ret == 0) break;
	}

	freeaddrinfo(result);
	return (int32_t)ret;
}

/* ===== Data Transfer ===== */

/**
 * Send all data on socket. Handles short writes and EINTR.
 * Returns total bytes sent on success, -1 on error.
 */
static inline int32_t msNetSend(int32_t fd, msString data) {
	const char* buf = msStringToCString(data);
	int32_t total = 0;
	int32_t len = (int32_t)data.len;
	while (total < len) {
		ms_ssize_t n = send(fd, buf + total, (size_t)(len - total), MS_SEND_FLAGS);
		if (MS_UNLIKELY(n < 0 && ms_errno() == MS_EINTR)) continue;
		if (MS_UNLIKELY(n <= 0)) return -1;
		total += (int32_t)n;
	}
	return total;
}

/**
 * Receive up to maxBytes from socket.
 * Returns received data, or MS_EMPTY_STRING on error/connection close.
 */
static inline msString msNetRecv(int32_t fd, int32_t maxBytes) {
	if (maxBytes <= 0) return MS_EMPTY_STRING;
	if (maxBytes > 16777216) maxBytes = 16777216; /* 16 MiB cap */

	char* buf = (char*)malloc((size_t)maxBytes + 1);
	if (!buf) return MS_EMPTY_STRING;

	ms_ssize_t received;
	do {
		received = recv(fd, buf, (size_t)maxBytes, 0);
	} while (received < 0 && ms_errno() == MS_EINTR);

	if (received <= 0) {
		free(buf);
		return MS_EMPTY_STRING;
	}

	buf[received] = '\0';
	msString result = msStringNew(buf, (int64_t)received);
	free(buf);
	return result;
}

/* ===== Socket Lifecycle ===== */

/**
 * Close a socket.
 */
static inline void msNetClose(int32_t fd) {
	ms_close_socket(fd);
}

/**
 * Set send and receive timeout on socket.
 * Returns 0 on success, -1 on error.
 */
static inline int32_t msNetSetTimeout(int32_t fd, int32_t ms) {
#ifdef _WIN32
	/* Windows setsockopt SO_RCVTIMEO/SO_SNDTIMEO takes DWORD milliseconds */
	DWORD timeout = (DWORD)ms;
	int ret = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, MS_SOCKOPT_CAST &timeout, sizeof(timeout));
	if (ret != 0) return -1;
	return (int32_t)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, MS_SOCKOPT_CAST &timeout, sizeof(timeout));
#else
	struct timeval tv;
	tv.tv_sec = ms / 1000;
	tv.tv_usec = (ms % 1000) * 1000;
	int ret = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	if (ret != 0) return -1;
	return (int32_t)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
}

/* ===== Non-Blocking Variants (for event-loop servers) ===== */

/**
 * Set fd to non-blocking mode. Returns 0 on success, -1 on error.
 */
static inline int32_t msNetSetNonBlocking(int32_t fd) {
	return ms_set_nonblock(fd);
}

/**
 * Set fd to blocking mode (clears O_NONBLOCK). Returns 0 on success, -1 on error.
 * Mirror of msNetSetNonBlocking — used by protocol-switch consumers (WebSocket,
 * raw TCP takeover) that take ownership of a fd after res.detach() and want
 * blocking I/O semantics in their own worker thread.
 */
static inline int32_t msNetSetBlocking(int32_t fd) {
	return ms_set_blocking(fd);
}

/**
 * Non-blocking accept. Returns client fd, or -1 on EAGAIN/error.
 * Sets TCP_NODELAY on accepted socket.
 */
static inline int32_t msNetAcceptNonBlock(int32_t fd) {
	struct sockaddr_in ca;
	ms_socklen_t cl = sizeof(ca);
	int cfd = accept(fd, (struct sockaddr*)&ca, &cl);
	if (cfd >= 0) {
		int f = 1;
		setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, MS_SOCKOPT_CAST &f, sizeof(f));
	}
	return (int32_t)cfd;
}

/**
 * Non-blocking recv. Returns received data, or empty string on EAGAIN/close/error.
 * Uses thread-local buffer to avoid per-recv malloc+free.
 */
static _Thread_local char _msRecvTlBuf[8192];

static inline msString msNetRecvNonBlock(int32_t fd, int32_t maxBytes) {
	if (maxBytes <= 0) return MS_EMPTY_STRING;
	if (maxBytes > 8192) maxBytes = 8192;
	ms_ssize_t r = recv(fd, _msRecvTlBuf, (size_t)maxBytes, 0);
	if (r <= 0) return MS_EMPTY_STRING;
	_msRecvTlBuf[r] = '\0';
	return msStringNew(_msRecvTlBuf, (int64_t)r);
}

/**
 * Non-blocking recv directly into an msString buffer — true zero-copy recv.
 * Appends received data to dest, growing if needed. Returns bytes received, 0 on EAGAIN, -1 on close/error.
 * Eliminates ALL allocations after the first request on a connection (buffer grows once, reused).
 */
static inline int32_t msNetRecvInto(int32_t fd, msString* dest, int32_t maxBytes) {
	extern void msStringPrepareAdd(msString* s, int64_t addLen);
	if (maxBytes <= 0) return 0;
	if (maxBytes > 8192) maxBytes = 8192;
	int64_t oldLen = dest->len;
	msStringPrepareAdd(dest, (int64_t)maxBytes);
	ms_ssize_t r = recv(fd, dest->p->data + oldLen, (size_t)maxBytes, 0);
	if (r <= 0) {
		dest->p->data[oldLen] = '\0';
		dest->len = oldLen;
		if (r == 0) return -1;  /* connection closed */
		if (ms_errno() == MS_EWOULDBLOCK) return 0;
		return -1;
	}
	dest->len = oldLen + (int64_t)r;
	dest->p->data[dest->len] = '\0';
	return (int32_t)r;
}

/**
 * Recv all available data into buffer until EAGAIN. Zero-alloc after warmup.
 * Returns total bytes read, 0 on pure EAGAIN, -1 on close/error.
 * Composes msNetRecvInto in a drain loop — replaces the MetaScript recv+append pattern.
 */
static inline int32_t msNetRecvAll(msString* dest, int32_t fd) {
	int total = 0;
	while (1) {
		int32_t n = msNetRecvInto(fd, dest, 4096);
		if (n < 0) return total > 0 ? total : -1;  /* closed or error */
		if (n == 0) return total > 0 ? total : 0;   /* EAGAIN */
		total += n;
		if (n < 4096) return total;  /* short read = no more data ready */
	}
}

/**
 * Non-blocking send with offset. Returns bytes sent, 0 on EAGAIN, -1 on error.
 * Allows incremental sending from a sendQueue.
 */
static inline int32_t msNetSendNonBlock(int32_t fd, msString data, int32_t offset) {
	if (!data.p || offset >= (int32_t)data.len) return 0;
	const char* buf = data.p->data + offset;
	int32_t remaining = (int32_t)data.len - offset;
	ms_ssize_t n = send(fd, buf, (size_t)remaining, MS_SEND_FLAGS);
	if (n < 0 && ms_errno() == MS_EWOULDBLOCK) return 0;
	if (n < 0) return -1;
	return (int32_t)n;
}

/**
 * Set TCP_NODELAY on fd (low-latency, no Nagle buffering).
 */
static inline void msNetSetTcpNoDelay(int32_t fd) {
	int flag = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, MS_SOCKOPT_CAST &flag, sizeof(flag));
}

/**
 * Set SO_NOSIGPIPE on macOS (equivalent to MSG_NOSIGNAL per-send on Linux).
 */
static inline void msNetSetNoSigpipe(int32_t fd) {
#ifdef SO_NOSIGPIPE
	int flag = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, MS_SOCKOPT_CAST &flag, sizeof(flag));
#else
	(void)fd;
#endif
}

/* ===== HTTP Performance Helpers ===== */

/* Fast headers check — O(1) last-4-bytes (httpbeast pattern).
 * Returns position after \r\n\r\n, or -1 if not found.
 * Assumes common case: full headers arrive in one read. */
static inline int32_t msFastHeadersCheck(msString data) {
	int32_t len = (int32_t)data.len;
	if (len < 4 || !data.p) return -1;
	const char* d = data.p->data;
	if (MS_LIKELY(d[len-4]=='\r' && d[len-3]=='\n' && d[len-2]=='\r' && d[len-1]=='\n'))
		return len;
	return -1;
}

/* Slow headers check — linear scan for \r\n\r\n (fallback for partial headers). */
static inline int32_t msSlowHeadersCheck(msString data) {
	int32_t len = (int32_t)data.len;
	if (!data.p) return -1;
	const char* d = data.p->data;
	for (int32_t i = 0; i + 3 < len; i++) {
		if (d[i]=='\r' && d[i+1]=='\n' && d[i+2]=='\r' && d[i+3]=='\n')
			return i + 4;
	}
	return -1;
}

/* Fast method parse — returns method enum (0=GET..6=OPTIONS) and method length, or -1 on error.
 * Avoids msString creation + parseMethod() match. */
static inline int32_t msFastParseMethod(msString data) {
	if (data.len < 14 || !data.p) return -1;  /* minimum: "GET / HTTP/1.1" */
	const char* d = data.p->data;
	int32_t len = (int32_t)data.len;
	switch (d[0]) {
	case 'G': if (d[1]=='E' && d[2]=='T' && d[3]==' ') return 0; break;
	case 'P':
		if (d[1]=='O' && d[2]=='S' && d[3]=='T' && d[4]==' ') return 1;
		if (d[1]=='U' && d[2]=='T' && d[3]==' ') return 2;
		if (len > 5 && d[1]=='A' && d[2]=='T' && d[3]=='C' && d[4]=='H' && d[5]==' ') return 4;
		break;
	case 'D': if (len > 6 && d[1]=='E' && d[2]=='L' && d[3]=='E' && d[4]=='T' && d[5]=='E' && d[6]==' ') return 3; break;
	case 'H': if (d[1]=='E' && d[2]=='A' && d[3]=='D' && d[4]==' ') return 5; break;
	case 'O': if (len > 7 && d[1]=='P' && d[2]=='T' && d[3]=='I' && d[4]=='O' && d[5]=='N' && d[6]=='S' && d[7]==' ') return 6; break;
	}
	return -1;
}

/* Fast path extract — returns path substring from raw request data.
 * Avoids indexOf + two slice() calls. */
static inline msString msFastParsePath(msString data) {
	if (data.len < 14 || !data.p) return MS_EMPTY_STRING;
	const char* d = data.p->data;
	int32_t len = (int32_t)data.len;
	/* Find first space (end of method) */
	int32_t i = 0;
	while (i < len && d[i] != ' ') i++;
	if (i >= len) return MS_EMPTY_STRING;
	int32_t pathStart = i + 1;
	/* Find second space (end of path) */
	int32_t pathEnd = pathStart;
	while (pathEnd < len && d[pathEnd] != ' ') pathEnd++;
	if (pathEnd >= len) return MS_EMPTY_STRING;
	return msStringNew(d + pathStart, (int64_t)(pathEnd - pathStart));
}

/* Fast path extract into existing buffer — zero-alloc after warmup.
 * Same logic as msFastParsePath but writes into dest instead of allocating. */
static inline void msFastParsePathInto(msString* dest, msString data) {
	extern void msStringPrepareAdd(msString* s, int64_t addLen);
	if (data.len < 14 || !data.p) { dest->len = 0; return; }
	const char* d = data.p->data;
	int32_t len = (int32_t)data.len;
	int32_t i = 0;
	while (i < len && d[i] != ' ') i++;
	if (i >= len) { dest->len = 0; return; }
	int32_t pathStart = i + 1;
	int32_t pathEnd = pathStart;
	while (pathEnd < len && d[pathEnd] != ' ') pathEnd++;
	if (pathEnd >= len) { dest->len = 0; return; }
	int32_t pathLen = pathEnd - pathStart;
	dest->len = 0;
	msStringPrepareAdd(dest, (int64_t)pathLen);
	memcpy(dest->p->data, d + pathStart, pathLen);
	dest->len = pathLen;
	dest->p->data[pathLen] = '\0';
}

/* Shift string left by offset (memmove in-place, zero alloc).
 * Used for HTTP pipelining: discard processed request, keep remainder. */
static inline void msStringShiftLeft(msString* s, int32_t offset) {
	if (offset <= 0) return;
	if (offset >= (int32_t)s->len) {
		s->len = 0;
		if (s->p) s->p->data[0] = '\0';
		return;
	}
	int32_t remaining = (int32_t)s->len - offset;
	memmove(s->p->data, s->p->data + offset, remaining);
	s->len = remaining;
	s->p->data[remaining] = '\0';
}

/* Thread-local cached Date header line (httpbeast/Bun pattern).
 * Updated at most once per second — avoids strftime per response.
 *
 * Bakes the full header line "Date: <imf-fixdate>\r\n" (37 bytes) into a
 * payload structure with msStrPayload's binary layout. The cap field gets
 * MS_STRLIT_FLAG set so DRC treats the returned msString as a literal —
 * no refcount touch, no free attempt on the thread-local backing buffer.
 *
 * Result: msHttpDateLine() returns a zero-alloc msString that MS code can
 * append into response buffers via the standard msStringAppend path.
 *
 * Layout invariant: _msDatePayloadBox MUST share msStrPayload's prefix —
 * `int64_t cap` first, then char data. Verified at compile time via the
 * static asserts below. If msStrPayload changes, these break the build. */
typedef struct {
	int64_t cap;        /* matches msStrPayload.cap (holds MS_STRLIT_FLAG | len) */
	char data[48];      /* "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n" + nul */
} _msDatePayloadBox;

_Static_assert(offsetof(_msDatePayloadBox, cap) == offsetof(msStrPayload, cap),
               "_msDatePayloadBox cap offset must match msStrPayload");
_Static_assert(offsetof(_msDatePayloadBox, data) == offsetof(msStrPayload, data),
               "_msDatePayloadBox data offset must match msStrPayload");

static _Thread_local _msDatePayloadBox _msDatePayload;
static _Thread_local int64_t _msDateLen = 0;
static _Thread_local time_t _msDateEpoch = 0;

static inline void _msEnsureDate(void) {
	time_t now = time(NULL);
	if (now != _msDateEpoch) {
		_msDateEpoch = now;
		struct tm tm;
		ms_gmtime(&now, &tm);
		/* "Date: " (6) + IMF-fixdate (29) + "\r\n" (2) = 37 bytes */
		int n = (int)strftime(_msDatePayload.data, sizeof(_msDatePayload.data),
		                      "Date: %a, %d %b %Y %H:%M:%S GMT\r\n", &tm);
		_msDateLen = (int64_t)n;
		_msDatePayload.cap = _msDateLen | MS_STRLIT_FLAG;
	}
}

/* C-string accessor — kept for any legacy callers. */
static inline const char* msGetDateHeader(void) {
	_msEnsureDate();
	return _msDatePayload.data + 6; /* skip "Date: " prefix for raw date value */
}

/* Zero-alloc msString accessor — bakes full "Date: ...\r\n" header line.
 * Caller is expected to msStringAppend this into a response buffer; the
 * literal flag prevents DRC from freeing the thread-local backing. */
static inline msString msHttpDateLine(void) {
	_msEnsureDate();
	return (msString){ .len = _msDateLen, .p = (msStrPayload*)&_msDatePayload };
}

/* ===== Static response cache (Layer D — Bun parity for hello-world hot path) =====
 *
 * Per-thread cache of complete HTTP responses for endpoints whose status,
 * headers, and body don't change request-to-request. Bun's `Bun.serve` does
 * the same for `new Response("body")` returned from `fetch`.
 *
 * Lifecycle:
 *   - Caller picks a slotId (0..63) at the call site — same slot per endpoint.
 *   - On hit (same wall-clock second), the cached msString is returned for
 *     the caller to msStringAppend into the response buffer. ZERO allocation,
 *     zero rebuild work in the hot path.
 *   - On miss (first call OR second rolled over OR slot empty), caller rebuilds
 *     the full response, then msStaticCachePut stores a fresh copy.
 *
 * Why per-thread (not shared):
 *   - serveConcurrent spawns N event loops; each owns its own client fds.
 *   - Sharing would require atomics or a CAS pointer swap for safety.
 *   - Thread-local removes the race entirely at the cost of N copies of
 *     ~100 bytes each (negligible).
 *
 * Why per-second invalidation:
 *   - The Date header changes every second (RFC 7231). Cached responses
 *     bake in the Date header at build time, so the cache must refresh
 *     in lockstep with the date.
 *
 * Cache ownership:
 *   - Stored msString has its own payload (allocated by msStringNew during put).
 *   - The literal flag is set so DRC treats it as immutable when shared with
 *     MS callers. The cache explicitly frees the old payload on overwrite,
 *     bypassing the literal check via direct free(). */
#define MS_STATIC_SLOTS 64

/* Two-generation cache to avoid use-after-free under load.
 *
 * Naive single-generation design races with in-flight io_uring SEND:
 *   1. Hot path: response shares cache.fullResponse payload via msString
 *      struct copy; SEND submitted, kernel reads bytes async.
 *   2. Wall second rolls; msStaticCachePut frees the old payload BEFORE
 *      the kernel finishes reading it → UAF, garbage on the wire.
 *
 * Two-generation fix: each slot keeps `current` + `prev`. On eviction we
 * shift current→prev and only free prev (which is guaranteed >= 1 second
 * older than any possibly-in-flight SEND, since the kernel processes the
 * ring well within that window). Cost: 2× cache RAM per slot (~200 bytes
 * total for a /health response). Trivial. */
typedef struct {
	int64_t epoch;          /* Wall-clock second when `current` was filled */
	msString current;       /* Active response — readers point here */
	msString prev;           /* Previous generation — freed on next rollover */
	uint8_t valid;          /* 0 = empty slot, 1 = filled */
} _msStaticSlot;

static _Thread_local _msStaticSlot _msStaticCache[MS_STATIC_SLOTS];

/* Current wall-clock second — used as cache key. */
static inline int64_t msEpochSec(void) {
	return (int64_t)time(NULL);
}

/* Cache hit predicate: slot filled AND epoch matches current second. */
static inline int32_t msStaticCacheHit(int32_t slotId, int64_t currentSec) {
	if (slotId < 0 || slotId >= MS_STATIC_SLOTS) return 0;
	return (_msStaticCache[slotId].valid && _msStaticCache[slotId].epoch == currentSec) ? 1 : 0;
}

/* Return the current generation's msString. Readers may share this payload
 * (via msString struct copy) for the duration of one io_uring SEND; it is
 * guaranteed alive until at least the NEXT eviction (which only happens
 * when the wall second changes, see msStaticCachePut). */
static inline msString msStaticCacheGet(int32_t slotId) {
	if (slotId < 0 || slotId >= MS_STATIC_SLOTS) return MS_EMPTY_STRING;
	return _msStaticCache[slotId].current;
}

/* Rotate generations and install `source` as `current`.
 *
 * Sequence: free prev (older than 1 second now → no SENDs possibly still
 * referencing it) → prev = current (cooling generation) → current = new
 * copy of source. The "still in-flight" SEND submissions from the previous
 * second now point at `prev`, which is alive for one more second. */
static inline void msStaticCachePut(int32_t slotId, int64_t currentSec, msString source) {
	if (slotId < 0 || slotId >= MS_STATIC_SLOTS) return;
	if (_msStaticCache[slotId].valid) {
		/* Free the GRAND-prev (2 seconds old) — any SEND referencing it
		 * has long since completed. The previous `current` becomes `prev`. */
		msStringDestroyForce(_msStaticCache[slotId].prev);
		_msStaticCache[slotId].prev = _msStaticCache[slotId].current;
	}
	if (source.len > 0 && source.p != NULL) {
		_msStaticCache[slotId].current = msStringNew((const char*)source.p->data, source.len);
		if (_msStaticCache[slotId].current.p != NULL) {
			_msStaticCache[slotId].current.p->cap |= MS_STRLIT_FLAG;
		}
	} else {
		_msStaticCache[slotId].current = MS_EMPTY_STRING;
	}
	_msStaticCache[slotId].epoch = currentSec;
	_msStaticCache[slotId].valid = 1;
}

/* Build HTTP response in one allocation (httpbeast pattern).
 * snprintf header + memcpy body → single string.
 * Includes cached Date header (RFC 7231 requirement). */
static inline msString msBuildResponse(int32_t status, msString statusTextStr,
                                        msString contentType, msString body) {
	char header[512];
	int32_t bodyLen = (int32_t)body.len;
	/* Extract C strings from msString for snprintf */
	char stBuf[64], ctBuf[128];
	int stLen = statusTextStr.len < 63 ? (int)statusTextStr.len : 63;
	int ctLen = contentType.len < 127 ? (int)contentType.len : 127;
	if (statusTextStr.p) memcpy(stBuf, statusTextStr.p->data, stLen);
	stBuf[stLen] = '\0';
	if (contentType.p) memcpy(ctBuf, contentType.p->data, ctLen);
	ctBuf[ctLen] = '\0';

	int hlen = snprintf(header, 512,
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nDate: %s\r\n\r\n",
		(int)status, stBuf, ctBuf, (int)bodyLen, msGetDateHeader());
	if (hlen < 0 || hlen >= 512) hlen = 511;
	int32_t total = hlen + bodyLen;
	/* Allocate string: payload header + data */
	msStrPayload* pp = (msStrPayload*)malloc(sizeof(msStrPayload) + total + 1);
	pp->cap = total;
	memcpy(pp->data, header, hlen);
	if (body.p && bodyLen > 0)
		memcpy(pp->data + hlen, body.p->data, bodyLen);
	pp->data[total] = '\0';
	msString result;
	result.len = total;
	result.p = pp;
	return result;
}

/* Build response into existing msString — reuses buffer (zero malloc after first request).
 * The dest string grows on first use, then subsequent calls reuse the allocation.
 * Call from C with pointer to msString (not through MetaScript extern). */
static inline void msBuildResponseReuse(msString* dest, int32_t status, msString statusTextStr,
                                         msString contentType, msString body) {
	char header[512];
	int32_t bodyLen = (int32_t)body.len;
	char stBuf[64], ctBuf[128];
	int stLen = statusTextStr.len < 63 ? (int)statusTextStr.len : 63;
	int ctLen = contentType.len < 127 ? (int)contentType.len : 127;
	if (statusTextStr.p) memcpy(stBuf, statusTextStr.p->data, stLen);
	stBuf[stLen] = '\0';
	if (contentType.p) memcpy(ctBuf, contentType.p->data, ctLen);
	ctBuf[ctLen] = '\0';

	int hlen = snprintf(header, 512,
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nDate: %s\r\n\r\n",
		(int)status, stBuf, ctBuf, (int)bodyLen, msGetDateHeader());
	if (MS_UNLIKELY(hlen < 0 || hlen >= 512)) hlen = 511;
	int32_t total = hlen + bodyLen;

	/* Reuse buffer: reset length, grow if needed (realloc only on first call or size increase) */
	extern void msStringPrepareAdd(msString* s, int64_t addLen);
	dest->len = 0;
	msStringPrepareAdd(dest, (int64_t)total);
	memcpy(dest->p->data, header, hlen);
	if (body.p && bodyLen > 0)
		memcpy(dest->p->data + hlen, body.p->data, bodyLen);
	dest->p->data[total] = '\0';
	dest->len = total;
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_NET_H */

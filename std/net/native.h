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
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include "std/core/system/native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ===== Socket Creation ===== */

/**
 * Create a TCP socket (AF_INET, SOCK_STREAM).
 * Returns fd on success, -1 on error.
 */
static inline int32_t msNetSocket(void) {
	return (int32_t)socket(AF_INET, SOCK_STREAM, 0);
}

/* ===== Server Operations ===== */

/**
 * Bind socket to address and port. Sets SO_REUSEADDR automatically.
 * Returns 0 on success, -1 on error.
 */
static inline int32_t msNetBind(int32_t fd, msString addr, int32_t port) {
	int opt = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);

	const char* addr_str = msCStr(addr);
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
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_REUSEPORT
	setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
#endif

	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);

	const char* addr_str = msCStr(addr);
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
	socklen_t client_len = sizeof(client_addr);
	int client_fd = accept(fd, (struct sockaddr*)&client_addr, &client_len);
	if (MS_LIKELY(client_fd >= 0)) {
		int flag = 1;
		setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
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
	const char* host_str = msCStr(host);
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
			ret = connect(fd, rp->ai_addr, (socklen_t)rp->ai_addrlen);
		} while (ret < 0 && errno == EINTR);
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
	const char* buf = msCStr(data);
	int32_t total = 0;
	int32_t len = (int32_t)data.len;
	while (total < len) {
		ssize_t n = send(fd, buf + total, (size_t)(len - total), 0);
		if (MS_UNLIKELY(n < 0 && errno == EINTR)) continue;
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

	ssize_t received;
	do {
		received = recv(fd, buf, (size_t)maxBytes, 0);
	} while (received < 0 && errno == EINTR);

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
	close(fd);
}

/**
 * Set send and receive timeout on socket.
 * Returns 0 on success, -1 on error.
 */
static inline int32_t msNetSetTimeout(int32_t fd, int32_t ms) {
	struct timeval tv;
	tv.tv_sec = ms / 1000;
	tv.tv_usec = (ms % 1000) * 1000;

	int ret = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	if (ret != 0) return -1;
	return (int32_t)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

/* ===== Non-Blocking Variants (for event-loop servers) ===== */

/**
 * Set fd to non-blocking mode. Returns 0 on success, -1 on error.
 */
static inline int32_t msNetSetNonBlocking(int32_t fd) {
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0) return -1;
	return fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ? -1 : 0;
}

/**
 * Non-blocking accept. Returns client fd, or -1 on EAGAIN/error.
 * Sets TCP_NODELAY on accepted socket.
 */
static inline int32_t msNetAcceptNonBlock(int32_t fd) {
	struct sockaddr_in ca;
	socklen_t cl = sizeof(ca);
	int cfd = accept(fd, (struct sockaddr*)&ca, &cl);
	if (cfd >= 0) {
		int f = 1;
		setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &f, sizeof(f));
	}
	return (int32_t)cfd;
}

/**
 * Non-blocking recv. Returns received data, or empty string on EAGAIN/close/error.
 */
static inline msString msNetRecvNonBlock(int32_t fd, int32_t maxBytes) {
	if (maxBytes <= 0) return MS_EMPTY_STRING;
	if (maxBytes > 16777216) maxBytes = 16777216;
	char* buf = (char*)malloc((size_t)maxBytes + 1);
	ssize_t r = recv(fd, buf, (size_t)maxBytes, 0);
	if (r <= 0) { free(buf); return MS_EMPTY_STRING; }
	buf[r] = '\0';
	msString result = msStringNew(buf, (int64_t)r);
	free(buf);
	return result;
}

/**
 * Non-blocking send with offset. Returns bytes sent, 0 on EAGAIN, -1 on error.
 * Allows incremental sending from a sendQueue.
 */
static inline int32_t msNetSendNonBlock(int32_t fd, msString data, int32_t offset) {
	if (!data.p || offset >= (int32_t)data.len) return 0;
	const char* buf = data.p->data + offset;
	int32_t remaining = (int32_t)data.len - offset;
	ssize_t n = send(fd, buf, (size_t)remaining, 0);
	if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
	if (n < 0) return -1;
	return (int32_t)n;
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

/* Thread-local cached Date header (httpbeast pattern).
 * Updated at most once per second — avoids strftime per response. */
static _Thread_local char _msDateBuf[64];
static _Thread_local time_t _msDateEpoch = 0;

static inline const char* msGetDateHeader(void) {
	time_t now = time(NULL);
	if (now != _msDateEpoch) {
		_msDateEpoch = now;
		struct tm tm;
		gmtime_r(&now, &tm);
		strftime(_msDateBuf, sizeof(_msDateBuf), "%a, %d %b %Y %H:%M:%S GMT", &tm);
	}
	return _msDateBuf;
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

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_NET_H */

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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
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
	if (client_fd >= 0) {
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
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) return -1;
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

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_NET_H */

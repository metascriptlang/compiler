/*
 * MetaScript TLS Runtime — mbedTLS SSL wrapper implementation
 *
 * Wraps mbedTLS's high-level SSL API. No TLS protocol implementation.
 * CA bundle auto-discovery for macOS/Linux/BSD.
 *
 * mbedTLS 4.x: RNG handled internally via PSA crypto (no manual entropy/ctr_drbg).
 */

#include "runtime/crypto/tls/tls.h"

/* mbedTLS headers — resolved via @passC include paths in index.cms */
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"
#include "psa/crypto.h"
#include "runtime/crypto/psaOnce.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <errno.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#define ms_close_socket(fd) closesocket((SOCKET)(intptr_t)(fd))
#define MS_SOCKOPT_CAST (const char*)
#define MS_TLS_SEND_FLAGS 0
static inline int _ms_access(const char* path) {
	DWORD attr = GetFileAttributesA(path);
	return attr != INVALID_FILE_ATTRIBUTES ? 0 : -1;
}
#define ms_sock_err() WSAGetLastError()
#define MS_ERR_INTR(e) ((e) == WSAEINTR)
#define MS_ERR_TIMEOUT(e) ((e) == WSAEWOULDBLOCK || (e) == WSAETIMEDOUT)
#define MS_ERR_INPROGRESS(e) ((e) == WSAEWOULDBLOCK || (e) == WSAEINTR || (e) == WSAEINPROGRESS)
#define ms_poll(fds, n, ms) WSAPoll((fds), (n), (ms))
#else
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/time.h>
#define ms_close_socket(fd) close(fd)
#define ms_sock_err() errno
#define MS_ERR_INTR(e) ((e) == EINTR)
#define MS_ERR_TIMEOUT(e) ((e) == EAGAIN || (e) == EWOULDBLOCK)
#define MS_ERR_INPROGRESS(e) ((e) == EINPROGRESS || (e) == EINTR)
#define ms_poll(fds, n, ms) poll((fds), (n), (ms))
#define MS_SOCKOPT_CAST
#ifdef MSG_NOSIGNAL
#define MS_TLS_SEND_FLAGS MSG_NOSIGNAL
#else
#define MS_TLS_SEND_FLAGS 0
#endif
#endif

/* ===== TLS Context ===== */

typedef struct msTlsCtx {
	int fd;
	mbedtls_ssl_context ssl;
	mbedtls_ssl_config conf;
	mbedtls_x509_crt ownCa; /* parsed for an explicit caPath only */
	mbedtls_x509_crt *ca;   /* ownCa, or the process-wide default chain */
	int timedOut;           /* the last read or write wait ran out */
	char lastError[512];    /* why the last read ended the stream; empty after a clean read */
} msTlsCtx;

/* ===== I/O Callbacks for mbedTLS ===== */

/* Connect only: a connection keeps its own timedOut and lastError once it exists. */
static _Thread_local int tlsTimedOut;

static int tls_send(void *bio, const unsigned char *buf, size_t len) {
	msTlsCtx *ctx = (msTlsCtx*)bio;
	int fd = ctx->fd;
	int result;
	msPsaUnlock();
	for (;;) {
		int ret = (int)send(fd, (const char*)buf, (int)len, MS_TLS_SEND_FLAGS);
		if (ret >= 0) { result = ret; break; }
		int err = ms_sock_err();
		if (MS_ERR_INTR(err)) continue;
		if (MS_ERR_TIMEOUT(err)) { ctx->timedOut = 1; result = MBEDTLS_ERR_SSL_TIMEOUT; break; }
		result = MBEDTLS_ERR_SSL_INTERNAL_ERROR;
		break;
	}
	msPsaLock();
	return result;
}

static int tls_recv(void *bio, unsigned char *buf, size_t len) {
	msTlsCtx *ctx = (msTlsCtx*)bio;
	int fd = ctx->fd;
	int result;
	msPsaUnlock();
	for (;;) {
		int ret = (int)recv(fd, (char*)buf, (int)len, 0);
		if (ret > 0) { result = ret; break; }
		if (ret == 0) { result = MBEDTLS_ERR_SSL_CONN_EOF; break; }
		int err = ms_sock_err();
		if (MS_ERR_INTR(err)) continue;
		if (MS_ERR_TIMEOUT(err)) { ctx->timedOut = 1; result = MBEDTLS_ERR_SSL_TIMEOUT; break; }
		result = MBEDTLS_ERR_SSL_INTERNAL_ERROR;
		break;
	}
	msPsaLock();
	return result;
}

/* ===== CA Discovery ===== */

static _Thread_local char tlsLastError[512];

static void tlsSetError(const char *fmt, const char *detail) {
	snprintf(tlsLastError, sizeof(tlsLastError), fmt, detail);
}

static int isDir(const char *path) {
	struct stat st;
	return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR;
}

static int loadCaSource(mbedtls_x509_crt *chain, const char *path) {
	int ret = isDir(path) ? mbedtls_x509_crt_parse_path(chain, path)
	                      : mbedtls_x509_crt_parse_file(chain, path);
	return ret >= 0 && chain->version != 0;
}

#ifdef _WIN32
static int loadCaFromWindows(mbedtls_x509_crt *chain) {
	char path[MAX_PATH + 16];
	DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
	if (n > 0 && n < MAX_PATH) {
		char *slash = strrchr(path, '\\');
		if (slash) {
			strcpy(slash + 1, "cacert.pem");
			if (_ms_access(path) == 0 && loadCaSource(chain, path)) return 1;
		}
	}
	const char *p = getenv("PATH");
	while (p && *p) {
		const char *end = strchr(p, ';');
		size_t len = end ? (size_t)(end - p) : strlen(p);
		const char *dir = p;
		if (len > 1 && dir[0] == '"' && dir[len - 1] == '"') { dir++; len -= 2; }
		if (len > 0 && len < MAX_PATH) {
			memcpy(path, dir, len);
			strcpy(path + len, "\\cacert.pem");
			if (_ms_access(path) == 0 && loadCaSource(chain, path)) return 1;
		}
		p = end ? end + 1 : NULL;
	}
	return 0;
}
#elif defined(__APPLE__)
static const char *caPaths[] = {
	"/etc/ssl/cert.pem",
	"/System/Library/OpenSSL/certs/cert.pem",
	NULL
};
#elif defined(__linux__)
static const char *caPaths[] = {
	"/etc/ssl/certs/ca-certificates.crt",
	"/etc/ssl/ca-bundle.pem",
	"/etc/pki/tls/certs/ca-bundle.crt",
	"/usr/share/ssl/certs/ca-bundle.crt",
	"/etc/pki/tls/certs",
	"/data/data/com.termux/files/usr/etc/tls/cert.pem",
	"/system/etc/security/cacerts",
	"/etc/ssl/certs/ca-bundle.crt",
	NULL
};
#else
static const char *caPaths[] = {
	"/etc/ssl/certs/ca-certificates.crt",
	"/usr/local/share/certs/ca-root-nss.crt",
	"/etc/ssl/cert.pem",
	"/usr/local/share/certs",
	"/etc/openssl/certs",
	NULL
};
#endif

static int loadCaChain(mbedtls_x509_crt *chain, const char *explicitPath) {
	if (explicitPath) {
		if (loadCaSource(chain, explicitPath)) return 1;
		tlsSetError("failed to load CA certificates from %s", explicitPath);
		return 0;
	}
	const char *envFile = getenv("SSL_CERT_FILE");
	if (envFile) {
		if (loadCaSource(chain, envFile)) return 1;
		tlsSetError("no CA certificates found: SSL_CERT_FILE=%s did not load", envFile);
		return 0;
	}
	const char *envDir = getenv("SSL_CERT_DIR");
	if (envDir) {
		if (loadCaSource(chain, envDir)) return 1;
		tlsSetError("no CA certificates found: SSL_CERT_DIR=%s did not load", envDir);
		return 0;
	}
#ifdef _WIN32
	if (loadCaFromWindows(chain)) return 1;
#else
	for (int i = 0; caPaths[i]; i++) {
		if (access(caPaths[i], R_OK) == 0 && loadCaSource(chain, caPaths[i])) return 1;
	}
#endif
	tlsSetError("no CA certificates found%s", "; set SSL_CERT_FILE or SSL_CERT_DIR");
	return 0;
}

/*
 * The default chain is parsed once per process and shared read-only by every connection and thread:
 * mbedtls_ssl_conf_ca_chain stores the pointer and verification only reads the chain, so no lock is
 * needed after the parse. A failed parse is not cached, so a later connect reports its own cause.
 */
#ifdef _WIN32
static SRWLOCK defaultCaLock = SRWLOCK_INIT;
#define DEFAULT_CA_LOCK() AcquireSRWLockExclusive(&defaultCaLock)
#define DEFAULT_CA_UNLOCK() ReleaseSRWLockExclusive(&defaultCaLock)
#else
#include <pthread.h>
static pthread_mutex_t defaultCaLock = PTHREAD_MUTEX_INITIALIZER;
#define DEFAULT_CA_LOCK() pthread_mutex_lock(&defaultCaLock)
#define DEFAULT_CA_UNLOCK() pthread_mutex_unlock(&defaultCaLock)
#endif
static mbedtls_x509_crt defaultCa;
static int defaultCaLoaded;

static mbedtls_x509_crt *defaultCaChain(void) {
	mbedtls_x509_crt *chain = NULL;
	DEFAULT_CA_LOCK();
	if (!defaultCaLoaded) {
		mbedtls_x509_crt_init(&defaultCa);
		if (loadCaChain(&defaultCa, NULL)) defaultCaLoaded = 1;
		else mbedtls_x509_crt_free(&defaultCa);
	}
	if (defaultCaLoaded) chain = &defaultCa;
	DEFAULT_CA_UNLOCK();
	return chain;
}

msString msTlsLastError(void) {
	return msStringNew(tlsLastError, (int64_t)strlen(tlsLastError));
}

/* ===== TCP Connect ===== */

static int64_t nowMs(void) {
#ifdef _WIN32
	return (int64_t)GetTickCount64();
#else
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
#endif
}

static int setBlocking(int fd, int blocking) {
#ifdef _WIN32
	u_long mode = blocking ? 0 : 1;
	return ioctlsocket((SOCKET)(intptr_t)fd, FIONBIO, &mode);
#else
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0) return -1;
	return fcntl(fd, F_SETFL, blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK));
#endif
}

static void setIoTimeout(int fd, int timeoutMs) {
#ifdef _WIN32
	DWORD t = (DWORD)timeoutMs;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, MS_SOCKOPT_CAST &t, sizeof(t));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, MS_SOCKOPT_CAST &t, sizeof(t));
#else
	struct timeval tv;
	tv.tv_sec = timeoutMs / 1000;
	tv.tv_usec = (timeoutMs % 1000) * 1000;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
}

/* One connect attempt: 1 connected, 0 refused or failed, -1 the deadline passed. */
static int connectOne(int fd, const struct sockaddr *addr, socklen_t addrLen, int64_t deadline) {
	if (setBlocking(fd, 0) != 0) return 0;
	int ok = connect(fd, addr, addrLen) == 0;
	if (!ok && MS_ERR_INPROGRESS(ms_sock_err())) {
		for (;;) {
			int wait = -1;
			if (deadline >= 0) {
				int64_t left = deadline - nowMs();
				if (left <= 0) return -1;
				wait = left > 0x7fffffff ? 0x7fffffff : (int)left;
			}
			struct pollfd p;
			p.fd = fd;
			p.events = POLLOUT;
			p.revents = 0;
			int n = ms_poll(&p, 1, wait);
			if (n < 0) {
				if (MS_ERR_INTR(ms_sock_err())) continue;
				return 0;
			}
			if (n == 0) return -1;
			int soErr = 0;
			socklen_t soLen = sizeof(soErr);
			if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char*)&soErr, &soLen) != 0 || soErr != 0) return 0;
			ok = 1;
			break;
		}
	}
	if (!ok) return 0;
	return setBlocking(fd, 1) == 0 ? 1 : 0;
}

/* Tries every address getaddrinfo returns, in order; timeoutMs bounds the whole connect (0 = no bound). */
static int tcpConnect(const char *hostname, int port, int timeoutMs) {
	char portStr[16];
	snprintf(portStr, sizeof(portStr), "%d", port);

	struct addrinfo hints = {0};
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	struct addrinfo *res = NULL;
	if (getaddrinfo(hostname, portStr, &hints, &res) != 0 || !res) return -1;

	int64_t deadline = timeoutMs > 0 ? nowMs() + timeoutMs : -1;
	int fd = -1;
	for (struct addrinfo *it = res; it; it = it->ai_next) {
		int s = (int)socket(it->ai_family, it->ai_socktype, it->ai_protocol);
		if (s < 0) continue;
		int r = connectOne(s, it->ai_addr, (socklen_t)it->ai_addrlen, deadline);
		if (r > 0) { fd = s; break; }
		ms_close_socket(s);
		if (r < 0) { tlsTimedOut = 1; break; }
	}
	freeaddrinfo(res);
	if (fd < 0) return -1;

	int flag = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, MS_SOCKOPT_CAST &flag, sizeof(flag));
#ifdef SO_NOSIGPIPE
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, MS_SOCKOPT_CAST &flag, sizeof(flag));
#endif
	if (timeoutMs > 0) setIoTimeout(fd, timeoutMs);
	return fd;
}

/* ===== Public API ===== */

int64_t msTlsConnect(msString hostname, int32_t port, msString caPath, int32_t timeoutMs) {
	tlsLastError[0] = '\0';
	tlsTimedOut = 0;

	char hostBuf[256];
	if (msStrLen(hostname) > 255) {
		tlsSetError("hostname is longer than 255 bytes%s", "");
		return 0;
	}
	int64_t hlen = msStrLen(hostname);
	memcpy(hostBuf, msStrData(&hostname), hlen);
	hostBuf[hlen] = '\0';
	if (msStrLen(caPath) > 511) {
		tlsSetError("CA path is longer than 511 bytes%s", "");
		return 0;
	}

	msPsaLock();
	if (msPsaEnsure() != 0) {
		msPsaUnlock();
		tlsSetError("PSA crypto initialisation failed%s", "");
		return 0;
	}

	msTlsCtx *ctx = (msTlsCtx*)msMemAlloc0(sizeof(msTlsCtx));
	ctx->fd = -1;

	mbedtls_ssl_init(&ctx->ssl);
	mbedtls_ssl_config_init(&ctx->conf);
	mbedtls_x509_crt_init(&ctx->ownCa);

	char caBuf[512];
	const char *explicitCa = NULL;
	if (msStrLen(caPath) > 0) {
		memcpy(caBuf, msStrData(&caPath), msStrLen(caPath));
		caBuf[msStrLen(caPath)] = '\0';
		explicitCa = caBuf;
	}
	if (explicitCa) {
		if (!loadCaChain(&ctx->ownCa, explicitCa)) goto fail;
		ctx->ca = &ctx->ownCa;
	} else {
		ctx->ca = defaultCaChain();
		if (!ctx->ca) goto fail;
	}

	msPsaUnlock();
	int fd = tcpConnect(hostBuf, port, timeoutMs);
	msPsaLock();
	if (fd < 0) {
		tlsSetError(tlsTimedOut ? "TCP connect to %s timed out" : "TCP connect to %s failed", hostBuf);
		goto fail;
	}
	ctx->fd = fd;

	/* Configure SSL — mbedTLS 4.x handles RNG internally via PSA crypto */
	if (mbedtls_ssl_config_defaults(&ctx->conf,
			MBEDTLS_SSL_IS_CLIENT,
			MBEDTLS_SSL_TRANSPORT_STREAM,
			MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
		tlsSetError("TLS configuration failed%s", "");
		goto fail;
	}

	mbedtls_ssl_conf_authmode(&ctx->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
	mbedtls_ssl_conf_ca_chain(&ctx->conf, ctx->ca, NULL);

	/* ALPN: advertise http/1.1 — required by some CDNs (e.g. CloudFront) */
	static const char *alpnProtocols[] = { "http/1.1", NULL };
	mbedtls_ssl_conf_alpn_protocols(&ctx->conf, alpnProtocols);

	if (mbedtls_ssl_setup(&ctx->ssl, &ctx->conf) != 0) {
		tlsSetError("TLS session setup failed%s", "");
		goto fail;
	}

	/* SNI + certificate hostname verification */
	if (mbedtls_ssl_set_hostname(&ctx->ssl, hostBuf) != 0) {
		tlsSetError("invalid TLS hostname %s", hostBuf);
		goto fail;
	}

	/* I/O callbacks */
	mbedtls_ssl_set_bio(&ctx->ssl, ctx, tls_send, tls_recv, NULL);

	/* TLS handshake */
	int ret;
	while ((ret = mbedtls_ssl_handshake(&ctx->ssl)) != 0) {
		if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
			if (ctx->timedOut) {
				tlsTimedOut = 1;
				snprintf(tlsLastError, sizeof(tlsLastError), "TLS handshake timed out");
			}
			else if (ret == MBEDTLS_ERR_SSL_CONN_EOF) snprintf(tlsLastError, sizeof(tlsLastError), "TLS handshake failed: connection closed by the peer");
			else snprintf(tlsLastError, sizeof(tlsLastError), "TLS handshake failed: -0x%04X", (unsigned)-ret);
			uint32_t failedFlags = mbedtls_ssl_get_verify_result(&ctx->ssl);
			if (failedFlags != 0 && failedFlags != 0xFFFFFFFFu) {
				char info[256];
				mbedtls_x509_crt_verify_info(info, sizeof(info), "", failedFlags);
				snprintf(tlsLastError, sizeof(tlsLastError), "certificate verification failed: %s", info);
			}
			goto fail;
		}
	}

	uint32_t flags = mbedtls_ssl_get_verify_result(&ctx->ssl);
	if (flags != 0) {
		char info[256];
		mbedtls_x509_crt_verify_info(info, sizeof(info), "", flags);
		tlsSetError("certificate verification failed: %s", info);
		goto fail;
	}

	msPsaUnlock();
	return TLS_TO_HANDLE(ctx);

fail:
	mbedtls_ssl_free(&ctx->ssl);
	mbedtls_ssl_config_free(&ctx->conf);
	mbedtls_x509_crt_free(&ctx->ownCa);
	msPsaUnlock();
	if (ctx->fd >= 0) ms_close_socket(ctx->fd);
	free(ctx);
	return 0;
}

static _Thread_local unsigned char tlsReadScratch[16384]; /* one TLS record */

/* An empty result is a clean close_notify when msTlsConnLastError() is empty; otherwise it names a timeout (msTlsConnTimedOut), a failure, or a close without close_notify. */
msUint8Array msTlsReadBytes(int64_t handle, int32_t maxBytes) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx || maxBytes <= 0) return MS_EMPTY_UINT8_ARRAY;
	ctx->lastError[0] = '\0';
	ctx->timedOut = 0;
	if (maxBytes > (int32_t)sizeof(tlsReadScratch)) maxBytes = (int32_t)sizeof(tlsReadScratch);

	int ret;
	msPsaLock();
	do {
		ret = mbedtls_ssl_read(&ctx->ssl, tlsReadScratch, (size_t)maxBytes);
	} while (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE ||
	         ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET);
	msPsaUnlock();
	if (ret <= 0) {
		if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return MS_EMPTY_UINT8_ARRAY;
		if (ctx->timedOut) snprintf(ctx->lastError, sizeof(ctx->lastError), "TLS read timed out");
		else if (ret == 0) snprintf(ctx->lastError, sizeof(ctx->lastError), "TLS connection closed without close_notify");
		else snprintf(ctx->lastError, sizeof(ctx->lastError), "TLS read failed: -0x%04X", (unsigned)-ret);
		return MS_EMPTY_UINT8_ARRAY;
	}
	return msBufferFrom(tlsReadScratch, (int64_t)ret);
}

int32_t msTlsTimedOut(void) {
	return tlsTimedOut;
}

int32_t msTlsConnTimedOut(int64_t handle) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	return ctx ? ctx->timedOut : 0;
}

msString msTlsConnLastError(int64_t handle) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx) return MS_EMPTY_STRING;
	return msStringNew(ctx->lastError, (int64_t)strlen(ctx->lastError));
}

int32_t msTlsWriteBytes(int64_t handle, const uint8_t *buf, int64_t len64) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx || len64 > INT32_MAX) return -1;
	ctx->timedOut = 0;
	int32_t total = 0;
	int32_t len = (int32_t)len64;
	msPsaLock();
	while (total < len) {
		int ret = mbedtls_ssl_write(&ctx->ssl, buf + total, (size_t)(len - total));
		if (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_WANT_READ) continue;
		if (ret < 0) { msPsaUnlock(); return -1; }
		total += (int32_t)ret;
	}
	msPsaUnlock();
	return total;
}

int32_t msTlsWrite(int64_t handle, msString data) {
	if (msStrLen(data) == 0) return 0;
	return msTlsWriteBytes(handle, (const uint8_t*)msStrData(&data), msStrLen(data));
}

void msTlsClose(int64_t handle) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx) return;

	msPsaLock();
	mbedtls_ssl_close_notify(&ctx->ssl);
	mbedtls_ssl_free(&ctx->ssl);
	mbedtls_ssl_config_free(&ctx->conf);
	mbedtls_x509_crt_free(&ctx->ownCa);
	msPsaUnlock();
	ms_close_socket(ctx->fd);
	free(ctx);
}

msString msTlsPeerCertSubject(int64_t handle) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx) return MS_EMPTY_STRING;

	const mbedtls_x509_crt *cert = mbedtls_ssl_get_peer_cert(&ctx->ssl);
	if (!cert) return MS_EMPTY_STRING;

	char buf[256];
	int ret = mbedtls_x509_dn_gets(buf, sizeof(buf), &cert->subject);
	if (ret < 0) return MS_EMPTY_STRING;

	return msStringNew(buf, (int64_t)ret);
}

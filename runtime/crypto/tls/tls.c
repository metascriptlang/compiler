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

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
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
#define access(p, m) _ms_access(p)
#else
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#define ms_close_socket(fd) close(fd)
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
	mbedtls_x509_crt cacert;
} msTlsCtx;

/* ===== I/O Callbacks for mbedTLS ===== */

static int tls_send(void *ctx, const unsigned char *buf, size_t len) {
	int fd = *(int*)ctx;
	int ret = (int)send(fd, (const char*)buf, (int)len, MS_TLS_SEND_FLAGS);
	if (ret < 0) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
	return (int)ret;
}

static int tls_recv(void *ctx, unsigned char *buf, size_t len) {
	int fd = *(int*)ctx;
	int ret = (int)recv(fd, (char*)buf, (int)len, 0);
	if (ret < 0) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
	if (ret == 0) return MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
	return (int)ret;
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
			if (access(path, 0) == 0 && loadCaSource(chain, path)) return 1;
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
			if (access(path, 0) == 0 && loadCaSource(chain, path)) return 1;
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

msString msTlsLastError(void) {
	return msStringNew(tlsLastError, (int64_t)strlen(tlsLastError));
}

/* ===== TCP Connect ===== */

static int tcpConnect(const char *hostname, int port) {
	char portStr[16];
	snprintf(portStr, sizeof(portStr), "%d", port);

	struct addrinfo hints = {0};
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	struct addrinfo *res = NULL;
	if (getaddrinfo(hostname, portStr, &hints, &res) != 0 || !res) return -1;

	int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
	if (fd < 0) { freeaddrinfo(res); return -1; }

	if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
		ms_close_socket(fd);
		freeaddrinfo(res);
		return -1;
	}

	freeaddrinfo(res);

	int flag = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, MS_SOCKOPT_CAST &flag, sizeof(flag));
#ifdef SO_NOSIGPIPE
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, MS_SOCKOPT_CAST &flag, sizeof(flag));
#endif

	return fd;
}

/* ===== Public API ===== */

int64_t msTlsConnect(msString hostname, int32_t port, msString caPath) {
	char hostBuf[256];
	int64_t hlen = hostname.len < 255 ? hostname.len : 255;
	if (hostname.p) memcpy(hostBuf, hostname.p->data, hlen);
	hostBuf[hlen] = '\0';

	/* Initialize PSA crypto once (required by mbedTLS 4.x for RNG) */
	static int psa_inited = 0;
	if (!psa_inited) { psa_crypto_init(); psa_inited = 1; }

	tlsLastError[0] = '\0';

	msTlsCtx *ctx = (msTlsCtx*)msMemAlloc0(sizeof(msTlsCtx));
	ctx->fd = -1;

	mbedtls_ssl_init(&ctx->ssl);
	mbedtls_ssl_config_init(&ctx->conf);
	mbedtls_x509_crt_init(&ctx->cacert);

	char caBuf[512];
	const char *explicitCa = NULL;
	if (caPath.len > 0 && caPath.p) {
		int64_t clen = caPath.len < 511 ? caPath.len : 511;
		memcpy(caBuf, caPath.p->data, clen);
		caBuf[clen] = '\0';
		explicitCa = caBuf;
	}
	if (!loadCaChain(&ctx->cacert, explicitCa)) goto fail;

	int fd = tcpConnect(hostBuf, port);
	if (fd < 0) {
		tlsSetError("TCP connect to %s failed", hostBuf);
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
	mbedtls_ssl_conf_ca_chain(&ctx->conf, &ctx->cacert, NULL);

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
	mbedtls_ssl_set_bio(&ctx->ssl, &ctx->fd, tls_send, tls_recv, NULL);

	/* TLS handshake */
	int ret;
	while ((ret = mbedtls_ssl_handshake(&ctx->ssl)) != 0) {
		if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
			snprintf(tlsLastError, sizeof(tlsLastError), "TLS handshake failed: -0x%04X", (unsigned)-ret);
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

	return TLS_TO_HANDLE(ctx);

fail:
	mbedtls_ssl_free(&ctx->ssl);
	mbedtls_ssl_config_free(&ctx->conf);
	mbedtls_x509_crt_free(&ctx->cacert);
	if (ctx->fd >= 0) ms_close_socket(ctx->fd);
	free(ctx);
	return 0;
}

msString msTlsRead(int64_t handle, int32_t maxBytes) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx || maxBytes <= 0) return MS_EMPTY_STRING;

	unsigned char *buf = (unsigned char*)msMemAlloc(maxBytes);

	int ret = mbedtls_ssl_read(&ctx->ssl, buf, maxBytes);
	if (ret <= 0) {
		free(buf);
		return MS_EMPTY_STRING;
	}

	msString result = msStringNew((const char*)buf, (int64_t)ret);
	free(buf);
	return result;
}

int32_t msTlsWrite(int64_t handle, msString data) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx || data.len == 0 || !data.p) return -1;

	const unsigned char *buf = (const unsigned char*)data.p->data;
	int32_t total = 0;
	int32_t len = (int32_t)data.len;
	while (total < len) {
		int ret = mbedtls_ssl_write(&ctx->ssl, buf + total, (size_t)(len - total));
		if (ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
		if (ret < 0) return -1;
		total += (int32_t)ret;
	}
	return total;
}

void msTlsClose(int64_t handle) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx) return;

	mbedtls_ssl_close_notify(&ctx->ssl);
	mbedtls_ssl_free(&ctx->ssl);
	mbedtls_ssl_config_free(&ctx->conf);
	mbedtls_x509_crt_free(&ctx->cacert);
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

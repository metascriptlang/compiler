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
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#define ms_close_socket(fd) closesocket((SOCKET)(intptr_t)(fd))
#define MS_SOCKOPT_CAST (const char*)
static inline int _ms_access(const char* path) {
	DWORD attr = GetFileAttributesA(path);
	return attr != INVALID_FILE_ATTRIBUTES ? 0 : -1;
}
#define access(p, m) _ms_access(p)
#else
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/tcp.h>
#define ms_close_socket(fd) close(fd)
#define MS_SOCKOPT_CAST
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
	int ret = (int)send(fd, (const char*)buf, (int)len, 0);
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

/* ===== CA Bundle Discovery ===== */

static const char* findCaBundle(void) {
	const char *env = getenv("SSL_CERT_FILE");
	if (env && access(env, R_OK) == 0) return env;

	static const char *paths[] = {
		"/etc/ssl/cert.pem",                          /* macOS, some Linux */
		"/etc/ssl/certs/ca-certificates.crt",         /* Debian/Ubuntu */
		"/etc/pki/tls/certs/ca-bundle.crt",           /* RHEL/CentOS */
		"/usr/local/share/certs/ca-root-nss.crt",     /* FreeBSD */
		"/etc/ssl/ca-bundle.pem",                     /* OpenSUSE */
		NULL
	};

	for (int i = 0; paths[i]; i++) {
		if (access(paths[i], R_OK) == 0) return paths[i];
	}
	return NULL;
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

	int fd = tcpConnect(hostBuf, port);
	if (fd < 0) return 0;

	msTlsCtx *ctx = (msTlsCtx*)calloc(1, sizeof(msTlsCtx));
	if (!ctx) { ms_close_socket(fd); return 0; }
	ctx->fd = fd;

	mbedtls_ssl_init(&ctx->ssl);
	mbedtls_ssl_config_init(&ctx->conf);
	mbedtls_x509_crt_init(&ctx->cacert);

	/* Load CA bundle */
	char caBuf[512];
	const char *caFile = NULL;
	if (caPath.len > 0 && caPath.p) {
		int64_t clen = caPath.len < 511 ? caPath.len : 511;
		memcpy(caBuf, caPath.p->data, clen);
		caBuf[clen] = '\0';
		caFile = caBuf;
	} else {
		caFile = findCaBundle();
	}

	if (caFile) {
		if (mbedtls_x509_crt_parse_file(&ctx->cacert, caFile) < 0) {
			/* CA parse failed, continue without verification */
		}
	}

	/* Configure SSL — mbedTLS 4.x handles RNG internally via PSA crypto */
	if (mbedtls_ssl_config_defaults(&ctx->conf,
			MBEDTLS_SSL_IS_CLIENT,
			MBEDTLS_SSL_TRANSPORT_STREAM,
			MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
		goto fail;
	}

	mbedtls_ssl_conf_authmode(&ctx->conf,
		caFile ? MBEDTLS_SSL_VERIFY_REQUIRED : MBEDTLS_SSL_VERIFY_OPTIONAL);
	mbedtls_ssl_conf_ca_chain(&ctx->conf, &ctx->cacert, NULL);

	if (mbedtls_ssl_setup(&ctx->ssl, &ctx->conf) != 0) goto fail;

	/* SNI + certificate hostname verification */
	if (mbedtls_ssl_set_hostname(&ctx->ssl, hostBuf) != 0) goto fail;

	/* I/O callbacks */
	mbedtls_ssl_set_bio(&ctx->ssl, &ctx->fd, tls_send, tls_recv, NULL);

	/* TLS handshake */
	int ret;
	while ((ret = mbedtls_ssl_handshake(&ctx->ssl)) != 0) {
		if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
			goto fail;
		}
	}

	return TLS_TO_HANDLE(ctx);

fail:
	mbedtls_ssl_free(&ctx->ssl);
	mbedtls_ssl_config_free(&ctx->conf);
	mbedtls_x509_crt_free(&ctx->cacert);
	ms_close_socket(fd);
	free(ctx);
	return 0;
}

msString msTlsRead(int64_t handle, int32_t maxBytes) {
	msTlsCtx *ctx = TLS_FROM_HANDLE(handle);
	if (!ctx || maxBytes <= 0) return MS_EMPTY_STRING;

	unsigned char *buf = (unsigned char*)malloc(maxBytes);
	if (!buf) return MS_EMPTY_STRING;

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

	int ret = mbedtls_ssl_write(&ctx->ssl, (const unsigned char*)data.p->data, data.len);
	if (ret < 0) return -1;
	return (int32_t)ret;
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

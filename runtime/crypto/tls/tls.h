/*
 * MetaScript TLS Runtime — mbedTLS SSL wrapper
 *
 * Opaque handle pattern (same as RSA key handles).
 * One handle = TCP fd + SSL context + config + CA chain.
 * Single allocation, single free.
 */

#ifndef MS_TLS_H
#define MS_TLS_H

#include "runtime/core/string.h"
#include <stdint.h>

/* Opaque TLS connection handle */
#define TLS_TO_HANDLE(p)   ((int64_t)(uintptr_t)(p))
#define TLS_FROM_HANDLE(h) ((struct msTlsCtx*)(uintptr_t)(h))

/* Connect to hostname:port over TLS.
 * Performs DNS resolution, TCP connect, TLS handshake, cert verification.
 * caPath: path to CA bundle file. Empty string = use system default.
 * Returns handle on success, 0 on failure. */
int64_t msTlsConnect(msString hostname, int32_t port, msString caPath);

/* Read decrypted data from TLS connection.
 * Returns msString with data, empty on error/close. */
msString msTlsRead(int64_t ctx, int32_t maxBytes);

/* Write data through TLS connection (encrypted by mbedTLS).
 * Returns bytes written, -1 on error. */
int32_t msTlsWrite(int64_t ctx, msString data);

/* Close TLS connection and free all resources. */
void msTlsClose(int64_t ctx);

/* Get peer certificate subject string (for debugging/logging). */
msString msTlsPeerCertSubject(int64_t ctx);

#endif /* MS_TLS_H */

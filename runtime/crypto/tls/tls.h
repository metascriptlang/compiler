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
#include "runtime/core/buffer.h"
#include <stdint.h>

/* Opaque TLS connection handle */
#define TLS_TO_HANDLE(p)   ((int64_t)(uintptr_t)(p))
#define TLS_FROM_HANDLE(h) ((struct msTlsCtx*)(uintptr_t)(h))

/* Connect to hostname:port over TLS.
 * Performs DNS resolution, TCP connect, TLS handshake, cert verification.
 * caPath: path to CA bundle file. Empty string = use system default.
 * timeoutMs > 0 bounds the connect and every later handshake, read and write wait; 0 waits forever.
 * Returns handle on success, 0 on failure. */
int64_t msTlsConnect(msString hostname, int32_t port, msString caPath, int32_t timeoutMs);

/* 1 when the last connect on this thread failed because its wait ran out. */
int32_t msTlsTimedOut(void);

/* 1 when the connection's last read or write failed because its wait ran out. */
int32_t msTlsConnTimedOut(int64_t ctx);

/* The connection's last read: "" after data or a clean close_notify, else why the stream ended. */
msString msTlsConnLastError(int64_t ctx);

/* Why the last connect on this thread failed. */
msString msTlsLastError(void);

/* Read decrypted data from TLS connection, at most one TLS record (16384 bytes) per call.
 * Empty is end of stream, and an error when msTlsConnLastError() is then
 * non-empty (timeout, failure, or a close without close_notify). */
msUint8Array msTlsReadBytes(int64_t ctx, int32_t maxBytes);

/* Write data through TLS connection (encrypted by mbedTLS).
 * Returns bytes written (0 for empty data), -1 on error. */
int32_t msTlsWrite(int64_t ctx, msString data);
int32_t msTlsWriteBytes(int64_t ctx, const uint8_t *data, int64_t len);

/* Close TLS connection and free all resources. */
void msTlsClose(int64_t ctx);

/* Get peer certificate subject string (for debugging/logging). */
msString msTlsPeerCertSubject(int64_t ctx);

#endif /* MS_TLS_H */

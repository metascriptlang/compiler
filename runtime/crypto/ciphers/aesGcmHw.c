/*
 * MetaScript AES-GCM hardware path for the vendor surface: the mbedTLS key schedule handed to the shared kernels
 * of aesHw.c (8 blocks of CTR and one aggregated GHASH per pass, on Arm AES + PMULL or x86-64 AES-NI + PCLMULQDQ).
 * A CPU without the extensions stays on the vendored gcm.c.
 */

#include "runtime/crypto/ciphers/aesGcmHw.h"
#include "runtime/crypto/ciphers/aesHw.h"

/* The caller has already refused lengths past the SP 800-38D limits (msAesGcmLengthsOk). */
int msAesGcmHw(const mbedtls_aes_context* aes, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt) {
	if (!msAesHwAvailable()) return 0;
	const uint8_t* rk = (const uint8_t*)(aes->MBEDTLS_PRIVATE(buf) + aes->MBEDTLS_PRIVATE(rk_offset));
	msAesGcmHwRun(rk, aes->MBEDTLS_PRIVATE(nr), iv, aad, aadLen, in, len, out, tag, decrypt);
	return 1;
}

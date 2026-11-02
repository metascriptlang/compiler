/*
 * Four-block ChaCha20 keystream XOR on targets with 128-bit vector registers.
 */

#ifndef MS_CRYPTO_CHACHA20SIMD_H
#define MS_CRYPTO_CHACHA20SIMD_H

#include <stddef.h>
#include <stdint.h>

#if (defined(__aarch64__) && defined(__ARM_NEON)) || (defined(__x86_64__) && defined(__SSE2__))
#define MS_CHACHA20_SIMD 1

/* XORs in with the djb-layout keystream (64-bit counter at *ctr, 8-byte nonce) into out, for the
 * leading 64-byte blocks it batches, in chunks of 256 or 576 bytes. Advances *ctr by the blocks used and returns the bytes done;
 * the caller finishes the rest. in may equal out. */
size_t msChacha20SimdXor(uint8_t *out, const uint8_t *in, size_t n, const uint8_t key[32],
                         const uint8_t nonce[8], uint64_t *ctr);
#endif

#endif /* MS_CRYPTO_CHACHA20SIMD_H */

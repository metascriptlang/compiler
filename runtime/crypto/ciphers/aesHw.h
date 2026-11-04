/*
 * AES-GCM and AES-CBC on the CPU's AES extensions, over the encryption round keys rk[0..nr] as 16-byte blocks in
 * FIPS 197 order (aesHw.c). Call msAesHwAvailable first: it is 0 when the CPU or build has no hardware path.
 */
#ifndef MS_CRYPTO_AES_HW_H
#define MS_CRYPTO_AES_HW_H

#include <stddef.h>
#include <stdint.h>

int msAesHwAvailable(void);

/* GCM with a 12-byte iv: len bytes of in XOR the counter stream into out (in may equal out), and the tag over aad
 * and the cipher text (out when encrypting, in when decrypting) into tag. */
void msAesGcmHwRun(const uint8_t* rk, int nr, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
	const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt);

/* GCM decryption that verifies tag over aad and in before it writes: 1 with the plain text in out, or 0 with out
 * untouched. */
int msAesGcmHwOpen(const uint8_t* rk, int nr, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
	const uint8_t* in, size_t len, const uint8_t tag[16], uint8_t* out);

/* CBC over the whole 16-byte blocks of in (len a multiple of 16) into out; no padding. */
void msAesCbcHwEncrypt(const uint8_t* rk, int nr, const uint8_t iv[16], const uint8_t* in, size_t len, uint8_t* out);
void msAesCbcHwDecrypt(const uint8_t* rk, int nr, const uint8_t iv[16], const uint8_t* in, size_t len, uint8_t* out);

#endif /* MS_CRYPTO_AES_HW_H */

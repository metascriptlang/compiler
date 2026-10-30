/* Shared platform CSPRNG for crypto modules.
 * Included by native.c files that need random bytes. */

#ifndef MS_CRYPTO_RANDOM_FILL_H
#define MS_CRYPTO_RANDOM_FILL_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
static int ms_random_fill(uint8_t *buf, size_t len) {
	while (len > 0) {
		ULONG chunk = len > 0x40000000u ? 0x40000000u : (ULONG)len;
		if (BCryptGenRandom(NULL, buf, chunk, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return -1;
		buf += chunk;
		len -= chunk;
	}
	return 0;
}
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
#include <stdlib.h>
static int ms_random_fill(uint8_t *buf, size_t len) {
	arc4random_buf(buf, len);
	return 0;
}
#else
static int ms_random_fill(uint8_t *buf, size_t len) {
	FILE *f = fopen("/dev/urandom", "rb");
	if (!f) return -1;
	size_t got = fread(buf, 1, len, f);
	fclose(f);
	return (got == len) ? 0 : -1;
}
#endif

#endif /* MS_CRYPTO_RANDOM_FILL_H */

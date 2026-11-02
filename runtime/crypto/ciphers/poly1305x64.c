/*
 * Poly1305 over three 44/44/42-bit limbs held in 64-bit words, products in unsigned __int128.
 */

#include "runtime/crypto/ciphers/poly1305x64.h"

#ifdef __SIZEOF_INT128__

#include <string.h>

typedef unsigned __int128 u128;
typedef uint64_t u64;

#define MASK44 0xfffffffffffULL
#define MASK42 0x3ffffffffffULL

typedef struct {
	u64 r0, r1, r2, s1, s2, h0, h1, h2;
} polyState;

static u64 load64(const uint8_t *p) {
	u64 v;
	memcpy(&v, p, 8);
	return v;
}

static void polyBlocks(polyState *st, const uint8_t *m, size_t blocks) {
	const u64 r0 = st->r0, r1 = st->r1, r2 = st->r2, s1 = st->s1, s2 = st->s2;
	u64 h0 = st->h0, h1 = st->h1, h2 = st->h2;
	for (; blocks > 0; blocks--, m += 16) {
		u64 t0 = load64(m), t1 = load64(m + 8);
		h0 += t0 & MASK44;
		h1 += ((t0 >> 44) | (t1 << 20)) & MASK44;
		h2 += ((t1 >> 24) & MASK42) | ((u64)1 << 40);

		u128 d0 = (u128)h0 * r0 + (u128)h1 * s2 + (u128)h2 * s1;
		u128 d1 = (u128)h0 * r1 + (u128)h1 * r0 + (u128)h2 * s2;
		u128 d2 = (u128)h0 * r2 + (u128)h1 * r1 + (u128)h2 * r0;

		u64 c = (u64)(d0 >> 44);
		h0 = (u64)d0 & MASK44;
		d1 += c;
		c = (u64)(d1 >> 44);
		h1 = (u64)d1 & MASK44;
		d2 += c;
		c = (u64)(d2 >> 42);
		h2 = (u64)d2 & MASK42;
		h0 += c * 5;
		c = h0 >> 44;
		h0 &= MASK44;
		h1 += c;
	}
	st->h0 = h0;
	st->h1 = h1;
	st->h2 = h2;
}

/* Whole 16-byte blocks of data, then the remainder zero-padded to one more block. */
static void polyPadded(polyState *st, const uint8_t *data, size_t len) {
	polyBlocks(st, data, len >> 4);
	size_t rest = len & 15;
	if (rest > 0) {
		uint8_t block[16] = {0};
		memcpy(block, data + (len - rest), rest);
		polyBlocks(st, block, 1);
	}
}

static void polyFinal(polyState *st, uint8_t mac[16], const uint8_t pad[16]) {
	u64 h0 = st->h0, h1 = st->h1, h2 = st->h2, c;

	c = h1 >> 44; h1 &= MASK44; h2 += c;
	c = h2 >> 42; h2 &= MASK42; h0 += c * 5;
	c = h0 >> 44; h0 &= MASK44; h1 += c;
	c = h1 >> 44; h1 &= MASK44; h2 += c;
	c = h2 >> 42; h2 &= MASK42; h0 += c * 5;
	c = h0 >> 44; h0 &= MASK44; h1 += c;

	/* g = h + 5 - 2^130; h < p exactly when g went negative, which sets bit 63 of g2. */
	u64 g0 = h0 + 5;
	c = g0 >> 44; g0 &= MASK44;
	u64 g1 = h1 + c;
	c = g1 >> 44; g1 &= MASK44;
	u64 g2 = h2 + c - ((u64)1 << 42);

	u64 takeG = (g2 >> 63) - 1; /* all ones when h >= p */
	u64 keepH = ~takeG;
	h0 = (h0 & keepH) | (g0 & takeG);
	h1 = (h1 & keepH) | (g1 & takeG);
	h2 = (h2 & keepH) | (g2 & takeG);

	u64 t0 = load64(pad), t1 = load64(pad + 8);
	h0 += t0 & MASK44;
	c = h0 >> 44; h0 &= MASK44;
	h1 += (((t0 >> 44) | (t1 << 20)) & MASK44) + c;
	c = h1 >> 44; h1 &= MASK44;
	h2 += ((t1 >> 24) & MASK42) + c;
	h2 &= MASK42;

	u64 lo = h0 | (h1 << 44);
	u64 hi = (h1 >> 20) | (h2 << 24);
	memcpy(mac, &lo, 8);
	memcpy(mac + 8, &hi, 8);
}

void msPoly1305Aead(uint8_t mac[16], const uint8_t authKey[32], const uint8_t *ad, size_t adLen,
                    const uint8_t *cipherText, size_t textLen) {
	polyState st;
	u64 t0 = load64(authKey), t1 = load64(authKey + 8);
	st.r0 = t0 & 0xffc0fffffffULL;
	st.r1 = ((t0 >> 44) | (t1 << 20)) & 0xfffffc0ffffULL;
	st.r2 = (t1 >> 24) & 0x00ffffffc0fULL;
	st.s1 = st.r1 * (5 << 2);
	st.s2 = st.r2 * (5 << 2);
	st.h0 = st.h1 = st.h2 = 0;

	polyPadded(&st, ad, adLen);
	polyPadded(&st, cipherText, textLen);
	u64 sizes[2] = {adLen, textLen};
	polyBlocks(&st, (const uint8_t *)sizes, 1);
	polyFinal(&st, mac, authKey + 16);

	volatile uint8_t *w = (volatile uint8_t *)&st;
	for (size_t i = 0; i < sizeof st; i++) w[i] = 0;
}

#endif

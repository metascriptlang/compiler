#include "runtime/bigint/bigint.h"
#include "runtime/drc.h"
#include "runtime/core/system.h"
#include "mbedtls/private/bignum.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct msBigInt {
	mbedtls_mpi v;
};

static void msBigIntDestroy(void* p) {
	mbedtls_mpi_free(&((msBigInt*)p)->v);
}

const msTypeInfo msBigIntTypeInfo = { "bigint", false, NULL, msBigIntDestroy, 0, NULL };

static void bigFail(const char* msg) {
	fprintf(stderr, "BigInt: %s\n", msg);
	abort();
}

#define CHK(f) do { if ((f) != 0) bigFail("out of memory"); } while (0)

static msBigInt* newBig(void) {
	msBigInt* r = (msBigInt*)msAllocTyped(sizeof(msBigInt), &msBigIntTypeInfo);
	mbedtls_mpi_init(&r->v);
	return r;
}

msBigInt* msBigIntFromInt64(int64_t v) {
	msBigInt* r = newBig();
	CHK(mbedtls_mpi_lset(&r->v, (mbedtls_mpi_sint)v));
	return r;
}

msBigInt* msBigIntFromUint64(uint64_t v) {
	uint8_t buf[8];
	for (int i = 7; i >= 0; i--) { buf[i] = (uint8_t)(v & 0xff); v >>= 8; }
	msBigInt* r = newBig();
	CHK(mbedtls_mpi_read_binary(&r->v, buf, 8));
	return r;
}

msBigInt* msBigIntFromString(const char* s, size_t len) {
	while (len > 0 && isspace((unsigned char)s[0])) { s++; len--; }
	while (len > 0 && isspace((unsigned char)s[len - 1])) len--;
	if (len > 0 && s[len - 1] == 'n') len--;
	int neg = 0;
	if (len > 0 && (s[0] == '-' || s[0] == '+')) { neg = (s[0] == '-'); s++; len--; }
	int radix = 10;
	if (len >= 2 && s[0] == '0') {
		char c = (char)tolower((unsigned char)s[1]);
		if (c == 'x') { radix = 16; s += 2; len -= 2; }
		else if (c == 'b') { radix = 2; s += 2; len -= 2; }
		else if (c == 'o') { radix = 8; s += 2; len -= 2; }
	}
	char* clean = (char*)malloc(len + 2);
	if (clean == NULL) bigFail("out of memory");
	size_t n = 0;
	if (neg) clean[n++] = '-';
	for (size_t i = 0; i < len; i++) {
		if (s[i] == '_') continue;
		clean[n++] = s[i];
	}
	clean[n] = '\0';
	size_t digitCount = n - (neg ? 1u : 0u);
	msBigInt* r = newBig();
	if (digitCount == 0) {
		if (neg) bigFail("cannot convert string to a BigInt");
		CHK(mbedtls_mpi_lset(&r->v, 0));
	} else if (mbedtls_mpi_read_string(&r->v, radix, clean) != 0) {
		bigFail("cannot convert string to a BigInt");
	}
	free(clean);
	return r;
}

msBigInt* msBigIntFromLit(msString s) {
	return msBigIntFromString(s.p != NULL ? s.p->data : "", (size_t)s.len);
}

msString msBigIntToString(const msBigInt* a, int32_t radix) {
	char* raw = msBigIntToCString(a, radix);
	msString out = msStringNew(raw, (int64_t)strlen(raw));
	free(raw);
	return out;
}

msString msBigIntToDebugString(const msBigInt* a) {
	char* raw = msBigIntToCString(a, 10);
	size_t n = strlen(raw);
	char* buf = (char*)malloc(n + 2);
	if (buf == NULL) bigFail("out of memory");
	memcpy(buf, raw, n);
	buf[n] = 'n';
	buf[n + 1] = '\0';
	free(raw);
	msString out = msStringNew(buf, (int64_t)(n + 1));
	free(buf);
	return out;
}

msBigInt* msBigIntFromFloat64(double v) {
	if (!isfinite(v) || trunc(v) != v) bigFail("the number cannot be converted to a BigInt because it is not an integer");
	char buf[352];
	snprintf(buf, sizeof buf, "%.0f", v);
	return msBigIntFromString(buf, strlen(buf));
}

char* msBigIntToCString(const msBigInt* a, int32_t radix) {
	if (radix < 2 || radix > 36) bigFail("toString() radix must be between 2 and 36");
	if (radix <= 16) {
		size_t olen = 0;
		mbedtls_mpi_write_string(&a->v, radix, NULL, 0, &olen);
		char* buf = (char*)malloc(olen);
		if (buf == NULL) bigFail("out of memory");
		CHK(mbedtls_mpi_write_string(&a->v, radix, buf, olen, &olen));
		for (char* p = buf; *p; p++) *p = (char)tolower((unsigned char)*p);
		return buf;
	}
	/* mbedtls_mpi_write_string caps at radix 16; peel digits by division */
	static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
	int neg = mbedtls_mpi_cmp_int(&a->v, 0) < 0;
	mbedtls_mpi m, zero, q, r;
	mbedtls_mpi_init(&m); mbedtls_mpi_init(&zero); mbedtls_mpi_init(&q); mbedtls_mpi_init(&r);
	CHK(mbedtls_mpi_lset(&zero, 0));
	if (neg) CHK(mbedtls_mpi_sub_mpi(&m, &zero, &a->v));
	else CHK(mbedtls_mpi_copy(&m, &a->v));
	size_t cap = mbedtls_mpi_bitlen(&m) / 4 + 4;
	char* tmp = (char*)malloc(cap);
	if (tmp == NULL) bigFail("out of memory");
	size_t n = 0;
	if (mbedtls_mpi_cmp_int(&m, 0) == 0) tmp[n++] = '0';
	while (mbedtls_mpi_cmp_int(&m, 0) > 0) {
		CHK(mbedtls_mpi_div_int(&q, &r, &m, radix));
		size_t olen = 0;
		char dbuf[8];
		CHK(mbedtls_mpi_write_string(&r, 16, dbuf, sizeof dbuf, &olen));
		long d = strtol(dbuf, NULL, 16);
		tmp[n++] = digits[d];
		CHK(mbedtls_mpi_copy(&m, &q));
	}
	char* out = (char*)malloc(n + 2);
	if (out == NULL) bigFail("out of memory");
	size_t w = 0;
	if (neg) out[w++] = '-';
	while (n > 0) out[w++] = tmp[--n];
	out[w] = '\0';
	free(tmp);
	mbedtls_mpi_free(&m); mbedtls_mpi_free(&zero); mbedtls_mpi_free(&q); mbedtls_mpi_free(&r);
	return out;
}

double msBigIntToFloat64(const msBigInt* a) {
	char* s = msBigIntToCString(a, 10);
	double d = strtod(s, NULL);
	free(s);
	return d;
}

int64_t msBigIntToInt64(const msBigInt* a) {
	msBigInt* t = msBigIntAsIntN(64, a);
	int neg = mbedtls_mpi_cmp_int(&t->v, 0) < 0;
	mbedtls_mpi m, zero;
	mbedtls_mpi_init(&m); mbedtls_mpi_init(&zero);
	CHK(mbedtls_mpi_lset(&zero, 0));
	if (neg) CHK(mbedtls_mpi_sub_mpi(&m, &zero, &t->v));
	else CHK(mbedtls_mpi_copy(&m, &t->v));
	uint8_t buf[8] = {0};
	CHK(mbedtls_mpi_write_binary(&m, buf, 8));
	uint64_t u = 0;
	for (int i = 0; i < 8; i++) u = (u << 8) | buf[i];
	mbedtls_mpi_free(&m); mbedtls_mpi_free(&zero);
	// msBigIntDestroy only frees the mpi limbs — the msAllocTyped cell itself and
	// the ledger's destroy count both hang off the decref path.
	msDecref(t);
	return neg ? -(int64_t)u : (int64_t)u;
}

#define BIN_OP(name, call) \
	msBigInt* name(const msBigInt* a, const msBigInt* b) { \
		msBigInt* r = newBig(); \
		CHK(call(&r->v, &a->v, &b->v)); \
		return r; \
	}

BIN_OP(msBigIntAdd, mbedtls_mpi_add_mpi)
BIN_OP(msBigIntSub, mbedtls_mpi_sub_mpi)
BIN_OP(msBigIntMul, mbedtls_mpi_mul_mpi)

/* div_mpi is truncated division (R takes the dividend's sign) — exactly JS
 * `/` and `%`. mod_mpi is NOT usable: it rejects negative moduli. */
msBigInt* msBigIntDiv(const msBigInt* a, const msBigInt* b) {
	msBigInt* r = newBig();
	int rc = mbedtls_mpi_div_mpi(&r->v, NULL, &a->v, &b->v);
	if (rc == MBEDTLS_ERR_MPI_DIVISION_BY_ZERO) bigFail("division by zero");
	CHK(rc);
	return r;
}

msBigInt* msBigIntMod(const msBigInt* a, const msBigInt* b) {
	msBigInt* r = newBig();
	int rc = mbedtls_mpi_div_mpi(NULL, &r->v, &a->v, &b->v);
	if (rc == MBEDTLS_ERR_MPI_DIVISION_BY_ZERO) bigFail("division by zero");
	CHK(rc);
	return r;
}

msBigInt* msBigIntNeg(const msBigInt* a) {
	msBigInt* r = newBig();
	mbedtls_mpi zero;
	mbedtls_mpi_init(&zero);
	CHK(mbedtls_mpi_lset(&zero, 0));
	CHK(mbedtls_mpi_sub_mpi(&r->v, &zero, &a->v));
	mbedtls_mpi_free(&zero);
	return r;
}

msBigInt* msBigIntNot(const msBigInt* a) {
	msBigInt* r = newBig();
	mbedtls_mpi t, zero;
	mbedtls_mpi_init(&t); mbedtls_mpi_init(&zero);
	CHK(mbedtls_mpi_lset(&zero, 0));
	CHK(mbedtls_mpi_add_int(&t, &a->v, 1));
	CHK(mbedtls_mpi_sub_mpi(&r->v, &zero, &t));
	mbedtls_mpi_free(&t); mbedtls_mpi_free(&zero);
	return r;
}

msBigInt* msBigIntPow(const msBigInt* a, const msBigInt* b) {
	if (mbedtls_mpi_cmp_int(&b->v, 0) < 0) bigFail("exponent must be non-negative");
	msBigInt* r = newBig();
	CHK(mbedtls_mpi_lset(&r->v, 1));
	mbedtls_mpi t;
	mbedtls_mpi_init(&t);
	size_t bits = mbedtls_mpi_bitlen(&b->v);
	for (size_t i = bits; i-- > 0;) {
		CHK(mbedtls_mpi_mul_mpi(&t, &r->v, &r->v));
		mbedtls_mpi_swap(&t, &r->v);
		if (mbedtls_mpi_get_bit(&b->v, i) == 1) {
			CHK(mbedtls_mpi_mul_mpi(&t, &r->v, &a->v));
			mbedtls_mpi_swap(&t, &r->v);
		}
	}
	mbedtls_mpi_free(&t);
	return r;
}

/* JS bitwise is two's-complement over infinite width; mpi is sign-magnitude.
 * Bridge through big-endian buffers of L = max(size)+1 bytes: the spare byte
 * guarantees room for the sign bit, negatives become 2^(8L)+x. */
static void tcWrite(const mbedtls_mpi* x, uint8_t* buf, size_t L) {
	if (mbedtls_mpi_cmp_int(x, 0) >= 0) {
		CHK(mbedtls_mpi_write_binary(x, buf, L));
		return;
	}
	mbedtls_mpi t;
	mbedtls_mpi_init(&t);
	CHK(mbedtls_mpi_lset(&t, 1));
	CHK(mbedtls_mpi_shift_l(&t, 8 * L));
	CHK(mbedtls_mpi_add_mpi(&t, &t, x));
	CHK(mbedtls_mpi_write_binary(&t, buf, L));
	mbedtls_mpi_free(&t);
}

static msBigInt* tcRead(const uint8_t* buf, size_t L) {
	msBigInt* r = newBig();
	CHK(mbedtls_mpi_read_binary(&r->v, buf, L));
	if (buf[0] & 0x80) {
		mbedtls_mpi t;
		mbedtls_mpi_init(&t);
		CHK(mbedtls_mpi_lset(&t, 1));
		CHK(mbedtls_mpi_shift_l(&t, 8 * L));
		CHK(mbedtls_mpi_sub_mpi(&r->v, &r->v, &t));
		mbedtls_mpi_free(&t);
	}
	return r;
}

static msBigInt* bitwiseOp(const msBigInt* a, const msBigInt* b, int op) {
	size_t L = mbedtls_mpi_size(&a->v);
	size_t lb = mbedtls_mpi_size(&b->v);
	if (lb > L) L = lb;
	L += 1;
	uint8_t* ba = (uint8_t*)malloc(L * 2);
	if (ba == NULL) bigFail("out of memory");
	uint8_t* bb = ba + L;
	tcWrite(&a->v, ba, L);
	tcWrite(&b->v, bb, L);
	for (size_t i = 0; i < L; i++) {
		ba[i] = op == 0 ? (ba[i] & bb[i]) : op == 1 ? (ba[i] | bb[i]) : (ba[i] ^ bb[i]);
	}
	msBigInt* r = tcRead(ba, L);
	free(ba);
	return r;
}

msBigInt* msBigIntAnd(const msBigInt* a, const msBigInt* b) { return bitwiseOp(a, b, 0); }
msBigInt* msBigIntOr(const msBigInt* a, const msBigInt* b) { return bitwiseOp(a, b, 1); }
msBigInt* msBigIntXor(const msBigInt* a, const msBigInt* b) { return bitwiseOp(a, b, 2); }

static size_t shiftCount(const msBigInt* b, int* negOut) {
	int neg = mbedtls_mpi_cmp_int(&b->v, 0) < 0;
	*negOut = neg;
	mbedtls_mpi m, zero;
	mbedtls_mpi_init(&m); mbedtls_mpi_init(&zero);
	CHK(mbedtls_mpi_lset(&zero, 0));
	if (neg) CHK(mbedtls_mpi_sub_mpi(&m, &zero, &b->v));
	else CHK(mbedtls_mpi_copy(&m, &b->v));
	if (mbedtls_mpi_size(&m) > 8) bigFail("shift count too large");
	uint8_t buf[8] = {0};
	CHK(mbedtls_mpi_write_binary(&m, buf, 8));
	uint64_t u = 0;
	for (int i = 0; i < 8; i++) u = (u << 8) | buf[i];
	mbedtls_mpi_free(&m); mbedtls_mpi_free(&zero);
	if (u > (uint64_t)1 << 40) bigFail("shift count too large");
	return (size_t)u;
}

static msBigInt* shrBy(const msBigInt* a, size_t n);

static msBigInt* shlBy(const msBigInt* a, size_t n) {
	msBigInt* r = newBig();
	CHK(mbedtls_mpi_copy(&r->v, &a->v));
	CHK(mbedtls_mpi_shift_l(&r->v, n));
	return r;
}

/* JS >> is floor division by 2^n; mpi shift_r is a magnitude shift, so a
 * negative value that loses bits must be adjusted one step further down. */
static msBigInt* shrBy(const msBigInt* a, size_t n) {
	int neg = mbedtls_mpi_cmp_int(&a->v, 0) < 0;
	mbedtls_mpi m, zero, back;
	mbedtls_mpi_init(&m); mbedtls_mpi_init(&zero); mbedtls_mpi_init(&back);
	CHK(mbedtls_mpi_lset(&zero, 0));
	if (neg) CHK(mbedtls_mpi_sub_mpi(&m, &zero, &a->v));
	else CHK(mbedtls_mpi_copy(&m, &a->v));
	msBigInt* r = newBig();
	CHK(mbedtls_mpi_copy(&r->v, &m));
	CHK(mbedtls_mpi_shift_r(&r->v, n));
	if (neg) {
		CHK(mbedtls_mpi_copy(&back, &r->v));
		CHK(mbedtls_mpi_shift_l(&back, n));
		if (mbedtls_mpi_cmp_mpi(&back, &m) != 0) CHK(mbedtls_mpi_add_int(&r->v, &r->v, 1));
		CHK(mbedtls_mpi_sub_mpi(&r->v, &zero, &r->v));
	}
	mbedtls_mpi_free(&m); mbedtls_mpi_free(&zero); mbedtls_mpi_free(&back);
	return r;
}

msBigInt* msBigIntShl(const msBigInt* a, const msBigInt* b) {
	int neg;
	size_t n = shiftCount(b, &neg);
	return neg ? shrBy(a, n) : shlBy(a, n);
}

msBigInt* msBigIntShr(const msBigInt* a, const msBigInt* b) {
	int neg;
	size_t n = shiftCount(b, &neg);
	return neg ? shlBy(a, n) : shrBy(a, n);
}

int32_t msBigIntCmp(const msBigInt* a, const msBigInt* b) {
	return (int32_t)mbedtls_mpi_cmp_mpi(&a->v, &b->v);
}

bool msBigIntIsZero(const msBigInt* a) {
	return mbedtls_mpi_cmp_int(&a->v, 0) == 0;
}

msBigInt* msBigIntAsUintN(int64_t bits, const msBigInt* a) {
	if (bits < 0) bigFail("asUintN bits must be non-negative");
	mbedtls_mpi p2;
	mbedtls_mpi_init(&p2);
	CHK(mbedtls_mpi_lset(&p2, 1));
	CHK(mbedtls_mpi_shift_l(&p2, (size_t)bits));
	msBigInt* r = newBig();
	int rc = mbedtls_mpi_div_mpi(NULL, &r->v, &a->v, &p2);
	CHK(rc);
	if (mbedtls_mpi_cmp_int(&r->v, 0) < 0) CHK(mbedtls_mpi_add_mpi(&r->v, &r->v, &p2));
	mbedtls_mpi_free(&p2);
	return r;
}

msBigInt* msBigIntAsIntN(int64_t bits, const msBigInt* a) {
	if (bits < 0) bigFail("asIntN bits must be non-negative");
	msBigInt* u = msBigIntAsUintN(bits, a);
	if (bits == 0) return u;
	mbedtls_mpi half, p2;
	mbedtls_mpi_init(&half); mbedtls_mpi_init(&p2);
	CHK(mbedtls_mpi_lset(&half, 1));
	CHK(mbedtls_mpi_shift_l(&half, (size_t)(bits - 1)));
	if (mbedtls_mpi_cmp_mpi(&u->v, &half) >= 0) {
		CHK(mbedtls_mpi_lset(&p2, 1));
		CHK(mbedtls_mpi_shift_l(&p2, (size_t)bits));
		CHK(mbedtls_mpi_sub_mpi(&u->v, &u->v, &p2));
	}
	mbedtls_mpi_free(&half); mbedtls_mpi_free(&p2);
	return u;
}

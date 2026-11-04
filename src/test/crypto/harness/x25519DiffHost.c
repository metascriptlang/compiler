#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The MetaScript staticlib carries its own mbedtls; x25519Diff.sh renames every mbedtls_/psa_ symbol of the pinned oracle archive to oracle_<name>. */
#define mbedtls_ecp_group_init oracle_mbedtls_ecp_group_init
#define mbedtls_ecp_group_load oracle_mbedtls_ecp_group_load
#define mbedtls_ecp_point_init oracle_mbedtls_ecp_point_init
#define mbedtls_ecp_point_free oracle_mbedtls_ecp_point_free
#define mbedtls_ecp_mul oracle_mbedtls_ecp_mul
#define mbedtls_mpi_init oracle_mbedtls_mpi_init
#define mbedtls_mpi_free oracle_mbedtls_mpi_free
#define mbedtls_mpi_lset oracle_mbedtls_mpi_lset
#define mbedtls_mpi_read_binary_le oracle_mbedtls_mpi_read_binary_le
#define mbedtls_mpi_write_binary_le oracle_mbedtls_mpi_write_binary_le
#define mbedtls_version_get_string_full oracle_mbedtls_version_get_string_full

#include <mbedtls/bignum.h>
#include <mbedtls/ecp.h>
#include <mbedtls/version.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <sodium.h>

#ifndef MS_ENTRY_DATINIT
#error "pass -DMS_ENTRY_DATINIT=<entry module __DatInit000> and -DMS_ENTRY_INIT=<entry module __Init000> from the staticlib's _dispatch.c"
#endif

extern void MS_ENTRY_DATINIT(void);
extern void MS_ENTRY_INIT(void);
#ifdef MS_ENTRY_DEP_INIT
extern void MS_ENTRY_DEP_INIT(void);
#endif
extern void x25519ScalarMult(uint8_t *output, const uint8_t *scalar, const uint8_t *point);
extern void ref_crypto_x25519(uint8_t output[32], const uint8_t scalar[32], const uint8_t point[32]);

#define PINNED_OPENSSL "OpenSSL 3.0.13 30 Jan 2024"
#define PINNED_SODIUM "1.0.18"
#define PINNED_MBEDTLS "Mbed TLS 2.28.8"

enum {
	exitKnownAnswer = 10,
	exitUsage = 16,
	exitVersion = 17,
	exitMismatch = 20,
	exitUnexpectedRefusal = 21,
	exitProperty = 22,
	exitControlNotApplied = 23,
};

enum { implCandidate, implReference, implOpenssl, implSodium, implMbedtls, implCount };
enum { subjectCount = 2, oracleFirst = implOpenssl };
static const char *implName[implCount] = {"candidate", "monocypher", "openssl", "libsodium", "mbedtls"};

enum { statusOk, statusRefusedImport, statusRefusedDerive };

typedef struct {
	int status;
	uint8_t out[32];
	const char *reason;
	int libraryCode;
} Result;

typedef struct {
	long agree, zeroAgree, zeroRefused, refusedNonzero, refusedImport, mismatch;
} Stats;

typedef struct {
	const char *name;
	long first, count;
	Stats vsOracle[subjectCount][implCount - oracleFirst];
	long candidateRefAgree, candidateRefMismatch, rawZero, highBitAlias, clampAlias;
} Axis;

enum { axisLowOrder, axisHighBit, axisNonCanonical, axisClamp, axisRandom, axisCount };
static Axis axes[axisCount] = {{"lowOrder"}, {"highBit"}, {"nonCanonical"}, {"clamp"}, {"random"}};

typedef struct {
	int axis;
	uint8_t scalar[32];
	uint8_t point[32];
} Sample;

static uint64_t seed = 0x25519d1ffULL;
static long randomSamples = 2000;
static long onlyIndex = -1;
static const char *candidateLabel = "candidate";
static int corruptImpl = -1;
static int forceRefuseImpl = -1;
static int controlApplied = 0;
static long printedFailures = 0;
static int firstFailureExit = 0;
static long mbedtlsMaskedHighBit = 0;
static long failureTotal = 0;

static uint8_t scalarBuf[32] __attribute__((aligned(64)));
static uint8_t pointBuf[32] __attribute__((aligned(64)));
static uint8_t outputBuf[32] __attribute__((aligned(64)));

static mbedtls_ecp_group mbedGroup;

static void fromHex(uint8_t out[32], const char *hex) {
	for (int i = 0; i < 32; i++) {
		unsigned v;
		if (strlen(hex) != 64 || sscanf(hex + 2 * i, "%2x", &v) != 1) {
			fprintf(stderr, "bad hex in table: %s\n", hex);
			exit(exitUsage);
		}
		out[i] = (uint8_t)v;
	}
}

static void hexOf(char dst[65], const uint8_t b[32]) {
	for (int i = 0; i < 32; i++) sprintf(dst + 2 * i, "%02x", b[i]);
}

static int isZero(const uint8_t b[32]) {
	uint8_t acc = 0;
	for (int i = 0; i < 32; i++) acc |= b[i];
	return acc == 0;
}

static void clampScalar(uint8_t out[32], const uint8_t in[32]) {
	memcpy(out, in, 32);
	out[0] &= 248;
	out[31] &= 127;
	out[31] |= 64;
}

static uint64_t splitmix(uint64_t *state) {
	uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

static void randomBytes(uint64_t *state, uint8_t out[32]) {
	for (int i = 0; i < 4; i++) {
		uint64_t v = splitmix(state);
		memcpy(out + 8 * i, &v, 8);
	}
}

static Result candidateMult(const uint8_t *scalar, const uint8_t *point) {
	Result r = {statusOk, {0}, NULL, 0};
	memcpy(scalarBuf, scalar, 32);
	memcpy(pointBuf, point, 32);
	memset(outputBuf, 0xaa, 32);
	x25519ScalarMult(outputBuf, scalarBuf, pointBuf);
	memcpy(r.out, outputBuf, 32);
	return r;
}

static Result referenceMult(const uint8_t *scalar, const uint8_t *point) {
	Result r = {statusOk, {0}, NULL, 0};
	memset(r.out, 0xaa, 32);
	ref_crypto_x25519(r.out, scalar, point);
	return r;
}

static Result opensslMult(const uint8_t *scalar, const uint8_t *point) {
	Result r = {statusOk, {0}, NULL, 0};
	EVP_PKEY *priv = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, scalar, 32);
	EVP_PKEY *pub = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, point, 32);
	EVP_PKEY_CTX *ctx = NULL;
	size_t len = 32;
	if (priv == NULL || pub == NULL) {
		r.status = statusRefusedImport;
		r.reason = "EVP_PKEY_new_raw_{private,public}_key failed";
	} else if ((ctx = EVP_PKEY_CTX_new(priv, NULL)) == NULL || EVP_PKEY_derive_init(ctx) <= 0 ||
		EVP_PKEY_derive_set_peer(ctx, pub) <= 0) {
		r.status = statusRefusedImport;
		r.reason = "EVP_PKEY_derive_init/set_peer failed";
	} else if (EVP_PKEY_derive(ctx, NULL, &len) <= 0 || len != 32) {
		r.status = statusRefusedImport;
		r.reason = "EVP_PKEY_derive length query failed or not 32";
	} else if (EVP_PKEY_derive(ctx, r.out, &len) <= 0) {
		r.status = statusRefusedDerive;
		r.reason = "EVP_PKEY_derive refused";
	} else if (len != 32) {
		r.status = statusRefusedDerive;
		r.reason = "EVP_PKEY_derive wrote other than 32 bytes";
	}
	EVP_PKEY_CTX_free(ctx);
	EVP_PKEY_free(priv);
	EVP_PKEY_free(pub);
	ERR_clear_error();
	return r;
}

static Result sodiumMult(const uint8_t *scalar, const uint8_t *point) {
	Result r = {statusOk, {0}, NULL, 0};
	if (crypto_scalarmult_curve25519(r.out, scalar, point) != 0) {
		r.status = statusRefusedDerive;
		r.reason = "crypto_scalarmult_curve25519 returned -1";
	}
	return r;
}

static uint64_t mbedtlsBlindingState = 0x6d62656474;

static int mbedtlsBlindingRng(void *unused, unsigned char *buf, size_t len) {
	(void)unused;
	for (size_t i = 0; i < len; i++) buf[i] = (uint8_t)splitmix(&mbedtlsBlindingState);
	return 0;
}

static Result mbedtlsMult(const uint8_t *scalar, const uint8_t *point) {
	Result r = {statusOk, {0}, NULL, 0};
	uint8_t d[32], u[32];
	mbedtls_mpi dm;
	mbedtls_ecp_point P, R;
	mbedtls_mpi_init(&dm);
	mbedtls_ecp_point_init(&P);
	mbedtls_ecp_point_init(&R);
	clampScalar(d, scalar);
	memcpy(u, point, 32);
	if (u[31] & 0x80) {
		u[31] &= 0x7f;
		mbedtlsMaskedHighBit++;
	}
	int rc = mbedtls_mpi_read_binary_le(&dm, d, 32);
	if (rc == 0) rc = mbedtls_mpi_read_binary_le(&P.X, u, 32);
	if (rc == 0) rc = mbedtls_mpi_lset(&P.Z, 1);
	if (rc != 0) {
		r.status = statusRefusedImport;
		r.reason = "mbedtls_mpi import failed";
	} else if ((rc = mbedtls_ecp_mul(&mbedGroup, &R, &dm, &P, mbedtlsBlindingRng, NULL)) != 0) {
		r.status = statusRefusedDerive;
		r.libraryCode = rc;
		r.reason = rc == MBEDTLS_ERR_MPI_NOT_ACCEPTABLE ? "mbedtls_ecp_mul: MBEDTLS_ERR_MPI_NOT_ACCEPTABLE (inverse of zero)"
			: "mbedtls_ecp_mul returned an error";
	} else if (mbedtls_mpi_write_binary_le(&R.X, r.out, 32) != 0) {
		r.status = statusRefusedDerive;
		r.reason = "mbedtls_mpi_write_binary_le failed";
	}
	mbedtls_mpi_free(&dm);
	mbedtls_ecp_point_free(&P);
	mbedtls_ecp_point_free(&R);
	return r;
}

static Result runImpl(int impl, const uint8_t *scalar, const uint8_t *point) {
	switch (impl) {
		case implCandidate: return candidateMult(scalar, point);
		case implReference: return referenceMult(scalar, point);
		case implOpenssl: return opensslMult(scalar, point);
		case implSodium: return sodiumMult(scalar, point);
		default: return mbedtlsMult(scalar, point);
	}
}

typedef struct {
	const char *name;
	const char *scalarHex;
	const char *pointHex;
	const char *outputHex;
} Case;

static const Case katCases[] = {
	{"rfc7748-5.2-1",
		"a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
		"e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
		"c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"},
	{"rfc7748-5.2-2",
		"4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
		"e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
		"95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"},
	{"rfc7748-6.1-alice-public",
		"77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a",
		"0900000000000000000000000000000000000000000000000000000000000000",
		"8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"},
	{"rfc7748-6.1-bob-public",
		"5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb",
		"0900000000000000000000000000000000000000000000000000000000000000",
		"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"},
	{"rfc7748-6.1-shared",
		"77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a",
		"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f",
		"4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"},
	{"low-order-zero-output",
		"a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
		"0000000000000000000000000000000000000000000000000000000000000000",
		"0000000000000000000000000000000000000000000000000000000000000000"},
};
static const size_t katCount = sizeof katCases / sizeof katCases[0];

static const char *iterated1 = "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079";
static const char *iterated1000 = "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51";

static const char *lowOrderPoints[] = {
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0100000000000000000000000000000000000000000000000000000000000000",
	"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
	"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
	"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
};
enum { lowOrderBase = 7, lowOrderPointCount = lowOrderBase * 2, fixedScalarCount = 8, lowOrderRandomScalars = 8 };

static const char *fixedScalars[fixedScalarCount] = {
	"0000000000000000000000000000000000000000000000000000000000000000",
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"0800000000000000000000000000000000000000000000000000000000000000",
	"0100000000000000000000000000000000000000000000000000000000000000",
	"a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
	"f8ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"0000000000000000000000000000000000000000000000000000000000000040",
	"0000000000000000000000000000000000000000000000000000000000000080",
};

enum { nonCanonicalPoints = 19 * 2, nonCanonicalFixedScalars = 2, nonCanonicalRandomScalars = 6, clampEdgeUs = 8 };

static void layoutAxes(void) {
	axes[axisLowOrder].count = lowOrderPointCount * (fixedScalarCount + lowOrderRandomScalars);
	axes[axisHighBit].count = randomSamples;
	axes[axisNonCanonical].count = nonCanonicalPoints * (nonCanonicalFixedScalars + nonCanonicalRandomScalars);
	axes[axisClamp].count = randomSamples + fixedScalarCount * clampEdgeUs;
	axes[axisRandom].count = randomSamples;
	long at = 0;
	for (int a = 0; a < axisCount; a++) {
		axes[a].first = at;
		at += axes[a].count;
	}
}

static long totalSamples(void) {
	return axes[axisCount - 1].first + axes[axisCount - 1].count;
}

static void genSample(long index, Sample *s) {
	int a = 0;
	while (a + 1 < axisCount && index >= axes[a + 1].first) a++;
	long j = index - axes[a].first;
	uint64_t state = seed ^ ((uint64_t)index * 0x9E3779B97F4A7C15ULL);
	s->axis = a;
	switch (a) {
		case axisLowOrder: {
			long perPoint = fixedScalarCount + lowOrderRandomScalars;
			long p = j / perPoint, k = j % perPoint;
			fromHex(s->point, lowOrderPoints[p % lowOrderBase]);
			if (p >= lowOrderBase) s->point[31] |= 0x80;
			if (k < fixedScalarCount) fromHex(s->scalar, fixedScalars[k]);
			else randomBytes(&state, s->scalar);
			break;
		}
		case axisHighBit:
			randomBytes(&state, s->scalar);
			randomBytes(&state, s->point);
			s->point[31] |= 0x80;
			break;
		case axisNonCanonical: {
			long perPoint = nonCanonicalFixedScalars + nonCanonicalRandomScalars;
			long p = j / perPoint, k = j % perPoint;
			memset(s->point, 0xff, 32);
			s->point[0] = (uint8_t)(0xed + p % 19);
			s->point[31] = p >= 19 ? 0xff : 0x7f;
			if (k < nonCanonicalFixedScalars) fromHex(s->scalar, fixedScalars[k == 0 ? 4 : 1]);
			else randomBytes(&state, s->scalar);
			break;
		}
		case axisClamp:
			if (j < randomSamples) {
				randomBytes(&state, s->scalar);
				randomBytes(&state, s->point);
				switch (j % 4) {
					case 1: s->scalar[0] |= 7; s->scalar[31] = (s->scalar[31] & 0x3f) | 0x80; break;
					case 2: s->scalar[0] &= 0xf8; s->scalar[31] = (s->scalar[31] & 0x7f) | 0x40; break;
					case 3: clampScalar(s->scalar, s->scalar); break;
					default: break;
				}
			} else {
				j -= randomSamples;
				fromHex(s->scalar, fixedScalars[j / clampEdgeUs]);
				randomBytes(&state, s->point);
			}
			break;
		default:
			randomBytes(&state, s->scalar);
			if (j % 4 == 0) {
				memset(s->point, 0, 32);
				s->point[0] = 9;
			} else {
				randomBytes(&state, s->point);
			}
			break;
	}
}

static const char *argvLine = "";

static void printSample(const Sample *s, const Result r[implCount]) {
	char h[65];
	hexOf(h, s->scalar);
	printf("    scalar   %s\n", h);
	hexOf(h, s->point);
	printf("    point    %s\n", h);
	for (int i = 0; i < implCount; i++) {
		if (r[i].status == statusOk) {
			hexOf(h, r[i].out);
			printf("    %-10s %s%s\n", implName[i], h, isZero(r[i].out) ? " (raw all-zero output)" : "");
		} else {
			printf("    %-10s REFUSED (%s, library code %d)\n", implName[i], r[i].reason, r[i].libraryCode);
		}
	}
}

static void recordFailure(int exitCode, long index, const Sample *s, const Result r[implCount], const char *what) {
	failureTotal++;
	if (firstFailureExit == 0) firstFailureExit = exitCode;
	if (printedFailures >= 8) return;
	printedFailures++;
	printf("  FAIL %s at sample %ld axis %s\n", what, index, axes[s->axis].name);
	printSample(s, r);
	printf("    repro    %s --only %ld\n", argvLine, index);
}

static void classify(Axis *axis, long index, const Sample *s, const Result r[implCount], int subject, int oracle) {
	Stats *st = &axis->vsOracle[subject][oracle - oracleFirst];
	const Result *sub = &r[subject];
	const Result *ora = &r[oracle];
	int zero = isZero(sub->out);
	char what[160];
	if (ora->status == statusOk) {
		if (memcmp(sub->out, ora->out, 32) == 0) {
			if (zero) st->zeroAgree++;
			else st->agree++;
		} else {
			st->mismatch++;
			snprintf(what, sizeof what, "MISMATCH %s vs %s", implName[subject], implName[oracle]);
			recordFailure(exitMismatch, index, s, r, what);
		}
	} else if (ora->status == statusRefusedDerive && zero) {
		st->zeroRefused++;
	} else if (ora->status == statusRefusedDerive) {
		st->refusedNonzero++;
		snprintf(what, sizeof what, "UNEXPECTED REFUSAL by %s of a case where %s output is not all-zero", implName[oracle], implName[subject]);
		recordFailure(exitUnexpectedRefusal, index, s, r, what);
	} else {
		st->refusedImport++;
		snprintf(what, sizeof what, "UNEXPECTED REFUSAL by %s before computing (import stage)", implName[oracle]);
		recordFailure(exitUnexpectedRefusal, index, s, r, what);
	}
}

static void applyControls(Result r[implCount]) {
	if (corruptImpl >= 0 && !controlApplied && r[corruptImpl].status == statusOk) {
		r[corruptImpl].out[0] ^= 1;
		controlApplied = 1;
	}
	if (forceRefuseImpl >= 0 && !controlApplied && r[forceRefuseImpl].status == statusOk &&
		!isZero(r[implReference].out)) {
		r[forceRefuseImpl].status = statusRefusedDerive;
		r[forceRefuseImpl].reason = "forced by --force-refuse";
		controlApplied = 1;
	}
}

static void checkProperties(Axis *axis, long index, const Sample *s, const Result r[implCount]) {
	uint8_t clamped[32], unmasked[32];
	clampScalar(clamped, s->scalar);
	memcpy(unmasked, s->point, 32);
	unmasked[31] ^= 0x80;
	for (int subject = 0; subject < subjectCount; subject++) {
		Result viaClamp = runImpl(subject, clamped, s->point);
		Result viaFlip = runImpl(subject, s->scalar, unmasked);
		if (memcmp(viaClamp.out, r[subject].out, 32) != 0) {
			recordFailure(exitProperty, index, s, r, "PROPERTY clamp(scalar) gives another result than scalar");
		} else {
			axis->clampAlias++;
		}
		if (memcmp(viaFlip.out, r[subject].out, 32) != 0) {
			recordFailure(exitProperty, index, s, r, "PROPERTY flipping bit 255 of the point changes the result");
		} else {
			axis->highBitAlias++;
		}
	}
}

static void runSample(long index) {
	Sample s;
	Result r[implCount];
	genSample(index, &s);
	Axis *axis = &axes[s.axis];
	for (int i = 0; i < implCount; i++) r[i] = runImpl(i, s.scalar, s.point);
	applyControls(r);
	if (memcmp(r[implCandidate].out, r[implReference].out, 32) != 0) {
		axis->candidateRefMismatch++;
		recordFailure(exitMismatch, index, &s, r, "MISMATCH candidate vs monocypher");
	} else {
		axis->candidateRefAgree++;
	}
	if (isZero(r[implCandidate].out)) axis->rawZero++;
	for (int subject = 0; subject < subjectCount; subject++)
		for (int o = oracleFirst; o < implCount; o++) classify(axis, index, &s, r, subject, o);
	checkProperties(axis, index, &s, r);
}

static int checkVersions(void) {
	int bad = 0;
	const char *runtimeOpenssl = OpenSSL_version(OPENSSL_VERSION);
	char mbedBuf[32];
	mbedtls_version_get_string_full(mbedBuf);
	if (sodium_init() < 0) {
		printf("VERSION FAIL sodium_init failed\n");
		bad = 1;
	}
	printf("versions: openssl header \"%s\" runtime \"%s\"\n", OPENSSL_VERSION_TEXT, runtimeOpenssl);
	printf("versions: libsodium header \"%s\" runtime \"%s\" primitive \"%s\" library %d.%d\n", SODIUM_VERSION_STRING,
		sodium_version_string(), crypto_scalarmult_primitive(), sodium_library_version_major(), sodium_library_version_minor());
	printf("versions: mbedtls header \"%s\" runtime \"%s\"\n", MBEDTLS_VERSION_STRING_FULL, mbedBuf);
	if (strcmp(OPENSSL_VERSION_TEXT, PINNED_OPENSSL) || strcmp(runtimeOpenssl, PINNED_OPENSSL)) bad = 1;
	if (strcmp(SODIUM_VERSION_STRING, PINNED_SODIUM) || strcmp(sodium_version_string(), PINNED_SODIUM) ||
		strcmp(crypto_scalarmult_primitive(), "curve25519")) bad = 1;
	if (strcmp(MBEDTLS_VERSION_STRING_FULL, PINNED_MBEDTLS) || strcmp(mbedBuf, PINNED_MBEDTLS)) bad = 1;
	if (bad) printf("VERSION FAIL header or runtime differs from the pinned %s / %s / %s\n", PINNED_OPENSSL, PINNED_SODIUM, PINNED_MBEDTLS);
	return bad;
}

static int knownAnswers(void) {
	int failed = 0;
	for (int i = 0; i < implCount; i++) {
		size_t ok = 0;
		for (size_t c = 0; c < katCount; c++) {
			uint8_t scalar[32], point[32], expected[32];
			fromHex(scalar, katCases[c].scalarHex);
			fromHex(point, katCases[c].pointHex);
			fromHex(expected, katCases[c].outputHex);
			Result r = runImpl(i, scalar, point);
			int zeroExpected = isZero(expected);
			if (r.status == statusOk && memcmp(r.out, expected, 32) == 0) {
				ok++;
			} else if (zeroExpected && r.status == statusRefusedDerive) {
				printf("KAT %s %s: refused (%s) where the raw output is all-zero\n", implName[i], katCases[c].name, r.reason);
				ok++;
			} else {
				char h[65];
				printf("KAT FAIL %s %s: %s (library code %d)\n", implName[i], katCases[c].name, r.status == statusOk ? "wrong output" : r.reason, r.libraryCode);
				if (r.status == statusOk) {
					hexOf(h, r.out);
					printf("  got      %s\n", h);
					hexOf(h, expected);
					printf("  expected %s\n", h);
				}
				failed++;
			}
		}
		const char *label = i == implCandidate ? candidateLabel : implName[i];
		printf("KAT %s %zu/%zu\n", label, ok, katCount);
	}
	return failed;
}

static int iterations(void) {
	int failed = 0;
	for (int i = 0; i < implCount; i++) {
		uint8_t k[32] = {9}, u[32] = {9}, want1[32], want1000[32];
		fromHex(want1, iterated1);
		fromHex(want1000, iterated1000);
		int ok = 1;
		for (int n = 1; n <= 1000 && ok; n++) {
			Result r = runImpl(i, k, u);
			if (r.status != statusOk) {
				printf("ITER FAIL %s iteration %d refused (%s)\n", implName[i], n, r.reason);
				ok = 0;
				break;
			}
			memcpy(u, k, 32);
			memcpy(k, r.out, 32);
			if (n == 1 && memcmp(k, want1, 32) != 0) {
				printf("ITER FAIL %s after 1 iteration\n", implName[i]);
				ok = 0;
			}
		}
		if (ok && memcmp(k, want1000, 32) != 0) {
			printf("ITER FAIL %s after 1000 iterations\n", implName[i]);
			ok = 0;
		}
		failed += !ok;
		printf("ITER %s 1/1000 %s\n", i == implCandidate ? candidateLabel : implName[i], ok ? "ok" : "FAIL");
	}
	return failed;
}

static void printStats(const char *subjectLabel, const char *oracleLabel, const Stats *st) {
	printf("    %-10s vs %-9s agree=%ld zeroAgree=%ld zeroRefused=%ld refusedNonzero=%ld refusedImport=%ld mismatch=%ld\n",
		subjectLabel, oracleLabel, st->agree, st->zeroAgree, st->zeroRefused, st->refusedNonzero, st->refusedImport, st->mismatch);
}

static int parseImpl(const char *name) {
	for (int i = 0; i < implCount; i++)
		if (strcmp(name, implName[i]) == 0) return i;
	return -1;
}

int main(int argc, char **argv) {
	static char line[512];
	size_t used = 0;
	for (int i = 0; i < argc; i++) {
		if (strcmp(argv[i], "--only") == 0) {
			i++;
			continue;
		}
		used += (size_t)snprintf(line + used, sizeof line - used, "%s%s", used ? " " : "", argv[i]);
		if (used >= sizeof line) break;
	}
	argvLine = line;
	int badImplName = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) seed = strtoull(argv[++i], NULL, 0);
		else if (strcmp(argv[i], "--samples") == 0 && i + 1 < argc) randomSamples = strtol(argv[++i], NULL, 0);
		else if (strcmp(argv[i], "--only") == 0 && i + 1 < argc) onlyIndex = strtol(argv[++i], NULL, 0);
		else if (strcmp(argv[i], "--candidate-label") == 0 && i + 1 < argc) candidateLabel = argv[++i];
		else if (strcmp(argv[i], "--corrupt") == 0 && i + 1 < argc) badImplName |= (corruptImpl = parseImpl(argv[++i])) < 0;
		else if (strcmp(argv[i], "--force-refuse") == 0 && i + 1 < argc) badImplName |= (forceRefuseImpl = parseImpl(argv[++i])) < 0;
		else {
			fprintf(stderr,
				"usage: host [--seed N] [--samples N] [--only INDEX] [--candidate-label NAME] "
				"[--corrupt candidate|monocypher|openssl|libsodium|mbedtls] [--force-refuse openssl|libsodium|mbedtls]\n");
			return exitUsage;
		}
	}
	if (randomSamples < 1 || (forceRefuseImpl >= 0 && forceRefuseImpl < oracleFirst) || badImplName) {
		fprintf(stderr, "bad option value\n");
		return exitUsage;
	}

	MS_ENTRY_DATINIT();
#ifdef MS_ENTRY_DEP_INIT
	MS_ENTRY_DEP_INIT();
#endif
	MS_ENTRY_INIT();
	printf("STAGE init ok\n");
	printf("diff candidate=%s seed=0x%llx samplesPerRandomAxis=%ld\n", candidateLabel, (unsigned long long)seed, randomSamples);
	if (checkVersions() != 0) return exitVersion;
	mbedtls_ecp_group_init(&mbedGroup);
	if (mbedtls_ecp_group_load(&mbedGroup, MBEDTLS_ECP_DP_CURVE25519) != 0) {
		fprintf(stderr, "mbedtls_ecp_group_load(CURVE25519) failed\n");
		return exitVersion;
	}
	printf("STAGE versions ok\n");

	if (knownAnswers() != 0) return exitKnownAnswer;
	printf("STAGE kat ok\n");
	if (iterations() != 0) return exitKnownAnswer;
	printf("STAGE iterations ok\n");

	layoutAxes();
	long total = totalSamples();
	if (onlyIndex >= total) {
		fprintf(stderr, "--only %ld is outside 0..%ld\n", onlyIndex, total - 1);
		return exitUsage;
	}
	long ran = 0;
	for (long i = 0; i < total; i++) {
		if (onlyIndex >= 0 && i != onlyIndex) continue;
		runSample(i);
		ran++;
	}

	long mismatches = 0, refusals = 0, rawZero = 0, zeroRefused = 0;
	for (int a = 0; a < axisCount; a++) {
		Axis *axis = &axes[a];
		printf("axis %s samples=%ld first=%ld candidateVsMonocypher agree=%ld mismatch=%ld candidateRawZero=%ld clampAlias=%ld highBitAlias=%ld\n",
			axis->name, axis->count, axis->first, axis->candidateRefAgree, axis->candidateRefMismatch, axis->rawZero,
			axis->clampAlias, axis->highBitAlias);
		mismatches += axis->candidateRefMismatch;
		rawZero += axis->rawZero;
		for (int subject = 0; subject < subjectCount; subject++) {
			for (int o = oracleFirst; o < implCount; o++) {
				Stats *st = &axis->vsOracle[subject][o - oracleFirst];
				printStats(subject == implCandidate ? candidateLabel : implName[subject], implName[o], st);
				mismatches += st->mismatch;
				refusals += st->refusedNonzero + st->refusedImport;
				zeroRefused += st->zeroRefused;
			}
		}
	}
	printf("adapter: mbedtls clamps the scalar and masks bit 255 of the point itself (RFC 7748 section 5), masked %ld point(s)\n",
		mbedtlsMaskedHighBit);
	printf("TOTAL seed=0x%llx samples=%ld ran=%ld mismatches=%ld unexpectedRefusals=%ld candidateRawZero=%ld expectedZeroRefusals=%ld failures=%ld\n",
		(unsigned long long)seed, total, ran, mismatches, refusals, rawZero, zeroRefused, failureTotal);
	if ((corruptImpl >= 0 || forceRefuseImpl >= 0) && !controlApplied) {
		printf("CONTROL NOT APPLIED: the requested corruption never found an output to change\n");
		return exitControlNotApplied;
	}
	if (firstFailureExit != 0) {
		printf("RESULT FAIL\n");
		return firstFailureExit;
	}
	printf("RESULT PASS\n");
	return 0;
}

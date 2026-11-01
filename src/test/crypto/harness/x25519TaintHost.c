#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef X25519_TAINT
#include <valgrind/memcheck.h>
#endif

#ifndef MS_ENTRY_DATINIT
#error "pass -DMS_ENTRY_DATINIT=<entry module __DatInit000> and -DMS_ENTRY_INIT=<entry module __Init000> from the staticlib's _dispatch.c"
#endif

extern void MS_ENTRY_DATINIT(void);
extern void MS_ENTRY_INIT(void);
extern void x25519ScalarMult(uint8_t *output, const uint8_t *scalar, const uint8_t *point);

enum {
	exitKnownAnswer = 10,
	exitNotOnValgrind = 11,
	exitScalarNotSecret = 12,
	exitPointNotPublic = 13,
	exitTaintMissedOutput = 14,
	exitTaintedResultDiffers = 15,
	exitUsage = 16,
};

typedef struct {
	const char *name;
	const char *scalarHex;
	const char *pointHex;
	const char *outputHex;
} Case;

static const Case cases[] = {
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

static const size_t caseCount = sizeof cases / sizeof cases[0];

static void fromHex(uint8_t out[32], const char *hex) {
	for (int i = 0; i < 32; i++) {
		unsigned v;
		if (sscanf(hex + 2 * i, "%2x", &v) != 1) {
			fprintf(stderr, "bad hex in case table\n");
			exit(exitUsage);
		}
		out[i] = (uint8_t)v;
	}
}

static void printHex(const char *label, const uint8_t *b) {
	printf("%s ", label);
	for (int i = 0; i < 32; i++) printf("%02x", b[i]);
	printf("\n");
}

static uint8_t scalarBuf[32] __attribute__((aligned(64)));
static uint8_t pointBuf[32] __attribute__((aligned(64)));
static uint8_t outputBuf[32] __attribute__((aligned(64)));

static int knownAnswers(void) {
	int failed = 0;
	for (size_t i = 0; i < caseCount; i++) {
		uint8_t expected[32];
		fromHex(scalarBuf, cases[i].scalarHex);
		fromHex(pointBuf, cases[i].pointHex);
		fromHex(expected, cases[i].outputHex);
		memset(outputBuf, 0xaa, 32);
		x25519ScalarMult(outputBuf, scalarBuf, pointBuf);
		if (memcmp(outputBuf, expected, 32) != 0) {
			printf("KAT FAIL %s\n", cases[i].name);
			printHex("  got     ", outputBuf);
			printHex("  expected", expected);
			failed++;
		} else {
			printf("KAT ok %s\n", cases[i].name);
		}
	}
	return failed;
}

#ifdef X25519_TAINT
static int undefinedBytes(const uint8_t *buf, size_t len) {
	uint8_t vbits[32];
	if (VALGRIND_GET_VBITS(buf, vbits, len) != 1) {
		fprintf(stderr, "VALGRIND_GET_VBITS did not answer 1: memcheck instrumentation missing\n");
		exit(exitNotOnValgrind);
	}
	int count = 0;
	for (size_t i = 0; i < len; i++) count += vbits[i] != 0;
	return count;
}

static int taintCases(int requireTaintedOutput) {
	for (size_t i = 0; i < caseCount; i++) {
		uint8_t expectedUntainted[32];
		fromHex(scalarBuf, cases[i].scalarHex);
		fromHex(pointBuf, cases[i].pointHex);
		memset(outputBuf, 0xaa, 32);
		x25519ScalarMult(outputBuf, scalarBuf, pointBuf);
		memcpy(expectedUntainted, outputBuf, 32);

		fromHex(scalarBuf, cases[i].scalarHex);
		fromHex(pointBuf, cases[i].pointHex);
		memset(outputBuf, 0xaa, 32);
		VALGRIND_MAKE_MEM_UNDEFINED(scalarBuf, 32);

		int scalarSecret = undefinedBytes(scalarBuf, 32);
		int pointSecret = undefinedBytes(pointBuf, 32);
		int outputSecretBefore = undefinedBytes(outputBuf, 32);
		if (scalarSecret != 32) {
			printf("TAINT FAIL %s: %d of 32 scalar bytes secret\n", cases[i].name, scalarSecret);
			return exitScalarNotSecret;
		}
		if (pointSecret != 0 || outputSecretBefore != 0) {
			printf("TAINT FAIL %s: point secret bytes %d, output secret bytes %d before the call\n", cases[i].name, pointSecret, outputSecretBefore);
			return exitPointNotPublic;
		}

		x25519ScalarMult(outputBuf, scalarBuf, pointBuf);

		int outputSecretAfter = undefinedBytes(outputBuf, 32);
		int pointSecretAfter = undefinedBytes(pointBuf, 32);
		printf("TAINT %s: output secret bytes after call %d of 32, point secret bytes %d\n", cases[i].name, outputSecretAfter, pointSecretAfter);
		if (pointSecretAfter != 0) {
			printf("TAINT FAIL %s: public point changed to secret\n", cases[i].name);
			return exitPointNotPublic;
		}
		if (requireTaintedOutput && outputSecretAfter == 0) {
			printf("TAINT FAIL %s: taint never reached the output, the kernel did not read the scalar\n", cases[i].name);
			return exitTaintMissedOutput;
		}

		VALGRIND_MAKE_MEM_DEFINED(outputBuf, 32);
		if (memcmp(outputBuf, expectedUntainted, 32) != 0) {
			printf("TAINT FAIL %s: tainted call returned another value than the untainted call\n", cases[i].name);
			return exitTaintedResultDiffers;
		}
		VALGRIND_MAKE_MEM_DEFINED(scalarBuf, 32);
	}
	return 0;
}
#endif

int main(int argc, char **argv) {
	int checkKnownAnswers = 1;
	int taint = 0;
	int requireTaintedOutput = 1;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--no-kat") == 0) checkKnownAnswers = 0;
		else if (strcmp(argv[i], "--taint") == 0) taint = 1;
		else if (strcmp(argv[i], "--no-output-taint-check") == 0) requireTaintedOutput = 0;
		else {
			fprintf(stderr, "usage: host [--no-kat] [--taint] [--no-output-taint-check]\n");
			return exitUsage;
		}
	}

	(void)requireTaintedOutput;
	MS_ENTRY_DATINIT();
	MS_ENTRY_INIT();
	printf("STAGE init ok\n");

	if (checkKnownAnswers) {
		if (knownAnswers() != 0) return exitKnownAnswer;
		printf("STAGE kat ok\n");
	}

	if (taint) {
#ifdef X25519_TAINT
		if (!RUNNING_ON_VALGRIND) {
			fprintf(stderr, "--taint needs the host to run under valgrind memcheck\n");
			return exitNotOnValgrind;
		}
		int status = taintCases(requireTaintedOutput);
		if (status != 0) return status;
		printf("STAGE taint ok\n");
#else
		fprintf(stderr, "built without -DX25519_TAINT: no taint instrumentation\n");
		return exitNotOnValgrind;
#endif
	}
	printf("STAGE done\n");
	return 0;
}

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(__x86_64__) && !defined(__aarch64__)
#error "no dudect timer for this architecture: the pinned header has rdtsc (x86-64) and armShim has cntvct_el0 (AArch64)"
#endif

#define DUDECT_IMPLEMENTATION
#include "dudect.h"

#ifndef MS_ENTRY_DATINIT
#error "pass -DMS_ENTRY_DATINIT=<entry module __DatInit000> and -DMS_ENTRY_INIT=<entry module __Init000> from the staticlib's _dispatch.c"
#endif

extern void MS_ENTRY_DATINIT(void);
extern void MS_ENTRY_INIT(void);
extern void x25519ScalarMult(uint8_t *output, const uint8_t *scalar, const uint8_t *point);

enum {
	exitNoLeakageEvidence = 0,
	exitKnownAnswer = 10,
	exitUsage = 16,
	exitLeakageFound = 20,
	exitInconclusive = 21,
};

enum {
	scalarBytes = 32,
	minMeasurements = 1000,
	maxMeasurements = 1000000,
	maxBatches = 1000000,
	maxTotalMeasurements = 500000000,
	maxLeakSpin = 1000000,
};

static const char *defaultFixedHex = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4";
static const char *publicPointHex = "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c";
static const char *knownAnswerHex = "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552";

static uint8_t fixedScalar[scalarBytes];
static uint8_t publicPoint[scalarBytes];
static uint8_t outputBuf[scalarBytes];
static volatile uint8_t outputSink;
static uint64_t leakSpin;
static int nullExperiment;
static uint64_t rngState;

static void usage(const char *why) {
	fprintf(stderr, "x25519DudectHost: %s\n", why);
	fprintf(stderr,
		"usage: host [--measurements M] [--batches B] [--seed S] [--fixed-hex H] [--no-kat] [--null] [--leak-spin N]\n"
		"  M per-batch measurements %d..%d (default 5000), B dudect_main calls 2..%d (default 40, the first only warms up),\n"
		"  M*B at most %d, S decimal or 0x hex (default: from /dev/urandom, printed), H 64 hex digits (default RFC 7748 5.2 #1),\n"
		"  --null draws both classes random (no leak exists), --leak-spin N adds N spin steps before the kernel when scalar[0] is odd\n",
		minMeasurements, maxMeasurements, maxBatches, maxTotalMeasurements);
	exit(exitUsage);
}

static void fromHex(uint8_t out[scalarBytes], const char *hex) {
	if (strlen(hex) != 2 * scalarBytes) usage("hex value is not 64 digits");
	for (int i = 0; i < scalarBytes; i++) {
		char pair[3] = {hex[2 * i], hex[2 * i + 1], 0};
		char *end;
		out[i] = (uint8_t)strtoul(pair, &end, 16);
		if (*end != 0) usage("bad hex digit");
	}
}

static void printHex(const uint8_t *b) {
	for (int i = 0; i < scalarBytes; i++) printf("%02x", b[i]);
}

static uint64_t nextRandom(void) {
	uint64_t z = (rngState += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

static void randomBytes(uint8_t *out, size_t n) {
	for (size_t i = 0; i < n; i += 8) {
		uint64_t r = nextRandom();
		for (size_t j = 0; j < 8 && i + j < n; j++) out[i + j] = (uint8_t)(r >> (8 * j));
	}
}

static uint64_t seedFromUrandom(void) {
	uint64_t s = 0;
	FILE *f = fopen("/dev/urandom", "rb");
	if (f == NULL || fread(&s, sizeof s, 1, f) != 1) usage("cannot read /dev/urandom for the default seed, pass --seed");
	fclose(f);
	return s;
}

static uint64_t parseNumber(const char *text, uint64_t lo, uint64_t hi, const char *what) {
	char *end;
	if (text[0] == 0 || text[0] == '-') usage(what);
	uint64_t v = strtoull(text, &end, 0);
	if (*end != 0 || v < lo || v > hi) usage(what);
	return v;
}

void prepare_inputs(dudect_config_t *c, uint8_t *input_data, uint8_t *classes) {
	for (size_t i = 0; i < c->number_measurements; i++) {
		uint8_t *chunk = input_data + i * c->chunk_size;
		classes[i] = (uint8_t)(nextRandom() >> 63);
		if (classes[i] == 0 && !nullExperiment) memcpy(chunk, fixedScalar, scalarBytes);
		else randomBytes(chunk, scalarBytes);
	}
}

static void spinFor(uint64_t steps) {
	volatile uint64_t acc = 0;
	for (uint64_t i = 0; i < steps; i++) acc += i;
}

uint8_t do_one_computation(uint8_t *data) {
	if (leakSpin != 0 && (data[0] & 1)) spinFor(leakSpin);
	x25519ScalarMult(outputBuf, data, publicPoint);
	uint8_t fold = 0;
	for (int i = 0; i < scalarBytes; i++) fold ^= outputBuf[i];
	outputSink ^= fold;
	return fold;
}

static int knownAnswer(void) {
	uint8_t expected[scalarBytes], got[scalarBytes], scalar[scalarBytes];
	fromHex(expected, knownAnswerHex);
	fromHex(scalar, defaultFixedHex);
	memset(got, 0xaa, sizeof got);
	x25519ScalarMult(got, scalar, publicPoint);
	if (memcmp(got, expected, scalarBytes) != 0) {
		printf("KAT FAIL got ");
		printHex(got);
		printf(" expected ");
		printHex(expected);
		printf("\n");
		return 0;
	}
	printf("KAT ok rfc7748-5.2-1\n");
	return 1;
}

static void printTimer(void) {
#if defined(__x86_64__)
	printf("CONFIG timer=x86-64 _mm_mfence+__rdtsc (upstream dudect.h cpucycles, TSC ticks)\n");
#else
	uint64_t freq;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	printf("CONFIG timer=aarch64 dsb sy+isb+cntvct_el0 via armShim (generic timer ticks, cntfrq_el0=%llu Hz, not CPU cycles)\n", (unsigned long long)freq);
#endif
}

int main(int argc, char **argv) {
	size_t measurements = 5000;
	uint64_t batches = 40;
	uint64_t seed = 0;
	int seedGiven = 0;
	int checkKnownAnswer = 1;
	const char *fixedHex = defaultFixedHex;
	for (int i = 1; i < argc; i++) {
		int hasValue = i + 1 < argc;
		if (strcmp(argv[i], "--measurements") == 0 && hasValue) measurements = (size_t)parseNumber(argv[++i], minMeasurements, maxMeasurements, "--measurements out of range");
		else if (strcmp(argv[i], "--batches") == 0 && hasValue) batches = parseNumber(argv[++i], 2, maxBatches, "--batches out of range");
		else if (strcmp(argv[i], "--seed") == 0 && hasValue) { seed = parseNumber(argv[++i], 0, UINT64_MAX, "--seed is not a 64-bit number"); seedGiven = 1; }
		else if (strcmp(argv[i], "--fixed-hex") == 0 && hasValue) fixedHex = argv[++i];
		else if (strcmp(argv[i], "--leak-spin") == 0 && hasValue) leakSpin = parseNumber(argv[++i], 0, maxLeakSpin, "--leak-spin out of range");
		else if (strcmp(argv[i], "--no-kat") == 0) checkKnownAnswer = 0;
		else if (strcmp(argv[i], "--null") == 0) nullExperiment = 1;
		else usage("unknown or incomplete argument");
	}
	if ((uint64_t)measurements * batches > maxTotalMeasurements) usage("measurements * batches is over the cap");
	if (nullExperiment && leakSpin != 0) usage("--null and --leak-spin contradict each other");
	if (!seedGiven) seed = seedFromUrandom();
	rngState = seed;
	fromHex(fixedScalar, fixedHex);
	fromHex(publicPoint, publicPointHex);

	MS_ENTRY_DATINIT();
	MS_ENTRY_INIT();
	printf("STAGE init ok\n");
	printf("CONFIG measurementsPerBatch=%zu batches=%llu seed=0x%016llx kat=%d null=%d leakSpin=%llu\n", measurements,
		(unsigned long long)batches, (unsigned long long)seed, checkKnownAnswer, nullExperiment, (unsigned long long)leakSpin);
	printf("CONFIG fixedScalar=%s\nCONFIG publicPoint=%s\n", fixedHex, publicPointHex);
	printTimer();
#ifdef __OPTIMIZE__
	printf("CONFIG compiler=%s optimize=%d\n", __VERSION__, __OPTIMIZE__);
#else
	printf("CONFIG compiler=%s optimize=0\n", __VERSION__);
#endif
	printf("CONFIG dudect enoughMeasurements=%d percentiles=%d thresholds moderate=10 bananas=500 (upstream)\n", DUDECT_ENOUGH_MEASUREMENTS, DUDECT_NUMBER_PERCENTILES);
	fflush(stdout);

	if (checkKnownAnswer) {
		if (!knownAnswer()) return exitKnownAnswer;
		printf("STAGE kat ok\n");
	}

	dudect_config_t config = {.chunk_size = scalarBytes, .number_measurements = measurements};
	dudect_ctx_t ctx;
	dudect_init(&ctx, &config);
	dudect_state_t state = DUDECT_NO_LEAKAGE_EVIDENCE_YET;
	uint64_t run = 0;
	while (run < batches && state == DUDECT_NO_LEAKAGE_EVIDENCE_YET) {
		state = dudect_main(&ctx);
		run++;
		fflush(stdout);
	}
	double class0 = ctx.ttest_ctxs[0]->n[0], class1 = ctx.ttest_ctxs[0]->n[1];
	dudect_free(&ctx);

	const char *verdict = state == DUDECT_LEAKAGE_FOUND ? "leakage" : class0 > DUDECT_ENOUGH_MEASUREMENTS ? "noEvidence" : "inconclusive";
	printf("RESULT %s batchesRun=%llu uncroppedClass0=%.0f uncroppedClass1=%.0f seed=0x%016llx\n", verdict, (unsigned long long)run, class0,
		class1, (unsigned long long)seed);
	printf("STAGE done\n");
	if (state == DUDECT_LEAKAGE_FOUND) return exitLeakageFound;
	return class0 > DUDECT_ENOUGH_MEASUREMENTS ? exitNoLeakageEvidence : exitInconclusive;
}

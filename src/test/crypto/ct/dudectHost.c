#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "dudectHost.h"

#if !defined(__x86_64__) && !defined(__aarch64__)
#error "no dudect timer for this architecture: the pinned header has rdtsc (x86-64) and armShim has cntvct_el0 (AArch64)"
#endif

#define DUDECT_IMPLEMENTATION
#include "dudect.h"

extern uint8_t msCtDudectCompute(uint8_t *data);

static uint8_t *fixedInput;
static size_t fixedLength;
static int nullExperiment;
static uint64_t rngState;

static uint64_t nextRandom(void) {
	uint64_t z = (rngState += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

void prepare_inputs(dudect_config_t *c, uint8_t *input_data, uint8_t *classes) {
	for (size_t i = 0; i < c->number_measurements; i++) {
		uint8_t *chunk = input_data + i * c->chunk_size;
		classes[i] = (uint8_t)(nextRandom() >> 63);
		if (classes[i] == 0 && !nullExperiment) {
			memcpy(chunk, fixedInput, fixedLength);
			continue;
		}
		for (size_t j = 0; j < c->chunk_size; j += 8) {
			uint64_t r = nextRandom();
			for (size_t k = 0; k < 8 && j + k < c->chunk_size; k++) chunk[j + k] = (uint8_t)(r >> (8 * k));
		}
	}
}

uint8_t do_one_computation(uint8_t *data) {
	return msCtDudectCompute(data);
}

static void printTimer(void) {
#if defined(__x86_64__)
	printf("CONFIG timer=x86-64 _mm_mfence+__rdtsc (upstream dudect.h cpucycles, TSC ticks)\n");
#else
	uint64_t freq;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	printf("CONFIG timer=aarch64 dsb sy+isb+cntvct_el0 via armShim (generic timer ticks, cntfrq_el0=%llu Hz, not CPU cycles)\n",
		(unsigned long long)freq);
#endif
#ifdef __OPTIMIZE__
	printf("CONFIG compiler=%s optimize=%d\n", __VERSION__, __OPTIMIZE__);
#else
	printf("CONFIG compiler=%s optimize=0\n", __VERSION__);
#endif
	printf("CONFIG dudect enoughMeasurements=%d percentiles=%d thresholds moderate=10 bananas=500 (upstream)\n",
		DUDECT_ENOUGH_MEASUREMENTS, DUDECT_NUMBER_PERCENTILES);
}

/* Runs upstream dudect_main until it reports leakage or `batches` calls pass; the first call only sets the percentiles.
 * Returns 0 no leakage evidence, 20 leakage, 21 inconclusive (class 0 never reached DUDECT_ENOUGH_MEASUREMENTS). */
int32_t msCtDudectRun(uint8_t *fixed, int64_t length, int64_t measurements, int64_t batches, uint64_t seed, int32_t null) {
	fixedInput = fixed;
	fixedLength = (size_t)length;
	nullExperiment = null;
	rngState = seed;
	printTimer();
	fflush(stdout);
	dudect_config_t config = {.chunk_size = (size_t)length, .number_measurements = (size_t)measurements};
	dudect_ctx_t ctx;
	dudect_init(&ctx, &config);
	dudect_state_t state = DUDECT_NO_LEAKAGE_EVIDENCE_YET;
	int64_t run = 0;
	while (run < batches && state == DUDECT_NO_LEAKAGE_EVIDENCE_YET) {
		state = dudect_main(&ctx);
		run++;
		fflush(stdout);
	}
	double class0 = ctx.ttest_ctxs[0]->n[0], class1 = ctx.ttest_ctxs[0]->n[1];
	dudect_free(&ctx);
	const char *verdict = state == DUDECT_LEAKAGE_FOUND ? "leakage" : class0 > DUDECT_ENOUGH_MEASUREMENTS ? "noEvidence" : "inconclusive";
	printf("RESULT %s batchesRun=%lld uncroppedClass0=%.0f uncroppedClass1=%.0f seed=0x%016llx\n", verdict, (long long)run,
		class0, class1, (unsigned long long)seed);
	fflush(stdout);
	if (state == DUDECT_LEAKAGE_FOUND) return 20;
	return class0 > DUDECT_ENOUGH_MEASUREMENTS ? 0 : 21;
}

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include "drc.h"

static int rcRaceReady;

static void* rcRaceBump(void* cell) {
	__atomic_fetch_add(&rcRaceReady, 1, __ATOMIC_RELAXED);
	while (__atomic_load_n(&rcRaceReady, __ATOMIC_RELAXED) < 2) {}
	for (int i = 0; i < 100000; i++) msIncRef(cell);
	return NULL;
}

int32_t rcRaceProbe(void) {
	msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + 16);
	void* cell = h + 1;
	pthread_t a, b;
	pthread_create(&a, NULL, rcRaceBump, cell);
	pthread_create(&b, NULL, rcRaceBump, cell);
	pthread_join(a, NULL);
	pthread_join(b, NULL);
	free(h);
	return 0;
}

#ifdef RC_RACE_PROBE_MAIN
int main(void) {
	return rcRaceProbe();
}
#endif

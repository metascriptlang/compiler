#include <pthread.h>
#include <stdlib.h>
#include "runtime/drc.h"

static void* bump(void* cell) {
	for (int i = 0; i < 100000; i++) msIncRef(cell);
	return NULL;
}

int main(void) {
	msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + 16);
	void* cell = h + 1;
	pthread_t a, b;
	pthread_create(&a, NULL, bump, cell);
	pthread_create(&b, NULL, bump, cell);
	pthread_join(a, NULL);
	pthread_join(b, NULL);
	return 0;
}

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include "runtime/drc.h"
#include "stale.h"

static msTypeInfo cyclic;
static void* shared;

static void onAbort(int sig) {
	(void)sig;
	fputs("aborted\n", stdout);
	fflush(stdout);
	_Exit(7);
}

static void* worker(void* unused) {
	(void)unused;
	msOrcIncRef(shared);
	msOrcDecRefIsLast(shared);
	msRootsThreadTeardown();
	return NULL;
}

int32_t msTestFreeRootOfExitedWorker(int32_t ownRoots) {
	cyclic.isCyclic = true;
	for (int32_t i = 0; i < ownRoots; i++) {
		void* own = msAllocTyped(32, &cyclic);
		msOrcIncRef(own);
		msOrcDecRefIsLast(own);
	}
	shared = msAllocTyped(32, &cyclic);
	pthread_t t;
	pthread_create(&t, NULL, worker, NULL);
	pthread_join(t, NULL);
	signal(SIGABRT, onAbort);
	fclose(stderr);
	msDestroyAndDispose(shared);
	signal(SIGABRT, SIG_DFL);
	return msRoots.len;
}

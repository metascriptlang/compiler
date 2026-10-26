#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "runtime/drc.h"
#include "stale.h"

static msTypeInfo cyclic;
static void* shared;
static int realStderr;
static int captured;

static void onAbort(int sig) {
	(void)sig;
	char msg[512] = {0};
	lseek(2, 0, SEEK_SET);
	ssize_t n = read(2, msg, sizeof(msg) - 1);
	dup2(realStderr, 2);
	fputs(n > 0 && strstr(msg, "M1 owner violation at free") ? "aborted M1\n" : "aborted other\n", stdout);
	fflush(stdout);
	exit(7);
}

static void* worker(void* unused) {
	(void)unused;
	msOrcIncRef(shared);
	msOrcDecRefIsLast(shared);
	msRootsThreadTeardown();
	return NULL;
}

static int32_t freeRootOfExitedWorker(int32_t ownRoots, bool collectFirst) {
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
	if (collectFirst) msOrcCollect();
	signal(SIGABRT, onAbort);
	realStderr = dup(2);
	captured = fileno(tmpfile());
	dup2(captured, 2);
	msDestroyAndDispose(shared);
	signal(SIGABRT, SIG_DFL);
	return msRoots.len;
}

int32_t msTestFreeRootOfExitedWorker(int32_t ownRoots) {
	return freeRootOfExitedWorker(ownRoots, false);
}

int32_t msTestCollectThenFreeRootOfExitedWorker(int32_t ownRoots) {
	return freeRootOfExitedWorker(ownRoots, true);
}

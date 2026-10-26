#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "runtime/promise/future.h"
#include "runtime/promise/dispatch.h"
#include "foreign.h"

static int realStderr;

static void onAbort(int sig) {
	(void)sig;
	char msg[512] = {0};
	lseek(2, 0, SEEK_SET);
	ssize_t n = read(2, msg, sizeof(msg) - 1);
	dup2(realStderr, 2);
	fputs(n > 0 && strstr(msg, "neither the main loop thread nor a pool worker") ? "aborted foreign await\n" : "aborted other\n", stdout);
	fflush(stdout);
	exit(7);
}

static void* awaitNeverSettled(void* unused) {
	(void)unused;
	msWaitFor(msFutureCreate());
	return NULL;
}

int32_t msTestAwaitOnForeignThread(void) {
	signal(SIGABRT, onAbort);
	realStderr = dup(2);
	dup2(fileno(tmpfile()), 2);
	pthread_t t;
	pthread_create(&t, NULL, awaitNeverSettled, NULL);
	pthread_join(t, NULL);
	dup2(realStderr, 2);
	return 0;
}

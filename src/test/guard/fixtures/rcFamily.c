#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "runtime/drc.h"
#include "rcFamily.h"

typedef void (*childOp)(void* cell);

static void plainDecref(void* cell) { msDecRefIsLast(cell); }
static void atomicDecref(void* cell) { msAtomicDecRefIsLast(cell); }
static void arcAllocPlainTyped(void* unused) {
	static msTypeInfo plain = { .name = "PlainTyped" };
	(void)unused;
	msAllocArc(32, &plain);
}

static int32_t childAbortsWithMismatch(childOp op, void* cell) {
	int out[2];
	if (pipe(out) != 0) return -1;
	pid_t pid = fork();
	if (pid < 0) return -1;
	if (pid == 0) {
		dup2(out[1], 2);
		close(out[0]);
		op(cell);
		_exit(0);
	}
	close(out[1]);
	char msg[512] = {0};
	ssize_t n = read(out[0], msg, sizeof(msg) - 1);
	close(out[0]);
	int status = 0;
	waitpid(pid, &status, 0);
	bool aborted = WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
	return aborted && n > 0 && strstr(msg, "RC-FAMILY MISMATCH") != NULL ? 1 : 0;
}

int32_t msTestPlainDecrefAborts(void* cell) { return childAbortsWithMismatch(plainDecref, cell); }
int32_t msTestAtomicDecrefAborts(void* cell) { return childAbortsWithMismatch(atomicDecref, cell); }
int32_t msTestPlainTypedArcAllocAborts(void) { return childAbortsWithMismatch(arcAllocPlainTyped, NULL); }

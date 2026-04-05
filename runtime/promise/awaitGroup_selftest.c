/*
 * Standalone self-test for AwaitGroup (PARALOCK Phase 2 Stage 1).
 *
 * Not part of the normal runtime build. Compile directly:
 *
 *     cc -std=c11 -Wall -Wextra -O2 -pthread \
 *        -I runtime \
 *        runtime/promise/awaitGroup.c \
 *        runtime/promise/awaitGroup_selftest.c \
 *        -o awaitGroup_selftest
 *     ./awaitGroup_selftest
 *
 * Exercises:
 *   T1 zero-sized group (pending == 0 from the start)
 *   T2 single slot, success
 *   T3 single slot, failure
 *   T4 multiple slots, all success, out-of-order completion
 *   T5 multiple slots, one failure among successes (first-failure-wins)
 *   T6 concurrent completion from worker threads, race between workers and waiter
 *   T7 large group under contention (stress)
 */
#include "promise/awaitGroup.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;
static int total = 0;

#define CHECK(cond, msg) do { \
		total++; \
		if (!(cond)) { \
			failures++; \
			fprintf(stderr, "  FAIL: %s (line %d)\n", (msg), __LINE__); \
		} \
	} while (0)

/* ===== T1 ===== */
static void t1_zero_size(void) {
	printf("T1 zero-sized group\n");
	msAwaitGroup* g = msAwaitGroupInit(0);
	CHECK(g != NULL, "create(0) returns non-null");
	CHECK(msAwaitGroupFinished(g), "zero-size group is finished immediately");
	CHECK(!msAwaitGroupFailed(g), "zero-size group is not failed");
	msAwaitGroupBlocking(g);
	CHECK(msAwaitGroupFinished(g), "wait on zero-size returns immediately");
	msAwaitGroupFree(g);
}

/* ===== T2 ===== */
static void t2_single_success(void) {
	printf("T2 single-slot success\n");
	msAwaitGroup* g = msAwaitGroupInit(1);
	CHECK(!msAwaitGroupFinished(g), "pre-completion: not finished");
	int payload = 42;
	msAwaitGroupCompleteSlot(g, 0, &payload);
	CHECK(msAwaitGroupFinished(g), "post-completion: finished");
	CHECK(!msAwaitGroupFailed(g), "post-completion: not failed");
	msAwaitGroupBlocking(g);
	void* result = msAwaitGroupResult(g, 0);
	CHECK(result == &payload, "result matches submitted value");
	CHECK(*(int*)result == 42, "result payload intact");
	msAwaitGroupFree(g);
}

/* ===== T3 ===== */
static void t3_single_failure(void) {
	printf("T3 single-slot failure\n");
	msAwaitGroup* g = msAwaitGroupInit(1);
	int err = -1;
	msAwaitGroupFailSlot(g, 0, &err);
	msAwaitGroupBlocking(g);
	CHECK(msAwaitGroupFailed(g), "group is failed");
	CHECK(msAwaitGroupError(g) == &err, "error payload preserved");
	CHECK(msAwaitGroupResult(g, 0) == NULL, "failed slot result is NULL");
	msAwaitGroupFree(g);
}

/* ===== T4 ===== */
static void t4_multi_success_out_of_order(void) {
	printf("T4 multi-slot success, out-of-order completion\n");
	const int N = 5;
	int payloads[5] = { 10, 20, 30, 40, 50 };
	msAwaitGroup* g = msAwaitGroupInit(N);

	/* Complete in reverse order to prove slot indexing is correct */
	msAwaitGroupCompleteSlot(g, 4, &payloads[4]);
	msAwaitGroupCompleteSlot(g, 2, &payloads[2]);
	msAwaitGroupCompleteSlot(g, 0, &payloads[0]);
	msAwaitGroupCompleteSlot(g, 3, &payloads[3]);
	CHECK(!msAwaitGroupFinished(g), "not finished with 4 of 5 complete");
	msAwaitGroupCompleteSlot(g, 1, &payloads[1]);
	CHECK(msAwaitGroupFinished(g), "finished after last slot");

	msAwaitGroupBlocking(g);
	for (int i = 0; i < N; i++) {
		void* r = msAwaitGroupResult(g, i);
		CHECK(r == &payloads[i], "result in correct slot");
		CHECK(*(int*)r == payloads[i], "result value intact");
	}
	msAwaitGroupFree(g);
}

/* ===== T5 ===== */
static void t5_mixed_failure(void) {
	printf("T5 mixed success + failure, first-failure-wins\n");
	msAwaitGroup* g = msAwaitGroupInit(4);
	int v0 = 1, v2 = 3;
	int e1 = 101, e3 = 103;

	msAwaitGroupCompleteSlot(g, 0, &v0);
	msAwaitGroupFailSlot(g, 1, &e1);        /* first failure */
	msAwaitGroupCompleteSlot(g, 2, &v2);
	msAwaitGroupFailSlot(g, 3, &e3);        /* second failure, should be dropped */

	msAwaitGroupBlocking(g);
	CHECK(msAwaitGroupFailed(g), "group is failed");
	CHECK(msAwaitGroupError(g) == &e1, "first error wins");
	CHECK(msAwaitGroupResult(g, 0) == &v0, "successful slot 0 preserved");
	CHECK(msAwaitGroupResult(g, 1) == NULL, "failed slot 1 is NULL");
	CHECK(msAwaitGroupResult(g, 2) == &v2, "successful slot 2 preserved");
	CHECK(msAwaitGroupResult(g, 3) == NULL, "failed slot 3 is NULL");
	msAwaitGroupFree(g);
}

/* ===== T6 ===== */
typedef struct {
	msAwaitGroup* g;
	int slot;
	int value;
	int delay_us;
} WorkerArg;

static void* worker_complete(void* arg) {
	WorkerArg* w = (WorkerArg*)arg;
	if (w->delay_us > 0) usleep(w->delay_us);
	int* payload = (int*)malloc(sizeof(int));
	*payload = w->value;
	msAwaitGroupCompleteSlot(w->g, w->slot, payload);
	return NULL;
}

static void t6_concurrent_workers(void) {
	printf("T6 concurrent workers racing against waiter\n");
	const int N = 8;
	msAwaitGroup* g = msAwaitGroupInit(N);
	pthread_t threads[8];
	WorkerArg args[8];

	for (int i = 0; i < N; i++) {
		args[i].g = g;
		args[i].slot = i;
		args[i].value = i * 100;
		/* Staggered delays so some workers complete after wait starts */
		args[i].delay_us = (i % 3) * 1000;
		pthread_create(&threads[i], NULL, worker_complete, &args[i]);
	}

	/* Main thread waits — workers are completing concurrently */
	msAwaitGroupBlocking(g);

	CHECK(msAwaitGroupFinished(g), "finished after wait");
	CHECK(!msAwaitGroupFailed(g), "no failures");
	for (int i = 0; i < N; i++) {
		pthread_join(threads[i], NULL);
		int* r = (int*)msAwaitGroupResult(g, i);
		CHECK(r != NULL, "result present");
		CHECK(*r == i * 100, "result value correct");
		free(r);
	}
	msAwaitGroupFree(g);
}

/* ===== T7 ===== */
typedef struct {
	msAwaitGroup* g;
	WorkerArg* args;
	int from;
	int to;
} BatchCtx;

static void* batch_worker(void* arg) {
	BatchCtx* ctx = (BatchCtx*)arg;
	for (int i = ctx->from; i < ctx->to; i++) {
		int* payload = (int*)malloc(sizeof(int));
		*payload = ctx->args[i].value;
		msAwaitGroupCompleteSlot(ctx->g, ctx->args[i].slot, payload);
	}
	return NULL;
}

static void t7_stress(void) {
	printf("T7 stress: 256 slots, 16 workers\n");
	const int N = 256;
	const int W = 16;
	msAwaitGroup* g = msAwaitGroupInit(N);
	pthread_t threads[16];
	WorkerArg args[256];

	for (int i = 0; i < N; i++) {
		args[i].g = g;
		args[i].slot = i;
		args[i].value = i + 1;
		args[i].delay_us = 0;
	}

	/* Dispatch N tasks across W worker threads by having each worker thread
	 * submit N/W slots sequentially. This stresses concurrent completion
	 * with no inter-worker coordination. */
	BatchCtx ctxs[16];
	for (int w = 0; w < W; w++) {
		ctxs[w].g = g;
		ctxs[w].args = args;
		ctxs[w].from = w * (N / W);
		ctxs[w].to = (w + 1) * (N / W);
		pthread_create(&threads[w], NULL, batch_worker, &ctxs[w]);
	}

	msAwaitGroupBlocking(g);

	for (int w = 0; w < W; w++) pthread_join(threads[w], NULL);

	CHECK(msAwaitGroupFinished(g), "stress: finished");
	CHECK(!msAwaitGroupFailed(g), "stress: no failures");
	int seen[256] = { 0 };
	for (int i = 0; i < N; i++) {
		int* r = (int*)msAwaitGroupResult(g, i);
		CHECK(r != NULL, "stress: result present");
		if (r != NULL) {
			CHECK(*r == i + 1, "stress: result correct");
			seen[i] = 1;
			free(r);
		}
	}
	int missing = 0;
	for (int i = 0; i < N; i++) if (!seen[i]) missing++;
	CHECK(missing == 0, "stress: all slots accounted for");
	msAwaitGroupFree(g);
}

/* ===== main ===== */
int main(void) {
	printf("AwaitGroup self-test\n");
	printf("====================\n");
	t1_zero_size();
	t2_single_success();
	t3_single_failure();
	t4_multi_success_out_of_order();
	t5_mixed_failure();
	t6_concurrent_workers();
	t7_stress();
	printf("\n");
	printf("Results: %d/%d checks passed, %d failures\n",
		total - failures, total, failures);
	return failures == 0 ? 0 : 1;
}

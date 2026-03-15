/*
 * MetaScript Promise Combinators — Promise.all / Promise.race
 */
#include "std/core/system/native.h"
#include "std/core/promise/combinator.h"
#include <stdlib.h>

/* ===== Promise.all ===== */

static void msPromiseAllCb(void* env) {
	msPromiseAllCbEnv* e = (msPromiseAllCbEnv*)env;
	msPromiseAllState* s = e->state;
	int idx = e->index;
	free(e);

	/* Record result or failure */
	if (!s->failed) {
		msFuture* f = s->inputs[idx];
		if (f->failed || f->cancelled) {
			s->failed = true;
			msFutureFail(s->result, f->error);
		} else {
			s->values[idx] = f->value;
		}
	}

	/* Always decrement. Last callback frees state. */
	s->remaining--;
	if (s->remaining == 0) {
		if (!s->failed) {
			s->result->valueDestructor = free; /* values array freed when future destroyed */
			msFutureComplete(s->result, s->values);
		} else {
			free(s->values);
		}
		free(s->inputs);
		free(s);
	}
}

msFuture* msPromiseAll(msRefArray arr) {
	int count = (int)arr.len;
	msFuture** futures = (arr.p != NULL) ? (msFuture**)arr.p->data : NULL;
	msFuture* result = msFutureCreate();

	if (count == 0 || futures == NULL) {
		msFutureComplete(result, NULL);
		return result;
	}

	/* Copy futures array — caller may free original */
	msFuture** inputsCopy = (msFuture**)malloc(count * sizeof(msFuture*));
	for (int i = 0; i < count; i++) inputsCopy[i] = futures[i];

	msPromiseAllState* state = (msPromiseAllState*)calloc(1, sizeof(msPromiseAllState));
	state->result = result;
	state->inputs = inputsCopy;
	state->values = (void**)calloc(count, sizeof(void*));
	state->count = count;
	state->remaining = count;

	for (int i = 0; i < count; i++) {
		msPromiseAllCbEnv* env = (msPromiseAllCbEnv*)malloc(sizeof(msPromiseAllCbEnv));
		env->state = state;
		env->index = i;
		msFutureAddCallback(futures[i], (msClosure){
			.fn = (msClosureFn)msPromiseAllCb,
			.env = env
		});
	}
	return result;
}

/* ===== Promise.race ===== */

static void msPromiseRaceCb(void* env) {
	msPromiseRaceCbEnv* e = (msPromiseRaceCbEnv*)env;
	msPromiseRaceState* s = e->state;
	msFuture* f = e->input;
	free(e);

	/* First settlement wins */
	if (!s->settled) {
		s->settled = true;
		if (f->failed || f->cancelled) {
			msFutureFail(s->result, f->error);
		} else {
			msFutureComplete(s->result, f->value);
		}
	}

	/* Last callback frees state */
	s->remaining--;
	if (s->remaining == 0) free(s);
}

msFuture* msPromiseRace(msRefArray arr) {
	int count = (int)arr.len;
	msFuture** futures = (arr.p != NULL) ? (msFuture**)arr.p->data : NULL;
	msFuture* result = msFutureCreate();

	if (count == 0 || futures == NULL) return result;  /* never settles — ECMAScript spec */

	msPromiseRaceState* state = (msPromiseRaceState*)calloc(1, sizeof(msPromiseRaceState));
	state->result = result;
	state->remaining = count;

	for (int i = 0; i < count; i++) {
		msPromiseRaceCbEnv* env = (msPromiseRaceCbEnv*)malloc(sizeof(msPromiseRaceCbEnv));
		env->state = state;
		env->input = futures[i];
		msFutureAddCallback(futures[i], (msClosure){
			.fn = (msClosureFn)msPromiseRaceCb,
			.env = env
		});
	}
	return result;
}

/* ===== Promise.allSettled ===== */

static void msPromiseAllSettledCb(void* env) {
	msPromiseAllSettledCbEnv* e = (msPromiseAllSettledCbEnv*)env;
	msPromiseAllSettledState* s = e->state;
	free(e);

	/* Always decrement. Last callback completes (never fails). */
	s->remaining--;
	if (s->remaining == 0) {
		msFutureComplete(s->result, NULL);
		free(s->inputs);
		free(s);
	}
}

msFuture* msPromiseAllSettled(msRefArray arr) {
	int count = (int)arr.len;
	msFuture** futures = (arr.p != NULL) ? (msFuture**)arr.p->data : NULL;
	msFuture* result = msFutureCreate();

	if (count == 0 || futures == NULL) {
		msFutureComplete(result, NULL);
		return result;
	}

	/* Copy futures array — caller may free original */
	msFuture** inputsCopy = (msFuture**)malloc(count * sizeof(msFuture*));
	for (int i = 0; i < count; i++) inputsCopy[i] = futures[i];

	msPromiseAllSettledState* state = (msPromiseAllSettledState*)calloc(1, sizeof(msPromiseAllSettledState));
	state->result = result;
	state->inputs = inputsCopy;
	state->count = count;
	state->remaining = count;

	for (int i = 0; i < count; i++) {
		msPromiseAllSettledCbEnv* env = (msPromiseAllSettledCbEnv*)malloc(sizeof(msPromiseAllSettledCbEnv));
		env->state = state;
		env->index = i;
		msFutureAddCallback(futures[i], (msClosure){
			.fn = (msClosureFn)msPromiseAllSettledCb,
			.env = env
		});
	}
	return result;
}

/* ===== Promise.any ===== */

static void msPromiseAnyCb(void* env) {
	msPromiseAnyCbEnv* e = (msPromiseAnyCbEnv*)env;
	msPromiseAnyState* s = e->state;
	msFuture* f = e->input;
	free(e);

	/* First fulfillment wins */
	if (!s->resolved) {
		if (!(f->failed || f->cancelled)) {
			s->resolved = true;
			msFutureComplete(s->result, f->value);
		} else {
			s->rejected++;
			if (s->rejected == s->count) {
				msFutureFail(s->result, (void*)"All promises were rejected");
			}
		}
	}

	/* Last callback frees state */
	s->remaining--;
	if (s->remaining == 0) free(s);
}

msFuture* msPromiseAny(msRefArray arr) {
	int count = (int)arr.len;
	msFuture** futures = (arr.p != NULL) ? (msFuture**)arr.p->data : NULL;
	msFuture* result = msFutureCreate();

	if (count == 0 || futures == NULL) {
		msFutureFail(result, (void*)"All promises were rejected");
		return result;
	}

	msPromiseAnyState* state = (msPromiseAnyState*)calloc(1, sizeof(msPromiseAnyState));
	state->result = result;
	state->count = count;
	state->remaining = count;

	for (int i = 0; i < count; i++) {
		msPromiseAnyCbEnv* env = (msPromiseAnyCbEnv*)malloc(sizeof(msPromiseAnyCbEnv));
		env->state = state;
		env->input = futures[i];
		msFutureAddCallback(futures[i], (msClosure){
			.fn = (msClosureFn)msPromiseAnyCb,
			.env = env
		});
	}
	return result;
}

/* ===== new Promise(executor) ===== */

static void msPromiseResolveFn(void* env, void* value) {
	msPromiseNewEnv* e = (msPromiseNewEnv*)env;
	if (!e->settled) {
		e->settled = true;
		msFutureComplete(e->future, value);
		free(e);
	}
}

static void msPromiseRejectFn(void* env, void* error) {
	msPromiseNewEnv* e = (msPromiseNewEnv*)env;
	if (!e->settled) {
		e->settled = true;
		msFutureFail(e->future, error);
		free(e);
	}
}

msFuture* msPromiseNew(msClosure executor) {
	msFuture* f = msFutureCreate();
	msPromiseNewEnv* env = (msPromiseNewEnv*)calloc(1, sizeof(msPromiseNewEnv));
	env->future = f;
	msClosure resolve = { .fn = (msClosureFn)msPromiseResolveFn, .env = env };
	msClosure reject = { .fn = (msClosureFn)msPromiseRejectFn, .env = env };
	/* Call executor(resolve, reject) synchronously */
	if (executor.env != NULL) {
		((void(*)(void*, msClosure, msClosure))executor.fn)(executor.env, resolve, reject);
	} else {
		((void(*)(msClosure, msClosure))executor.fn)(resolve, reject);
	}
	/* env freed by whichever of resolve/reject fires first (settled flag prevents double-free) */
	return f;
}

/* ===== Promise.then ===== */

static void msFutureThenCb(void* raw) {
	msFutureThenEnv* e = (msFutureThenEnv*)raw;
	if (e->input->failed || e->input->cancelled) {
		msFutureFail(e->output, e->input->error);
	} else {
		void* val = e->input->value;
		if (e->onFulfilled.env != NULL) {
			((void(*)(void*, void*))e->onFulfilled.fn)(e->onFulfilled.env, val);
		} else {
			((void(*)(void*))e->onFulfilled.fn)(val);
		}
		if (msErr) {
			msFutureFail(e->output, (void*)msCurrException);
			msErr = false; msCurrException = NULL;
		} else {
			msFutureComplete(e->output, NULL);
		}
	}
	free(e);
}

msFuture* msFutureThen(msFuture* input, msClosure onFulfilled) {
	msFuture* output = msFutureCreate();
	msFutureThenEnv* env = (msFutureThenEnv*)malloc(sizeof(msFutureThenEnv));
	env->output = output; env->input = input; env->onFulfilled = onFulfilled;
	msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)msFutureThenCb, .env = env});
	return output;
}

/* ===== Promise.catch ===== */

static void msFutureCatchCb(void* raw) {
	msFutureCatchEnv* e = (msFutureCatchEnv*)raw;
	if (e->input->failed || e->input->cancelled) {
		void* err = e->input->error;
		if (e->onRejected.env != NULL) {
			((void(*)(void*, void*))e->onRejected.fn)(e->onRejected.env, err);
		} else {
			((void(*)(void*))e->onRejected.fn)(err);
		}
		if (msErr) {
			msFutureFail(e->output, (void*)msCurrException);
			msErr = false; msCurrException = NULL;
		} else {
			msFutureComplete(e->output, NULL);
		}
	} else {
		msFutureComplete(e->output, e->input->value);
	}
	free(e);
}

msFuture* msFutureCatch(msFuture* input, msClosure onRejected) {
	msFuture* output = msFutureCreate();
	msFutureCatchEnv* env = (msFutureCatchEnv*)malloc(sizeof(msFutureCatchEnv));
	env->output = output; env->input = input; env->onRejected = onRejected;
	msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)msFutureCatchCb, .env = env});
	return output;
}

/* ===== Promise.finally ===== */

static void msFutureFinallyCb(void* raw) {
	msFutureFinallyEnv* e = (msFutureFinallyEnv*)raw;
	if (e->onSettled.env != NULL) {
		((void(*)(void*))e->onSettled.fn)(e->onSettled.env);
	} else {
		((void(*)(void))e->onSettled.fn)();
	}
	if (e->input->failed || e->input->cancelled) {
		msFutureFail(e->output, e->input->error);
	} else {
		msFutureComplete(e->output, e->input->value);
	}
	free(e);
}

msFuture* msFutureFinally(msFuture* input, msClosure onSettled) {
	msFuture* output = msFutureCreate();
	msFutureFinallyEnv* env = (msFutureFinallyEnv*)malloc(sizeof(msFutureFinallyEnv));
	env->output = output; env->input = input; env->onSettled = onSettled;
	msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)msFutureFinallyCb, .env = env});
	return output;
}

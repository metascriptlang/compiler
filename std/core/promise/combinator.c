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
		if (f->base.failed || f->base.cancelled) {
			s->failed = true;
			msFutureFail(s->result, f->base.error);
		} else {
			s->values[idx] = f->value;
		}
	}

	/* Always decrement. Last callback frees state. */
	s->remaining--;
	if (s->remaining == 0) {
		if (!s->failed) {
			s->result->base.valueDestructor = free; /* values array freed when future destroyed */
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
	msFuture* result = (msFuture*)msFutureCreate();

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
		if (f->base.failed || f->base.cancelled) {
			msFutureFail(s->result, f->base.error);
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
	msFuture* result = (msFuture*)msFutureCreate();

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
	msFuture* result = (msFuture*)msFutureCreate();

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
		if (!(f->base.failed || f->base.cancelled)) {
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
	msFuture* result = (msFuture*)msFutureCreate();

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
	msFuture* f = (msFuture*)msFutureCreate();
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

/* Type-aware callback dispatch for .then.
 * MetaScript convention: lifted closures have params first, env last.
 * Type tag determines how to pass the value to match the callback's C signature. */
static void msFutureThenCb(void* raw) {
	msFutureThenEnv* e = (msFutureThenEnv*)raw;
	if (e->input->base.failed || e->input->base.cancelled) {
		msFutureFail(e->output, e->input->base.error);
		free(e);
		return;
	}
	void* val = e->input->value;
	e->input->value = NULL;  /* consumed — prevent double-free by valueDestructor */
	void* fn = (void*)e->onFulfilled.fn;
	void* env = e->onFulfilled.env;

	switch (e->typeTag) {
	case MS_TYPETAG_INT: {
		/* val is msBoxInt32 result (int32_t* on heap) — dereference + free */
		int32_t ival = val ? *(int32_t*)val : 0;
		if (val) free(val);
		if (env) ((void(*)(int32_t, void*))fn)(ival, env);
		else ((void(*)(int32_t))fn)(ival);
		break;
	}
	case MS_TYPETAG_DOUBLE: {
		double dval = val ? *(double*)val : 0.0;
		if (val) free(val);
		if (env) ((void(*)(double, void*))fn)(dval, env);
		else ((void(*)(double))fn)(dval);
		break;
	}
	case MS_TYPETAG_STRING: {
		msString sval = val ? *(msString*)val : MS_EMPTY_STRING;
		if (val) free(val);
		if (env) ((void(*)(msString, void*))fn)(sval, env);
		else ((void(*)(msString))fn)(sval);
		break;
	}
	default: /* PTR or VOID — pass void* directly */
		if (env) ((void(*)(void*, void*))fn)(val, env);
		else ((void(*)(void*))fn)(val);
		break;
	}

	if (msErr) {
		msFutureFail(e->output, (void*)msCurrException);
		msErr = false; msCurrException = NULL;
	} else {
		msFutureComplete(e->output, NULL);
	}
	free(e);
}

msFuture* msFutureThen(msFuture* input, msClosure onFulfilled) {
	return msFutureThenTyped(input, onFulfilled, MS_TYPETAG_PTR);
}

msFuture* msFutureThenTyped(msFuture* input, msClosure onFulfilled, int typeTag) {
	msFuture* output = (msFuture*)msFutureCreate();
	msFutureThenEnv* env = (msFutureThenEnv*)malloc(sizeof(msFutureThenEnv));
	env->output = output; env->input = input; env->onFulfilled = onFulfilled; env->typeTag = typeTag;
	msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)msFutureThenCb, .env = env});
	return output;
}

/* ===== Promise.catch ===== */

static void msFutureCatchCb(void* raw) {
	msFutureCatchEnv* e = (msFutureCatchEnv*)raw;
	if (e->input->base.failed || e->input->base.cancelled) {
		void* err = e->input->base.error;
		e->input->base.error = NULL;  /* consumed — prevent double-free */
		void* fn = (void*)e->onRejected.fn;
		void* env = e->onRejected.env;
		/* Error is always a string (msString*) in MetaScript */
		switch (e->typeTag) {
		case MS_TYPETAG_STRING: {
			msString sval = err ? *(msString*)err : MS_EMPTY_STRING;
			if (env) ((void(*)(msString, void*))fn)(sval, env);
			else ((void(*)(msString))fn)(sval);
			break;
		}
		default:
			if (env) ((void(*)(void*, void*))fn)(err, env);
			else ((void(*)(void*))fn)(err);
			break;
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
	return msFutureCatchTyped(input, onRejected, MS_TYPETAG_PTR);
}

msFuture* msFutureCatchTyped(msFuture* input, msClosure onRejected, int typeTag) {
	msFuture* output = (msFuture*)msFutureCreate();
	msFutureCatchEnv* env = (msFutureCatchEnv*)malloc(sizeof(msFutureCatchEnv));
	env->output = output; env->input = input; env->onRejected = onRejected; env->typeTag = typeTag;
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
	if (e->input->base.failed || e->input->base.cancelled) {
		msFutureFail(e->output, e->input->base.error);
	} else {
		msFutureComplete(e->output, e->input->value);
	}
	free(e);
}

msFuture* msFutureFinally(msFuture* input, msClosure onSettled) {
	msFuture* output = (msFuture*)msFutureCreate();
	msFutureFinallyEnv* env = (msFutureFinallyEnv*)malloc(sizeof(msFutureFinallyEnv));
	env->output = output; env->input = input; env->onSettled = onSettled;
	msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)msFutureFinallyCb, .env = env});
	return output;
}

#ifndef MSOS_BARE
/*
 * MetaScript Promise Combinators — Promise.all / Promise.race
 */
#include "runtime/core/system.h"
#include "runtime/promise/combinator.h"
#include <stdlib.h>

/* ===== Promise.all ===== */

static void msPromiseAllCb(void* env) {
	msPromiseAllCbEnv* e = (msPromiseAllCbEnv*)env;
	msPromiseAllState* s = e->state;
	int idx = e->index;
	free(e);

	/* Record result or failure */
	msFuture* f = s->inputs[idx];
	if (!s->failed) {
		if (f->base.failed || f->base.cancelled) {
			s->failed = true;
			msFutureFailShared(s->result, f->base.error);
		} else {
			s->values[idx] = f->value;
		}
	}
	msFutureEdgeSettle(s->result, idx);
	msDecref(f);

	/* Always decrement. Last callback frees state. */
	s->remaining--;
	if (s->remaining == 0) {
		if (!s->failed) {
			s->result->base.valueDestructor = free; /* values array freed when future destroyed */
			msFutureComplete(s->result, s->values);
		} else {
			free(s->values);
		}
		msDecref(s->result);
		free(s->inputs);
		free(s);
	}
}

void* msPromiseAll(msRefArray* arr) {
	int count = (arr != NULL) ? (int)arr->len : 0;
	msFuture** futures = (arr != NULL && arr->p != NULL) ? (msFuture**)arr->p->data : NULL;
	msFuture* result = (msFuture*)msFutureCreate();

	if (count == 0 || futures == NULL) {
		msFutureComplete(result, NULL);
		return result;
	}

	/* Copy futures array — caller may free original */
	msFuture** inputsCopy = (msFuture**)msMemAlloc(count * sizeof(msFuture*));
	for (int i = 0; i < count; i++) { inputsCopy[i] = futures[i]; msIncref(inputsCopy[i]); }

	msPromiseAllState* state = (msPromiseAllState*)msMemAlloc0(sizeof(msPromiseAllState));
	state->result = result;
	msIncref(result);
	state->inputs = inputsCopy;
	state->values = (void**)msMemAlloc0(count * sizeof(void*));
	state->count = count;
	state->remaining = count;
	msFutureEdgeAll(result, (void* const*)inputsCopy, count);

	for (int i = 0; i < count; i++) {
		msPromiseAllCbEnv* env = (msPromiseAllCbEnv*)msMemAlloc(sizeof(msPromiseAllCbEnv));
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
			msFutureFailShared(s->result, f->base.error);
		} else {
			msFutureComplete(s->result, f->value);
		}
	}

	msDecref(f);

	/* Last callback frees state */
	s->remaining--;
	if (s->remaining == 0) {
		msDecref(s->result);
		free(s);
	}
}

void* msPromiseRace(msRefArray* arr) {
	int count = (arr != NULL) ? (int)arr->len : 0;
	msFuture** futures = (arr != NULL && arr->p != NULL) ? (msFuture**)arr->p->data : NULL;
	msFuture* result = (msFuture*)msFutureCreate();

	if (count == 0 || futures == NULL) return result;  /* never settles — ECMAScript spec */

	msPromiseRaceState* state = (msPromiseRaceState*)msMemAlloc0(sizeof(msPromiseRaceState));
	state->result = result;
	msIncref(result);
	state->remaining = count;

	for (int i = 0; i < count; i++) {
		msPromiseRaceCbEnv* env = (msPromiseRaceCbEnv*)msMemAlloc(sizeof(msPromiseRaceCbEnv));
		env->state = state;
		env->input = futures[i];
		msIncref(futures[i]);
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
	int idx = e->index;
	free(e);
	msFutureEdgeSettle(s->result, idx);
	msDecref(s->inputs[idx]);

	/* Always decrement. Last callback completes (never fails). */
	s->remaining--;
	if (s->remaining == 0) {
		msFutureComplete(s->result, NULL);
		msDecref(s->result);
		free(s->inputs);
		free(s);
	}
}

void* msPromiseAllSettled(msRefArray* arr) {
	int count = (arr != NULL) ? (int)arr->len : 0;
	msFuture** futures = (arr != NULL && arr->p != NULL) ? (msFuture**)arr->p->data : NULL;
	msFuture* result = (msFuture*)msFutureCreate();

	if (count == 0 || futures == NULL) {
		msFutureComplete(result, NULL);
		return result;
	}

	/* Copy futures array — caller may free original */
	msFuture** inputsCopy = (msFuture**)msMemAlloc(count * sizeof(msFuture*));
	for (int i = 0; i < count; i++) { inputsCopy[i] = futures[i]; msIncref(inputsCopy[i]); }

	msPromiseAllSettledState* state = (msPromiseAllSettledState*)msMemAlloc0(sizeof(msPromiseAllSettledState));
	state->result = result;
	msIncref(result);
	state->inputs = inputsCopy;
	state->count = count;
	state->remaining = count;
	msFutureEdgeAll(result, (void* const*)inputsCopy, count);

	for (int i = 0; i < count; i++) {
		msPromiseAllSettledCbEnv* env = (msPromiseAllSettledCbEnv*)msMemAlloc(sizeof(msPromiseAllSettledCbEnv));
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
				msFutureFail(s->result, msMakeError(msStringFromCStr("All promises were rejected")));
			}
		}
	}

	msDecref(f);

	/* Last callback frees state */
	s->remaining--;
	if (s->remaining == 0) {
		msDecref(s->result);
		free(s);
	}
}

void* msPromiseAny(msRefArray* arr) {
	int count = (arr != NULL) ? (int)arr->len : 0;
	msFuture** futures = (arr != NULL && arr->p != NULL) ? (msFuture**)arr->p->data : NULL;
	msFuture* result = (msFuture*)msFutureCreate();

	if (count == 0 || futures == NULL) {
		msFutureFail(result, msMakeError(msStringFromCStr("All promises were rejected")));
		return result;
	}

	msPromiseAnyState* state = (msPromiseAnyState*)msMemAlloc0(sizeof(msPromiseAnyState));
	state->result = result;
	msIncref(result);
	state->count = count;
	state->remaining = count;

	for (int i = 0; i < count; i++) {
		msPromiseAnyCbEnv* env = (msPromiseAnyCbEnv*)msMemAlloc(sizeof(msPromiseAnyCbEnv));
		env->state = state;
		env->input = futures[i];
		msIncref(futures[i]);
		msFutureAddCallback(futures[i], (msClosure){
			.fn = (msClosureFn)msPromiseAnyCb,
			.env = env
		});
	}
	return result;
}

/* ===== Promise.then ===== */

/* Type-aware callback dispatch for .then.
 * MetaScript convention: lifted closures have params first, env last.
 * Type tag determines how to pass the value to match the callback's C signature. */
static void msFutureThenCb(void* raw) {
	msFutureThenEnv* e = (msFutureThenEnv*)raw;
	if (e->input->base.failed || e->input->base.cancelled) {
		msFutureThenRejected(e);
		msFutureThenEnvFree(e);
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
	case MS_TYPETAG_VOID:
		if (env) ((void(*)(void*))fn)(env);
		else ((void(*)(void))fn)();
		break;
	default: /* PTR — pass void* directly */
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
	msFutureThenEnvFree(e);
}

msFuture* msFutureThen(msFuture* input, msClosure onFulfilled) {
	return msFutureThenTyped(input, onFulfilled, MS_TYPETAG_PTR);
}

void* msFutureThenTyped(void* input, msClosure onFulfilled, int typeTag) {
	return msFutureThenTypedWithRejected(input, onFulfilled, typeTag, (msClosure){0});
}

void* msFutureThenTypedWithRejected(void* input, msClosure onFulfilled, int typeTag, msClosure onRejected) {
	return msFutureThenAttach(input, onFulfilled, onRejected, typeTag, (msClosureFn)msFutureThenCb);
}

/* ===== Promise.catch ===== */

static void msFutureCatchCb(void* raw) {
	msFutureCatchEnv* e = (msFutureCatchEnv*)raw;
	if (e->input->base.failed || e->input->base.cancelled) {
		void* err = e->input->base.error;  /* lent: the input keeps its count */
		void* fn = (void*)e->onRejected.fn;
		void* env = e->onRejected.env;
		if (env) ((void(*)(void*, void*))fn)(err, env);
		else ((void(*)(void*))fn)(err);
		if (msErr) {
			msFutureFail(e->output, (void*)msCurrException);
			msErr = false; msCurrException = NULL;
		} else {
			msFutureComplete(e->output, NULL);
		}
	} else {
		msFutureComplete(e->output, e->input->value);
	}
	msDecref(e->output); msDecref(e->input); msClosureDestroy(e->onRejected);
	free(e);
}

msFuture* msFutureCatch(msFuture* input, msClosure onRejected) {
	return msFutureCatchTyped(input, onRejected, MS_TYPETAG_PTR);
}

void* msFutureCatchTyped(void* input, msClosure onRejected, int typeTag) {
	msFuture* output = (msFuture*)msFutureCreate();
	msFutureCatchEnv* env = (msFutureCatchEnv*)msMemAlloc(sizeof(msFutureCatchEnv));
	env->output = output; env->input = (msFuture*)input; msIncref(input); msIncref(output); msClosureCopy(onRejected); env->onRejected = onRejected; env->typeTag = typeTag;
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
		msFutureFailShared(e->output, e->input->base.error);
	} else {
		msFutureComplete(e->output, e->input->value);
	}
	msDecref(e->output); msDecref(e->input); msClosureDestroy(e->onSettled);
	free(e);
}

void* msFutureFinally(void* input, msClosure onSettled) {
	msFuture* output = (msFuture*)msFutureCreate();
	msFutureFinallyEnv* env = (msFutureFinallyEnv*)msMemAlloc(sizeof(msFutureFinallyEnv));
	env->output = output; env->input = (msFuture*)input; msIncref(input); msIncref(output); msClosureCopy(onSettled); env->onSettled = onSettled;
	msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)msFutureFinallyCb, .env = env});
	return output;
}

#endif /* !MSOS_BARE */

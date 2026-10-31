#ifndef MSOS_BARE
/*
 * MetaScript Promise Combinators — Promise.allSettled / Promise.then / Promise.catch / Promise.finally
 */
#include "runtime/core/system.h"
#include "runtime/promise/combinator.h"
#include <stdlib.h>

/* ===== Promise.allSettled ===== */

static void msPromiseAllSettledCb(void* env) {
	msPromiseAllSettledCbEnv* e = (msPromiseAllSettledCbEnv*)env;
	msPromiseAllSettledState* s = e->state;
	int idx = e->index;
	free(e);
	msFutureEdgeSettle(s->result, idx);
	msDecrefAny(s->inputs[idx]);

	/* Always decrement. Last callback completes (never fails). */
	s->remaining--;
	if (s->remaining == 0) {
		msFutureComplete(s->result, NULL);
		msDecrefAny(s->result);
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

/* ===== Promise.then / .catch / .finally ===== */

static void msFutureThenRunTagged(void* raw) {
	msFutureThenEnv* e = (msFutureThenEnv*)raw;
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
}

msFuture* msFutureThen(msFuture* input, msClosure onFulfilled) {
	return msFutureThenTyped(input, onFulfilled, MS_TYPETAG_PTR);
}

void* msFutureThenTyped(void* input, msClosure onFulfilled, int typeTag) {
	return msFutureThenTypedWithRejected(input, onFulfilled, typeTag, (msClosure){0});
}

void* msFutureThenTypedWithRejected(void* input, msClosure onFulfilled, int typeTag, msClosure onRejected) {
	return msFutureThenAttach(input, onFulfilled, onRejected, typeTag, msFutureThenRunTagged);
}

static void msFutureCatchOkGeneric(void* output, void* input) {
	msFutureComplete(output, ((msFuture*)input)->value);
}

msFuture* msFutureCatch(msFuture* input, msClosure onRejected) {
	return msFutureCatchTyped(input, onRejected, MS_TYPETAG_PTR);
}

void* msFutureCatchTyped(void* input, msClosure onRejected, int typeTag) {
	(void)typeTag;
	return msFutureCatchAttach(input, msFutureCreate(), onRejected, msFutureCatchOkGeneric);
}

void* msFutureFinally(void* input, msClosure onSettled) {
	msClosureCopy(onSettled);
	return msPromiseFinallyAttach(input, (void*)onSettled.fn, onSettled.env);
}

#endif /* !MSOS_BARE */

/*
 * MetaScript AbortController / AbortSignal — C runtime helpers
 * Only the operations that need C are here. The classes themselves
 * are pure MetaScript (declared in index.ms).
 */
#ifndef MS_ABORT_H
#define MS_ABORT_H

/* Raise abort error — sets msErr flag (same as throw) */
static inline void msAbortThrow(void) {
	msCurrException = (msException*)msMakeError(msStringFromCStr("AbortError"));
	msErr = true;
}

#endif /* MS_ABORT_H */

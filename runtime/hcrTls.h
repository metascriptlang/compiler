#ifndef MS_HCR_TLS_H
#define MS_HCR_TLS_H

#include <stdint.h>

#if defined(_WIN32) && (defined(MS_HCR_CORE) || defined(MS_HCR_MODULE))
#if !defined(_M_X64) && !defined(__x86_64__)
#error "HCR images reach core TLS through the x64 TEB; this Windows architecture has no HCR TLS adapter"
#endif
#include <intrin.h>
extern uint32_t msHcrTlsIndex;
static inline char* msHcrTlsBase(uint32_t index) { return ((char**)__readgsqword(0x58))[index]; }
#endif

#if defined(_WIN32) && defined(MS_HCR_MODULE)

#define MS_TLS_EXTERN(type, name) extern uint32_t msHcrTlsOffset_##name
#define MS_TLS_EXTERN_ARRAY(type, name, count) extern uint32_t msHcrTlsOffset_##name
#define MS_HCR_TLS_REF(type, name) (*(type*)(msHcrTlsBase(msHcrTlsIndex) + msHcrTlsOffset_##name))
#define MS_HCR_TLS_ARRAY(type, name) ((type*)(msHcrTlsBase(msHcrTlsIndex) + msHcrTlsOffset_##name))

#define msCurrentActor MS_HCR_TLS_REF(msActor*, msCurrentActor)
#define msMySchedulerID MS_HCR_TLS_REF(int, msMySchedulerID)
#define msMyHazard MS_HCR_TLS_REF(msHazardRec*, msMyHazard)
#define msMsgPools MS_HCR_TLS_ARRAY(msMsgPool, msMsgPools)
#define _msEvtBuf MS_HCR_TLS_ARRAY(msReadyEvent, _msEvtBuf)
#define msErr MS_HCR_TLS_REF(bool, msErr)
#define msCurrException MS_HCR_TLS_REF(msException*, msCurrException)
#define msCallSoonProc MS_HCR_TLS_REF(msCallSoonFn, msCallSoonProc)
#define msErrPayload MS_HCR_TLS_REF(void*, msErrPayload)
#define msRoots MS_HCR_TLS_REF(msCellSeq, msRoots)
#define msRootsThreshold MS_HCR_TLS_REF(int32_t, msRootsThreshold)
#define msOrcTeardownDepth MS_HCR_TLS_REF(int32_t, msOrcTeardownDepth)
#define msFreedCyclicObjects MS_HCR_TLS_REF(int32_t, msFreedCyclicObjects)
#define msFutureReleaseBuf MS_HCR_TLS_ARRAY(void*, msFutureReleaseBuf)
#define msFutureReleaseCount MS_HCR_TLS_REF(int, msFutureReleaseCount)
#define msIsPoolWorker MS_HCR_TLS_REF(bool, msIsPoolWorker)

#else

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L && !defined(__STDC_NO_THREADS__)
#define MS_TLS_STORAGE _Thread_local
#else
#define MS_TLS_STORAGE __thread
#endif
#define MS_TLS_EXTERN(type, name) extern MS_TLS_STORAGE type name
#define MS_TLS_EXTERN_ARRAY(type, name, count) extern MS_TLS_STORAGE type name[count]

#endif

#if defined(_WIN32) && defined(MS_HCR_CORE)
extern unsigned long _tls_index;
#define MS_TLS_PUBLISH(name) \
	uint32_t msHcrTlsOffset_##name; \
	__attribute__((constructor)) static void msHcrTlsPublish_##name(void) { \
		msHcrTlsIndex = (uint32_t)_tls_index; \
		msHcrTlsOffset_##name = (uint32_t)((char*)&name - msHcrTlsBase((uint32_t)_tls_index)); \
	}
#else
#define MS_TLS_PUBLISH(name)
#endif

#endif

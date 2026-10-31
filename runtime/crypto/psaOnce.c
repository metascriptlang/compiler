#include "runtime/crypto/psaOnce.h"
#include "psa/crypto.h"

#ifdef _WIN32
#include <windows.h>
static SRWLOCK psaLock = SRWLOCK_INIT;
void msPsaLock(void) { AcquireSRWLockExclusive(&psaLock); }
void msPsaUnlock(void) { ReleaseSRWLockExclusive(&psaLock); }
#else
#include <pthread.h>
static pthread_mutex_t psaLock = PTHREAD_MUTEX_INITIALIZER;
void msPsaLock(void) { pthread_mutex_lock(&psaLock); }
void msPsaUnlock(void) { pthread_mutex_unlock(&psaLock); }
#endif

static int psaInitialized;

int msPsaEnsure(void) {
	if (psaInitialized) return 0;
	if (psa_crypto_init() != PSA_SUCCESS) return -1;
	psaInitialized = 1;
	return 0;
}

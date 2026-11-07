#include "foreign.h"
#if defined(_WIN32)
#include <windows.h>
static DWORD WINAPI body(LPVOID arg) { return (DWORD)foreignWork((int32_t)(intptr_t)arg); }
int32_t msTestRunForeignThreads(int32_t count) {
	int32_t sum = 0;
	for (int32_t i = 0; i < count; i++) {
		HANDLE t = CreateThread(NULL, 0, body, (LPVOID)(intptr_t)i, 0, NULL);
		if (t == NULL) return -1;
		WaitForSingleObject(t, INFINITE);
		DWORD code = 0;
		GetExitCodeThread(t, &code);
		sum += (int32_t)code;
		CloseHandle(t);
	}
	return sum;
}
#else
#include <pthread.h>
/* A destructor of another key that runs MS code after the runtime's own exit release:
 * it re-arms itself once, so its MS call lands in a later destructor round. */
static pthread_key_t lateKey;
static pthread_once_t lateOnce = PTHREAD_ONCE_INIT;
static void lateWork(void* round) {
	if ((intptr_t)round == 1) { pthread_setspecific(lateKey, (void*)2); return; }
	foreignWork(-1);
}
static void lateCreate(void) { pthread_key_create(&lateKey, lateWork); }
static void* body(void* arg) {
	pthread_once(&lateOnce, lateCreate);
	pthread_setspecific(lateKey, (void*)1);
	return (void*)(intptr_t)foreignWork((int32_t)(intptr_t)arg);
}
int32_t msTestRunForeignThreads(int32_t count) {
	int32_t sum = 0;
	for (int32_t i = 0; i < count; i++) {
		pthread_t t;
		void* r = NULL;
		if (pthread_create(&t, NULL, body, (void*)(intptr_t)i) != 0) return -1;
		pthread_join(t, &r);
		sum += (int32_t)(intptr_t)r;
	}
	return sum;
}
#endif

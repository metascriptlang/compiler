#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#define holdNap() Sleep(1)
#else
#include <unistd.h>
#include <pthread.h>
#define holdNap() usleep(1000)
#endif
struct msTaskFrame;
const struct msTaskFrame* msPoolFrameSwap(const struct msTaskFrame* frame);
static _Atomic int32_t holdRunning = 0;
static _Atomic int32_t holdRelease = 0;
static inline int32_t holdWorker(void) { atomic_fetch_add(&holdRunning, 1); while (!atomic_load(&holdRelease)) holdNap(); atomic_fetch_sub(&holdRunning, 1); return 1; }
static inline void holdWaitAll(int32_t n) { while (atomic_load(&holdRunning) < n) holdNap(); }
static inline void holdReleaseAll(void) { atomic_store(&holdRelease, 1); }
static inline void holdRearm(void) { atomic_store(&holdRelease, 0); }
static inline int32_t holdRunningAfter(int32_t ms) { for (int32_t i = 0; i < ms; i++) holdNap(); return atomic_load(&holdRunning); }
static inline int32_t holdFrameLeft(void) { const struct msTaskFrame* f = msPoolFrameSwap(NULL); msPoolFrameSwap(f); return f != NULL ? 1 : 0; }
#ifdef _WIN32
static DWORD WINAPI holdHangWatch(LPVOID seconds) { Sleep((DWORD)(intptr_t)seconds * 1000); puts("STEP hung"); fflush(stdout); _exit(1); }
static inline void holdHangAfter(int32_t seconds) { HANDLE t = CreateThread(NULL, 0, holdHangWatch, (LPVOID)(intptr_t)seconds, 0, NULL); if (t != NULL) CloseHandle(t); }
#else
static void* holdHangWatch(void* seconds) { sleep((unsigned)(intptr_t)seconds); puts("STEP hung"); fflush(stdout); _exit(1); }
static inline void holdHangAfter(int32_t seconds) { pthread_t t; if (pthread_create(&t, NULL, holdHangWatch, (void*)(intptr_t)seconds) == 0) pthread_detach(t); }
#endif

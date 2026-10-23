#include <stdint.h>
#include <stdatomic.h>
#ifdef _WIN32
#include <windows.h>
#define holdNap() Sleep(1)
#else
#include <unistd.h>
#define holdNap() usleep(1000)
#endif
struct msTaskFrame;
const struct msTaskFrame* msPoolFrameSwap(const struct msTaskFrame* frame);
static _Atomic int32_t holdRunning = 0;
static _Atomic int32_t holdRelease = 0;
static inline int32_t holdWorker(void) { atomic_fetch_add(&holdRunning, 1); while (!atomic_load(&holdRelease)) holdNap(); return 1; }
static inline void holdWaitAll(int32_t n) { while (atomic_load(&holdRunning) < n) holdNap(); }
static inline void holdReleaseAll(void) { atomic_store(&holdRelease, 1); }
static inline int32_t holdFrameLeft(void) { const struct msTaskFrame* f = msPoolFrameSwap(NULL); msPoolFrameSwap(f); return f != NULL ? 1 : 0; }

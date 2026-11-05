#ifndef MS_BARE_HEAP_CHECKS_H
#define MS_BARE_HEAP_CHECKS_H
#include <stdint.h>
int32_t msBareHeapReuseChecks(void);
int32_t msBareHeapUseAfterFree(void);
int32_t msAllocatorCoreChecks(void);
void msBareHeapOtherUnitFree(void* p);
#endif
